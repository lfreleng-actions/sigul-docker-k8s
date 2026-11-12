#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Tests for the chart's client bundle builder,
# K8S/charts/sigul/files/toolbox/make-bundle.sh (#116).
#
# Issues real certificates with pki-bootstrap.sh, as
# test_pki_bootstrap_clients.py does, and serves its Secrets to
# make-bundle.sh through a stand-in kubectl. Checks:
#   - the SIGUL_CREDENTIALS document (--format action) has the shape
#     sigul-sign-action documents: base64 of compact JSON holding
#     version 1, the base64 client.conf, the first line of the key
#     passphrase and the base64 armoured bundle, and nothing else
#   - the bundle decrypts with the passphrase to a tar.xz whose top
#     directory is the last component of --nss-dir, holding an NSS
#     database with the three nicknames and the trust nss-init.sh sets
#   - client.conf names the client, the bridge, the default in-cluster
#     server name, the nss-dir and the database's NSS password
#   - the shared certificate is used when the client has no Secret,
#     and for a server.adminUser name no Secret can carry (ci_bot);
#     from files (--secrets-dir) only with --shared-cert, which refuses
#     a per-client certificate, even one whose name starts with the
#     shared certificate's sigul-client. prefix
#   - an --nss-dir whose last component starts with '-' is archived
#   - a CRLF passphrase file encrypts with, and puts in the JSON, the
#     passphrase without its carriage return
#   - the NSS password never reaches sed's argv
#   - an empty Secret, a CN differing from --client and existing
#     outputs are refused, and nothing is left behind
#   - an output another run creates mid-way is neither overwritten nor
#     mixed with this run's: this run fails and takes its own back
#
# Needs bash, certutil, pk12util, gpg, tar, xz and jq; the client
# image carries them all:
#   docker run --rm --user 1000:1000 \
#     -v "${PWD}/test:/test:ro" \
#     -v "${PWD}/K8S/charts/sigul/files:/chart-files:ro" \
#     -e PKI_SCRIPTS_DIR=/chart-files/scripts \
#     -e MAKE_BUNDLE=/chart-files/toolbox/make-bundle.sh \
#     --entrypoint python3 <client image> /test/test_make_bundle.py

import base64
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_pki_bootstrap_clients import (  # noqa: E402
    CA_PUBLIC,
    FIXED_SECRETS,
    PASSWORDS,
    PREFIX,
    SHARED,
    Release,
)


def _script() -> Path:
    return Path(
        os.environ.get(
            "MAKE_BUNDLE",
            Path(__file__).resolve().parent.parent
            / "K8S/charts/sigul/files/toolbox/make-bundle.sh",
        )
    )


SCRIPT = _script()
RELEASE = "sigul"
NAMESPACE = "signing"
BRIDGE = "sigul-bridge.example.org"
CLIENT = "opensearch-canary"
PASSPHRASE = "correct horse battery staple"
CREDENTIAL_KEYS = {"version", "config", "password", "pki"}

FAILURES: list[str] = []

# kubectl, as far as make-bundle.sh uses it, over the JSON store the
# pki-bootstrap.sh stand-in writes.
KUBECTL = r"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
name = args[args.index("secret") + 1]
if os.environ.get("STUB_QUERIES"):
    open(os.environ["STUB_QUERIES"], "a").write(name + "\n")
plant = os.environ.get("STUB_PLANT")
if plant and not os.path.exists(plant):
    open(plant, "w").write("another run\n")
path = os.path.join(os.environ["STUB_STORE"], name + ".json")
data = json.load(open(path)) if os.path.exists(path) else None
if "--ignore-not-found" in args:
    print("secret/" + name if data is not None else "")
    sys.exit(0)
if data is None:
    sys.exit('Error from server (NotFound): secrets "%s" not found' % name)
key = args[-1].split("{.data.", 1)[1].rstrip("}").replace("\\.", ".")
sys.stdout.write(data.get(key, ""))
"""

# sed, logging its argv when STUB_SED_ARGV names a file.
SED = """#!/bin/sh
[ -z "${{STUB_SED_ARGV:-}}" ] || printf '%s\\n' "$*" >> "${{STUB_SED_ARGV}}"
exec {sed} "$@"
"""


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


class Cluster:
    """A bootstrapped release, its Secrets served by a stand-in kubectl."""

    def __init__(self, root: Path, clients: list[str] | None) -> None:
        names = FIXED_SECRETS + (
            [f"{PREFIX}{c}-p12" for c in clients] if clients else [SHARED]
        )
        self.release: Release = Release(root / "release", names)
        done = self.release.run(" ".join(clients) if clients else None)
        if done.returncode:
            raise SystemExit(f"pki-bootstrap.sh failed:\n{done.stderr}")
        self.bin: Path = root / "bin"
        self.bin.mkdir()
        kubectl = self.bin / "kubectl"
        _ = kubectl.write_text(KUBECTL)
        kubectl.chmod(0o755)
        sed = self.bin / "sed"
        _ = sed.write_text(SED.format(sed=shutil.which("sed") or "/bin/sed"))
        sed.chmod(0o755)
        self.root: Path = root
        self.passfile: Path = root / "passphrase"
        _ = self.passfile.write_text(f"{PASSPHRASE}\nignored second line\n")

    def make_bundle(
        self,
        out: Path,
        *extra: str,
        client: str = CLIENT,
        passfile: Path | None = None,
        stub_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = {
            "PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "STUB_STORE": str(self.release.store),
            **(stub_env or {}),
        }
        return subprocess.run(
            [
                "bash",
                str(SCRIPT),
                "--release",
                RELEASE,
                "--namespace",
                NAMESPACE,
                "--client",
                client,
                "--bridge",
                BRIDGE,
                "--key-passphrase-file",
                str(passfile or self.passfile),
                "--out",
                str(out),
                *extra,
            ],
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )


def secrets_dir(cluster: Cluster, dest: Path, client_secret: str) -> Path:
    """Copy the four Secret keys to files, as for the admin toolbox."""
    dest.mkdir()
    for key, secret in (
        ("client.p12", client_secret),
        ("ca.crt", CA_PUBLIC),
        ("bridge.crt", CA_PUBLIC),
        ("p12-password", PASSWORDS),
    ):
        _ = (dest / key).write_bytes(cluster.release.value(secret, key))
    return dest


def run(*argv: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=False)


def conf_value(conf: str, key: str) -> str:
    match = re.search(rf"^{re.escape(key)}:\s*(.*)$", conf, re.MULTILINE)
    return match.group(1).strip() if match else ""


def unpack(asc: Path, dest: Path) -> list[str]:
    """Decrypt and unpack a bundle as a consumer does; list its members."""
    home = dest / "gnupg"
    home.mkdir(parents=True)
    done = subprocess.run(
        [
            "gpg",
            "--homedir",
            str(home),
            "--batch",
            "--quiet",
            "--pinentry-mode",
            "loopback",
            "--passphrase-fd",
            "0",
            "-d",
            "-o",
            str(dest / "bundle.tar.xz"),
            str(asc),
        ],
        input=f"{PASSPHRASE}\n",
        capture_output=True,
        text=True,
        check=False,
    )
    _ = run("gpgconf", "--homedir", str(home), "--kill", "gpg-agent")
    if done.returncode:
        return []
    listing = run("tar", "-tJf", str(dest / "bundle.tar.xz")).stdout.split()
    _ = run("tar", "-xJf", str(dest / "bundle.tar.xz"), "-C", str(dest))
    return listing


def test_action_format(tmp: Path) -> None:
    cluster = Cluster(tmp / "action", ["admin", CLIENT])
    out = tmp / "action" / "out"
    sed_argv = tmp / "action" / "sed-argv"
    done = cluster.make_bundle(
        out, "--format", "action", stub_env={"STUB_SED_ARGV": str(sed_argv)}
    )
    check(
        "make-bundle.sh --format action succeeds",
        done.returncode == 0,
        f"exit {done.returncode}" + (f"\n{done.stderr}" if done.returncode else ""),
    )
    if done.returncode:
        return
    files = sorted(p.name for p in out.iterdir())
    check(
        "it writes client.conf, sigul-pki.asc and sigul-credentials.b64 alone",
        files == ["client.conf", "sigul-credentials.b64", "sigul-pki.asc"],
        f"{files}",
    )
    modes = {p.name: stat.S_IMODE(p.stat().st_mode) for p in out.iterdir()}
    check(
        "every output is readable by its owner alone",
        all(m == 0o600 for m in modes.values())
        and stat.S_IMODE(out.stat().st_mode) == 0o700,
        f"{ {k: oct(v) for k, v in modes.items()} }",
    )

    conf = (out / "client.conf").read_text()
    asc = (out / "sigul-pki.asc").read_bytes()
    encoded = (out / "sigul-credentials.b64").read_text()
    check(
        "sigul-credentials.b64 is a single base64 line",
        encoded.endswith("\n") and "\n" not in encoded.rstrip("\n"),
        f"{len(encoded.splitlines())} line(s)",
    )
    raw = base64.b64decode(encoded.strip(), validate=True).decode()
    parsed = cast("object", json.loads(raw))
    document = cast("dict[str, object]", parsed) if isinstance(parsed, dict) else {}

    def text(key: str) -> str:
        value = document.get(key)
        return value if isinstance(value, str) else ""

    check(
        "the credentials document is compact JSON",
        raw == json.dumps(document, separators=(",", ":")),
        raw[:40] + "...",
    )
    check(
        "the credentials document holds version, config, password and pki only",
        set(document) == CREDENTIAL_KEYS,
        f"{sorted(document)}",
    )
    version = document.get("version")
    check(
        "version is the integer 1",
        type(version) is int and version == 1,
        f"{version!r}",
    )
    check(
        "config is client.conf, base64",
        base64.b64decode(text("config"), validate=True).decode() == conf,
        "decodes to client.conf",
    )
    check(
        "password is the first line of the key passphrase",
        text("password") == PASSPHRASE,
        "first line only",
    )
    check(
        "pki is the armoured bundle, base64",
        base64.b64decode(text("pki"), validate=True) == asc
        and asc.startswith(b"-----BEGIN PGP MESSAGE-----"),
        "decodes to sigul-pki.asc",
    )

    check(
        "client.conf names the client, bridge, server and nss-dir",
        conf_value(conf, "user-name") == CLIENT
        and conf_value(conf, "bridge-hostname") == BRIDGE
        and conf_value(conf, "bridge-port") == "44334"
        and conf_value(conf, "server-hostname")
        == f"sigul-server.{RELEASE}-bridge.{NAMESPACE}.svc.cluster.local"
        and conf_value(conf, "client-cert-nickname") == "sigul-client-cert"
        and conf_value(conf, "nss-dir") == "/home/jenkins/sigul"
        and "${" not in conf,
        "rendered from client.conf.template",
    )
    nss_password = conf_value(conf, "nss-password")
    check(
        "the NSS password is printed once and matches client.conf",
        done.stdout.count(nss_password) == 1 and len(nss_password) >= 24,
        "printed on stdout",
    )
    argv = sed_argv.read_text() if sed_argv.exists() else ""
    check(
        "the NSS password never reaches sed's argv",
        bool(argv) and nss_password not in argv,
        f"{len(argv.splitlines())} sed call(s) logged",
    )

    listing = unpack(out / "sigul-pki.asc", tmp / "action" / "unpacked")
    check(
        "the bundle decrypts to a tar.xz of sigul/ holding the NSS database",
        bool(listing)
        and all(m.split("/")[0] == "sigul" for m in listing)
        and {"sigul/cert9.db", "sigul/key4.db"} <= set(listing),
        f"{listing}",
    )
    db = tmp / "action" / "unpacked" / "sigul"
    certs = run("certutil", "-L", "-d", f"sql:{db}").stdout
    trust = {
        line.rsplit(None, 1)[0].strip(): line.rsplit(None, 1)[1]
        for line in certs.splitlines()
        if line.startswith("sigul-")
    }
    check(
        "the database holds the CA, bridge and client with nss-init.sh's trust",
        trust
        == {
            "sigul-ca": "CT,C,C",
            "sigul-bridge-cert": "P,P,P",
            "sigul-client-cert": "u,u,u",
        },
        f"{trust}",
    )
    pwfile = tmp / "action" / "nss.pw"
    _ = pwfile.write_text(nss_password)
    keys = run("certutil", "-K", "-d", f"sql:{db}", "-f", str(pwfile)).stdout
    check(
        "the NSS password unlocks the client's key, and only it",
        "sigul-client-cert" in keys and "sigul-ca" not in keys,
        keys.strip().splitlines()[-1] if keys.strip() else "no keys",
    )
    subject = run("certutil", "-L", "-d", f"sql:{db}", "-n", "sigul-client-cert")
    check(
        "the client certificate is the client's own",
        f'Subject: "CN={CLIENT}"' in subject.stdout,
        "CN matches --client",
    )
    leftovers = [p.name for p in out.iterdir() if p.name.startswith(".")]
    leftovers += [p.name for p in (tmp / "action").glob("make-bundle-gnupg.*")]
    check("no scratch directory is left behind", not leftovers, f"{leftovers}")

    again = cluster.make_bundle(out, "--format", "action")
    check(
        "existing outputs are not overwritten",
        again.returncode != 0
        and "already exists" in again.stderr
        and (out / "sigul-pki.asc").read_bytes() == asc,
        f"exit {again.returncode}",
    )


def test_files_format(tmp: Path) -> None:
    cluster = Cluster(tmp / "files", ["admin", CLIENT])
    out = tmp / "files" / "out"
    done = cluster.make_bundle(out, "--nss-dir", "/var/sigul/.sigul")
    files = sorted(p.name for p in out.iterdir()) if out.exists() else []
    check(
        "--format files writes client.conf and sigul-pki.asc only",
        done.returncode == 0 and files == ["client.conf", "sigul-pki.asc"],
        f"exit {done.returncode}, {files}"
        + (f"\n{done.stderr}" if done.returncode else ""),
    )
    if done.returncode:
        return
    conf = (out / "client.conf").read_text()
    listing = unpack(out / "sigul-pki.asc", tmp / "files" / "unpacked")
    check(
        "--nss-dir sets nss-dir and the archive's top directory",
        conf_value(conf, "nss-dir") == "/var/sigul/.sigul"
        and bool(listing)
        and all(m.split("/")[0] == ".sigul" for m in listing),
        f"{listing}",
    )

    out = tmp / "files" / "dash"
    done = cluster.make_bundle(out, "--nss-dir", "/home/jenkins/-sigul")
    listing = (
        unpack(out / "sigul-pki.asc", tmp / "files" / "dash-unpacked")
        if done.returncode == 0
        else []
    )
    check(
        "an --nss-dir whose last component starts with '-' is archived",
        bool(listing) and all(m.split("/")[0] == "-sigul" for m in listing),
        f"exit {done.returncode}, {listing}"
        + (f"\n{done.stderr}" if done.returncode else ""),
    )


def test_shared_certificate(tmp: Path) -> None:
    cluster = Cluster(tmp / "shared", None)
    out = tmp / "shared" / "out"
    done = cluster.make_bundle(out)
    conf = (out / "client.conf").read_text() if done.returncode == 0 else ""
    check(
        "without its own Secret a client gets the shared certificate",
        done.returncode == 0
        and f"using the shared {RELEASE}-client-p12" in done.stderr
        and conf_value(conf, "user-name") == CLIENT,
        f"exit {done.returncode}" + (f"\n{done.stderr}" if done.returncode else ""),
    )

    queries = tmp / "shared" / "queries"
    out = tmp / "shared" / "ci_bot"
    done = cluster.make_bundle(
        out, client="ci_bot", stub_env={"STUB_QUERIES": str(queries)}
    )
    conf = (out / "client.conf").read_text() if done.returncode == 0 else ""
    asked = queries.read_text().split() if queries.exists() else []
    check(
        "a server.adminUser name no Secret can carry uses the shared certificate",
        done.returncode == 0
        and conf_value(conf, "user-name") == "ci_bot"
        and f"{PREFIX}ci_bot-p12" not in asked,
        f"exit {done.returncode}, queried {asked}"
        + (f"\n{done.stderr}" if done.returncode else ""),
    )

    # The admin toolbox path: the shared Secret's keys copied to files.
    secrets = secrets_dir(cluster, tmp / "shared" / "secrets", SHARED)
    out = tmp / "shared" / "toolbox"
    done = cluster.make_bundle(
        out, "--secrets-dir", str(secrets), "--shared-cert", client="admin"
    )
    conf = (out / "client.conf").read_text() if done.returncode == 0 else ""
    check(
        "--secrets-dir --shared-cert builds a bundle from the shared certificate",
        done.returncode == 0 and conf_value(conf, "user-name") == "admin",
        f"exit {done.returncode}" + (f"\n{done.stderr}" if done.returncode else ""),
    )
    out = tmp / "shared" / "toolbox-strict"
    done = cluster.make_bundle(out, "--secrets-dir", str(secrets), client="admin")
    check(
        "--secrets-dir without --shared-cert refuses the shared certificate",
        done.returncode != 0
        and "--shared-cert" in done.stderr
        and not any(out.iterdir()),
        done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "",
    )


def test_shared_prefix_collision(tmp: Path) -> None:
    # A pki.clients name may start with the shared certificate's
    # sigul-client. prefix; only its key usage tells the two apart.
    collider = "sigul-client.canary"
    cluster = Cluster(tmp / "collide", ["admin", collider])
    secrets = secrets_dir(
        cluster, tmp / "collide" / "secrets", f"{PREFIX}{collider}-p12"
    )
    out = tmp / "collide" / "shared"
    done = cluster.make_bundle(
        out, "--secrets-dir", str(secrets), "--shared-cert", client="admin"
    )
    check(
        "--shared-cert refuses a per-client certificate named sigul-client.*",
        done.returncode != 0
        and "not the shared certificate" in done.stderr
        and not any(out.iterdir()),
        done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "",
    )
    out = tmp / "collide" / "strict"
    done = cluster.make_bundle(out, "--secrets-dir", str(secrets), client="admin")
    check(
        "a per-client sigul-client.* mismatch does not suggest --shared-cert",
        done.returncode != 0
        and f"CN is '{collider}', not --client 'admin'" in done.stderr
        and "--shared-cert" not in done.stderr
        and not any(out.iterdir()),
        done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "",
    )
    out = tmp / "collide" / "own"
    done = cluster.make_bundle(out, "--secrets-dir", str(secrets), client=collider)
    check(
        "a client named sigul-client.* gets a bundle from its own certificate",
        done.returncode == 0 and (out / "sigul-pki.asc").is_file(),
        f"exit {done.returncode}" + (f"\n{done.stderr}" if done.returncode else ""),
    )


def test_crlf_passphrase(tmp: Path) -> None:
    cluster = Cluster(tmp / "crlf", ["admin", CLIENT])
    passfile = tmp / "crlf" / "passphrase-crlf"
    _ = passfile.write_bytes(f"{PASSPHRASE}\r\nignored\r\n".encode())
    out = tmp / "crlf" / "out"
    done = cluster.make_bundle(out, "--format", "action", passfile=passfile)
    password = ""
    if done.returncode == 0:
        encoded = (out / "sigul-credentials.b64").read_text().strip()
        document = cast("object", json.loads(base64.b64decode(encoded)))
        if isinstance(document, dict):
            value = cast("dict[str, object]", document).get("password")
            password = value if isinstance(value, str) else ""
    listing = (
        unpack(out / "sigul-pki.asc", tmp / "crlf" / "unpacked")
        if done.returncode == 0
        else []
    )
    check(
        "a CRLF passphrase file loses its carriage return",
        done.returncode == 0 and password == PASSPHRASE and bool(listing),
        f"exit {done.returncode}, password {password!r}, "
        + f"{'decrypts' if listing else 'does not decrypt'} without the CR",
    )


def test_concurrent_publication(tmp: Path) -> None:
    cluster = Cluster(tmp / "race", ["admin", CLIENT])
    out = tmp / "race" / "out"
    planted = out / "sigul-pki.asc"
    done = cluster.make_bundle(out, stub_env={"STUB_PLANT": str(planted)})
    files = sorted(p.name for p in out.iterdir()) if out.exists() else []
    check(
        "an output created by another run mid-way is kept, and this run backs out",
        done.returncode != 0
        and "cannot create" in done.stderr
        and planted.read_text() == "another run\n"
        and files == ["sigul-pki.asc"],
        f"exit {done.returncode}, {files}",
    )


def test_refusals(tmp: Path) -> None:
    cluster = Cluster(tmp / "refuse", ["admin", CLIENT])
    store = cluster.release.store

    _ = (store / f"{PREFIX}ci-bot-p12.json").write_text("{}")
    out = tmp / "refuse" / "empty"
    done = cluster.make_bundle(out, client="ci-bot")
    check(
        "an unpopulated client Secret is refused",
        done.returncode != 0
        and f"{PREFIX}ci-bot-p12 has no client.p12" in done.stderr
        and not any(out.iterdir()),
        done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "",
    )

    secrets = secrets_dir(cluster, tmp / "refuse" / "secrets", f"{PREFIX}admin-p12")
    out = tmp / "refuse" / "mismatch"
    done = cluster.make_bundle(out, "--secrets-dir", str(secrets))
    check(
        "a certificate whose CN differs from --client is refused",
        done.returncode != 0
        and f"CN is 'admin', not --client '{CLIENT}'" in done.stderr
        and not any(out.iterdir()),
        done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "",
    )
    out = tmp / "refuse" / "secrets-dir"
    done = cluster.make_bundle(out, "--secrets-dir", str(secrets), client="admin")
    check(
        "--secrets-dir builds a bundle without the cluster",
        done.returncode == 0 and (out / "sigul-pki.asc").is_file(),
        f"exit {done.returncode}" + (f"\n{done.stderr}" if done.returncode else ""),
    )
    out = tmp / "refuse" / "not-shared"
    done = cluster.make_bundle(
        out, "--secrets-dir", str(secrets), "--shared-cert", client="ci-bot"
    )
    check(
        "--shared-cert refuses a per-client certificate",
        done.returncode != 0
        and "not the shared certificate" in done.stderr
        and not any(out.iterdir()),
        done.stderr.strip().splitlines()[-1] if done.stderr.strip() else "",
    )

    for label, args in (
        ("--shared-cert without --secrets-dir", ["--shared-cert"]),
        ("a --client that is not a user name", ["--client", "bad;name"]),
        ("a relative --nss-dir", ["--nss-dir", "sigul"]),
        ("an unknown --format", ["--format", "yaml"]),
    ):
        done = cluster.make_bundle(tmp / "refuse" / "args", *args)
        check(f"{label} is refused", done.returncode != 0, f"exit {done.returncode}")


def main() -> int:
    print("make-bundle.sh client bundle tests")
    print(f"script: {SCRIPT}")
    print()
    with tempfile.TemporaryDirectory() as tmp:
        test_action_format(Path(tmp))
        test_files_format(Path(tmp))
        test_shared_certificate(Path(tmp))
        test_shared_prefix_collision(Path(tmp))
        test_crlf_passphrase(Path(tmp))
        test_concurrent_publication(Path(tmp))
        test_refusals(Path(tmp))
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("make-bundle.sh builds the bundle sigul-sign-action consumes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
