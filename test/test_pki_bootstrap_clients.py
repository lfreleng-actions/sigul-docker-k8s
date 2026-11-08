#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Tests for the chart's PKI bootstrap issuing one client certificate
# per Sigul user (pki.clients, #104).
#
# Runs K8S/charts/sigul/files/scripts/pki-bootstrap.sh for real -
# certutil and pk12util issue and export every certificate - against a
# stand-in for publish-secrets.py that keeps Secrets as JSON files.
# Like the chart's Role, the stand-in only writes to Secrets that
# already exist, so a test pre-creates exactly the set the chart
# renders and any write outside it fails the run.
#
# Each published client.p12 is then imported the way nss-init.sh does
# and checked: its nickname, its CN, a clientAuth-only extended key
# usage, a serial no other certificate shares, and that it validates
# as an SSL client against the published CA.
#
# Needs bash, certutil and pk12util; run inside the sigul bridge
# image, which the bootstrap Job also uses:
#   docker run --rm --user 1000:1000 \
#     -v "${PWD}/test:/test:ro" \
#     -v "${PWD}/K8S/charts/sigul/files/scripts:/chart-scripts:ro" \
#     --entrypoint python3 <bridge image> \
#     /test/test_pki_bootstrap_clients.py

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import cast


def _scripts_dir() -> Path:
    path = Path(
        os.environ.get(
            "PKI_SCRIPTS_DIR",
            Path(__file__).resolve().parent.parent / "K8S/charts/sigul/files/scripts",
        )
    )
    if (path / "pki-bootstrap.sh").is_file():
        return path
    return Path("/chart-scripts")


SCRIPTS = _scripts_dir()

FAILURES: list[str] = []

EXTERNAL_FQDN = "sigul.example.org"
INTERNAL_FQDN = "sigul-bridge.sigul.svc.cluster.local"
PREFIX = "sigul-client-"
SHARED = "sigul-client-p12"
CA_PUBLIC = "sigul-ca-public"
PASSWORDS = "sigul-passwords"
MARKER = "sigul-pki-bootstrapped"
# How the script refuses an auto run whose client set changed.
IDENTITY_CHANGED = "differ from those the completed"
FIXED_SECRETS = [
    CA_PUBLIC,
    "sigul-bridge-p12",
    "sigul-server-p12",
    PASSWORDS,
    "sigul-admin",
    MARKER,
]

# The stand-in for publish-secrets.py: the same subcommands and exit
# codes, with each Secret's data in STORE/<name>.json and every call
# appended to STORE/calls.log.
STUB = r"""
import base64, json, os, sys
store = os.environ["STUB_STORE"]
args = sys.argv[1:]
with open(os.path.join(store, "calls.log"), "a") as log:
    log.write(" ".join(args) + "\n")
cmd = args[0]
if cmd in ("lock", "unlock", "restart"):
    sys.exit(0)
path = os.path.join(store, args[1] + ".json")
data = None
if os.path.exists(path):
    with open(path) as fh:
        data = json.load(fh)
if cmd == "exists":
    keys = [args[i + 1] for i, a in enumerate(args) if a == "--key"]
    ok = bool(data) and all(data.get(k) for k in keys)
    sys.exit(0 if ok else 1)
if cmd == "matches":
    ok = bool(data) and args[2] in data and (
        base64.b64decode(data[args[2]]).decode() == args[3])
    sys.exit(0 if ok else 1)
if cmd == "get":
    if not data or args[2] not in data:
        sys.exit(1)
    print(base64.b64decode(data[args[2]]).decode())
    sys.exit(0)
if cmd == "apply":
    if data is None:
        sys.exit("Secret %s does not exist" % args[1])
    if "--if-absent" in args and data:
        sys.exit(0)
    i = 2
    while i < len(args):
        if args[i] == "--file":
            key, _, src = args[i + 1].partition("=")
            with open(src, "rb") as fh:
                data[key] = base64.b64encode(fh.read()).decode()
            i += 2
        elif args[i] == "--literal":
            key, _, value = args[i + 1].partition("=")
            data[key] = base64.b64encode(value.encode()).decode()
            i += 2
        else:
            i += 1
    with open(path, "w") as fh:
        json.dump(data, fh)
    sys.exit(0)
sys.exit("unknown subcommand %s" % cmd)
"""


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


class Release:
    """One release's Secrets, and the bootstrap script wired to them."""

    def __init__(self, root: Path, secrets: list[str]) -> None:
        self.root: Path = root
        self.store: Path = root / "store"
        self.work: Path = root / "work"
        self.store.mkdir(parents=True)
        self.work.mkdir()
        stub = root / "publish-secrets.py"
        _ = stub.write_text(STUB)
        text = (SCRIPTS / "pki-bootstrap.sh").read_text()
        for old, new in (
            ("python3 /scripts/publish-secrets.py", f"python3 {stub}"),
            ("WORK=/work\n", f"WORK={self.work}\n"),
        ):
            if old not in text:
                raise SystemExit(f"pki-bootstrap.sh no longer contains {old!r}")
            text = text.replace(old, new)
        self.script: Path = root / "pki-bootstrap.sh"
        _ = self.script.write_text(text)
        for name in secrets:
            self.create(name)

    def create(self, name: str) -> None:
        path = self.store / f"{name}.json"
        if not path.exists():
            _ = path.write_text("{}")

    def run(
        self, clients: str | None, **extra: str
    ) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(self.root),
            "STUB_STORE": str(self.store),
            "PKI_MODE": "auto",
            "EXTERNAL_FQDN": EXTERNAL_FQDN,
            "INTERNAL_FQDN": INTERNAL_FQDN,
            "BRIDGE_SERVICE_NAME": "sigul-bridge",
            "CA_VALIDITY_MONTHS": "12",
            "CERT_VALIDITY_MONTHS": "12",
            "SECRET_CA_PUBLIC": CA_PUBLIC,
            "SECRET_BRIDGE_P12": "sigul-bridge-p12",
            "SECRET_SERVER_P12": "sigul-server-p12",
            "SECRET_PASSWORDS": PASSWORDS,
            "SECRET_ADMIN": "sigul-admin",
            "SECRET_MARKER": MARKER,
            "LOCK_LEASE": "sigul-pki-bootstrap",
            "POD_NAME": "pki-bootstrap-test",
            "BRIDGE_DEPLOYMENT": "sigul-bridge",
            "SERVER_STATEFULSET": "sigul-server",
        }
        if clients is None:
            env["SECRET_CLIENT_P12"] = SHARED
        else:
            env.update(
                {
                    "PKI_CLIENTS": clients,
                    "SECRET_CLIENT_P12_PREFIX": PREFIX,
                    "ADMIN_USER": "admin",
                    "LENIENT_USERNAME_CHECK": "no",
                }
            )
        env.update(extra)
        return subprocess.run(
            ["bash", str(self.script)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def data(self, name: str) -> dict[str, str]:
        path = self.store / f"{name}.json"
        if not path.exists():
            return {}
        return cast("dict[str, str]", json.loads(path.read_text()))

    def value(self, name: str, key: str) -> bytes:
        return base64.b64decode(self.data(name).get(key, ""))

    def calls(self) -> str:
        log = self.store / "calls.log"
        return log.read_text() if log.exists() else ""


def inspect_bundle(release: Release, secret: str, tag: str) -> dict[str, str]:
    """Import a published client.p12 as nss-init.sh does and describe it."""
    db = release.root / f"nss-{tag}"
    db.mkdir()
    pw = release.root / f"nss-{tag}.pw"
    _ = pw.write_text("test")
    p12 = release.root / f"{tag}.p12"
    _ = p12.write_bytes(release.value(secret, "client.p12"))
    p12pw = release.root / f"{tag}.p12pw"
    _ = p12pw.write_bytes(release.value(PASSWORDS, "p12-password"))
    ca = release.root / f"{tag}-ca.crt"
    _ = ca.write_bytes(release.value(CA_PUBLIC, "ca.crt"))

    def nss(*argv: str) -> str:
        done = subprocess.run(argv, capture_output=True, text=True, check=False)
        return done.stdout + done.stderr

    _ = nss("certutil", "-N", "-d", f"sql:{db}", "-f", str(pw))
    _ = nss(
        "certutil",
        "-A",
        "-d",
        f"sql:{db}",
        "-f",
        str(pw),
        "-n",
        "sigul-ca",
        "-t",
        "CT,C,C",
        "-a",
        "-i",
        str(ca),
    )
    _ = nss(
        "pk12util",
        "-i",
        str(p12),
        "-d",
        f"sql:{db}",
        "-k",
        str(pw),
        "-w",
        str(p12pw),
    )
    listing = nss("certutil", "-L", "-d", f"sql:{db}", "-n", "sigul-client-cert")
    verify = nss(
        "certutil",
        "-V",
        "-d",
        f"sql:{db}",
        "-n",
        "sigul-client-cert",
        "-u",
        "C",
    )
    subject = re.search(r'Subject: "([^"]*)"', listing)
    serial = re.search(r"Serial Number: (\d+)", listing)
    return {
        "subject": subject.group(1) if subject else "",
        "serial": serial.group(1) if serial else "",
        "client_auth": str("TLS Web Client Authentication" in listing),
        "server_auth": str("TLS Web Server Authentication" in listing),
        "verify": verify.strip(),
    }


def per_client_secrets(clients: list[str]) -> list[str]:
    return [f"{PREFIX}{c}-p12" for c in clients]


def test_per_client_issuance(tmp: Path) -> None:
    clients = ["admin", "opensearch-canary", "release.bot"]
    release = Release(tmp / "per-client", FIXED_SECRETS + per_client_secrets(clients))
    done = release.run(" ".join(clients))
    check(
        "bootstrap with pki.clients succeeds",
        done.returncode == 0,
        f"exit {done.returncode}" + (f"\n{done.stderr}" if done.returncode else ""),
    )
    if done.returncode:
        return
    check(
        "no shared client certificate is published",
        not (release.store / f"{SHARED}.json").exists()
        and SHARED not in release.calls(),
        "nothing touched sigul-client-p12",
    )
    serials: list[str] = []
    for client in clients:
        secret = f"{PREFIX}{client}-p12"
        info = inspect_bundle(release, secret, client)
        serials.append(info["serial"])
        check(
            f"{secret} holds {client}'s certificate under sigul-client-cert",
            info["subject"] == f"CN={client}",
            f"subject {info['subject']!r}",
        )
        check(
            f"{client}'s certificate is for TLS client auth only",
            info["client_auth"] == "True" and info["server_auth"] == "False",
            f"clientAuth {info['client_auth']}, serverAuth {info['server_auth']}",
        )
        check(
            f"{client}'s certificate validates as an SSL client against the CA",
            "certificate is valid" in info["verify"],
            info["verify"].splitlines()[-1] if info["verify"] else "no output",
        )
    check(
        "every client certificate has its own serial",
        len(set(serials)) == len(serials) and all(serials),
        f"serials {serials}",
    )

    again = release.run(" ".join(clients))
    check(
        "a second run with the same clients is a no-op",
        again.returncode == 0 and "already bootstrapped" in again.stdout,
        f"exit {again.returncode}",
    )

    reordered = release.run(" ".join(reversed(clients)))
    check(
        "reordering pki.clients is still a no-op",
        reordered.returncode == 0 and "already bootstrapped" in reordered.stdout,
        f"exit {reordered.returncode}",
    )

    added = clients + ["late-joiner"]
    release.create(f"{PREFIX}late-joiner-p12")
    grown = release.run(" ".join(added))
    check(
        "adding a client under pki.mode=auto is refused",
        grown.returncode != 0
        and "late-joiner" in grown.stderr
        and IDENTITY_CHANGED in grown.stderr,
        f"exit {grown.returncode}",
    )
    rotated = release.run(" ".join(added), PKI_MODE="force")
    check(
        "pki.mode=force issues the added client's certificate",
        rotated.returncode == 0
        and inspect_bundle(release, f"{PREFIX}late-joiner-p12", "late")["subject"]
        == "CN=late-joiner",
        f"exit {rotated.returncode}",
    )

    # Removing late-joiner leaves its protected Secret populated with
    # a certificate from the trust domain the next force run replaces.
    removed = release.run(" ".join(clients), PKI_MODE="force")
    stale = release.value(f"{PREFIX}late-joiner-p12", "client.p12")
    back = release.run(" ".join(added))
    check(
        "re-adding a removed client whose old Secret survived is refused",
        removed.returncode == 0
        and bool(stale)
        and back.returncode != 0
        and IDENTITY_CHANGED in back.stderr,
        f"force exit {removed.returncode}, auto exit {back.returncode}",
    )

    # The shared Secret retained from before adoption, likewise stale.
    release.create(SHARED)
    _ = (release.store / f"{SHARED}.json").write_text(
        json.dumps({"client.p12": base64.b64encode(b"stale").decode()})
    )
    shared = release.run(None)
    check(
        "returning to the shared certificate under pki.mode=auto is refused",
        shared.returncode != 0 and IDENTITY_CHANGED in shared.stderr,
        f"exit {shared.returncode}",
    )


def test_shared_default(tmp: Path) -> None:
    release = Release(tmp / "shared", FIXED_SECRETS + [SHARED])
    done = release.run(None)
    info = inspect_bundle(release, SHARED, "shared") if done.returncode == 0 else {}
    check(
        "without pki.clients the shared client certificate is issued",
        done.returncode == 0
        and info.get("subject") == f"CN=sigul-client.{EXTERNAL_FQDN}",
        f"exit {done.returncode}, subject {info.get('subject')!r}",
    )
    check(
        "the shared certificate keeps its server and client usages",
        info.get("client_auth") == "True" and info.get("server_auth") == "True",
        f"clientAuth {info.get('client_auth')}, serverAuth {info.get('server_auth')}",
    )

    # A marker written before pki.clients existed has no
    # client-identities key; its bootstrap issued the shared bundle.
    marker = release.data(MARKER)
    _ = marker.pop("client-identities", None)
    _ = (release.store / f"{MARKER}.json").write_text(json.dumps(marker))
    again = release.run(None)
    check(
        "a marker from before pki.clients still counts as the shared set",
        again.returncode == 0 and "already bootstrapped" in again.stdout,
        f"exit {again.returncode}",
    )
    release.create(f"{PREFIX}admin-p12")
    adopted = release.run("admin")
    check(
        "adopting pki.clients under pki.mode=auto is refused",
        adopted.returncode != 0 and IDENTITY_CHANGED in adopted.stderr,
        f"exit {adopted.returncode}",
    )


def test_rejected_inputs(tmp: Path) -> None:
    cases: list[tuple[str, str, dict[str, str], str]] = [
        ("an upper-case name", "admin Canary", {}, "not a valid Sigul user name"),
        ("a name ending in '-'", "admin canary-", {}, "not a valid Sigul user name"),
        ("a name with '..'", "admin ci..bot", {}, "not a valid Sigul user name"),
        ("a name with '.-'", "admin ci.-bot", {}, "not a valid Sigul user name"),
        ("a name with '-.'", "admin ci-.bot", {}, "not a valid Sigul user name"),
        (
            "a prefix giving an invalid Secret name",
            "admin canary",
            {"SECRET_CLIENT_P12_PREFIX": "Sigul_client-"},
            "not a valid Kubernetes DNS-1123 subdomain",
        ),
        ("a duplicate name", "admin canary admin", {}, "more than once"),
        ("a list without the admin", "canary", {}, "must include the admin user"),
        (
            "lenient username checking",
            "admin canary",
            {"LENIENT_USERNAME_CHECK": "yes"},
            "LENIENT_USERNAME_CHECK",
        ),
        (
            "a missing Secret prefix",
            "admin canary",
            {"SECRET_CLIENT_P12_PREFIX": ""},
            "SECRET_CLIENT_P12_PREFIX not set",
        ),
    ]
    for n, (label, clients, extra, message) in enumerate(cases):
        release = Release(tmp / f"reject-{n}", FIXED_SECRETS)
        done = release.run(clients, **extra)
        check(
            f"{label} fails before the lock is taken",
            done.returncode != 0 and message in done.stderr and release.calls() == "",
            f"exit {done.returncode}, calls {release.calls().split()[:2]}",
        )


def main() -> int:
    print("PKI bootstrap per-client certificate tests")
    print(f"script: {SCRIPTS / 'pki-bootstrap.sh'}")
    print()
    with tempfile.TemporaryDirectory() as tmp:
        test_per_client_issuance(Path(tmp))
        test_shared_default(Path(tmp))
        test_rejected_inputs(Path(tmp))
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("each pki.clients entry gets its own CN-bound client certificate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
