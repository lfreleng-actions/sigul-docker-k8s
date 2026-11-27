#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Tests for the admin toolbox's key expiry report,
# K8S/charts/sigul/files/toolbox/key-expiry.sh (#204).
#
# Generates throwaway public keys with gpg on a frozen clock, so every
# expiry is fixed, and serves them to the report through a stand-in
# sigul that answers list-keys and get-public-key --password only to
# the admin password on stdin. Checks:
#   - every signing-capable (sub)key is listed with its key name,
#     primary fingerprint, own fingerprint, UTC ISO 8601 expiry and
#     days remaining, or never; an encryption subkey is not, and a key
#     that cannot sign prints one NOSIGN line
#   - a signing subkey expires no later than its primary key
#   - the expired and the due come first, each group by expiry
#   - the exit status is 1 exactly when a signing (sub)key has expired
#     or expires within --warn-days (default 30), and --warn-days
#     moves that line
#   - the admin password reaches sigul on stdin only, from
#     SIGUL_ADMIN_PASSWORD or stdin up to a NUL or a newline, even
#     with stdin left open, and appears in no output and in no argv
#   - a wrong password or a key sigul cannot export exits 2
#
# Needs bash, gpg and GNU date; the client image carries them:
#   docker run --rm --user 1000:1000 \
#     -v "${PWD}/test:/test:ro" \
#     -v "${PWD}/K8S/charts/sigul/files:/chart-files:ro" \
#     -e KEY_EXPIRY=/chart-files/toolbox/key-expiry.sh \
#     --entrypoint python3 <client image> /test/test_key_expiry.py

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(
    os.environ.get(
        "KEY_EXPIRY",
        Path(__file__).resolve().parent.parent
        / "K8S/charts/sigul/files/toolbox/key-expiry.sh",
    )
)
PASSWORD = "admin-password-never-printed"
DAY = 86400
# Every key is created on 2026-01-01T00:00:00Z; the report is judged
# 100 days later, on 2026-04-11T00:00:00Z.
CREATED = 1767225600
NOW = CREATED + 100 * DAY
Y2100 = 4102444800

FAILURES: list[str] = []

# sigul, as far as key-expiry.sh uses it: list-keys and
# get-public-key --password, each answered only to the admin password,
# NUL-terminated on stdin. Logs its argv to STUB_ARGV.
SIGUL = r"""#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
with open(os.environ["STUB_ARGV"], "a") as log:
    log.write(" ".join(args) + "\n")
secret = sys.stdin.buffer.read().split(b"\0")[0].decode()
if "--batch" not in args or secret != os.environ["STUB_PASSWORD"]:
    sys.exit("Error: Authentication failed")
store = os.environ["STUB_KEYS"]
command = args[args.index("-c") + 2]
if command == "list-keys":
    for name in sorted(os.listdir(store)):
        print(name[: -len(".asc")])
elif command == "get-public-key" and args[-2] == "--password":
    path = os.path.join(store, args[-1] + ".asc")
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        sys.exit("Error: Key does not exist")
    sys.stdout.write(open(path).read())
else:
    sys.exit("stub sigul: unexpected arguments %r" % args)
"""


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


class Keyring:
    """Throwaway keys on a frozen clock, exported as sigul would."""

    def __init__(self, root: Path) -> None:
        self.home: Path = root / "gnupg"
        self.home.mkdir(mode=0o700)
        self.store: Path = root / "store"
        self.store.mkdir()

    def gpg(self, *args: str) -> str:
        done = subprocess.run(
            [
                "gpg",
                "--homedir",
                str(self.home),
                "--batch",
                "--quiet",
                "--pinentry-mode",
                "loopback",
                "--passphrase",
                "",
                "--faked-system-time",
                f"{CREATED}!",
                *args,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if done.returncode:
            raise SystemExit(f"gpg {' '.join(args)} failed:\n{done.stderr}")
        return done.stdout

    def fingerprints(self, selector: str) -> list[str]:
        """Primary then subkey fingerprints, in key order."""
        colons = self.gpg("--with-colons", "--list-keys", selector)
        pattern = r"^fpr:+([0-9A-F]{40}):"  # codespell:ignore fpr
        return re.findall(pattern, colons, re.MULTILINE)

    def key(self, name: str, usage: str, expires: int | None) -> str:
        """A key whose primary has USAGE, expiring EXPIRES seconds in."""
        uid = f"{name} <{name}@example.invalid>"
        span = f"seconds={expires}" if expires else "never"
        _ = self.gpg("--quick-gen-key", uid, "ed25519", usage, span)
        return self.fingerprints(f"={uid}")[0]

    def subkey(self, primary: str, algo: str, usage: str, expires: int) -> str:
        _ = self.gpg("--quick-add-key", primary, algo, usage, f"seconds={expires}")
        return self.fingerprints(primary)[-1]

    def publish(self, name: str, primary: str, store: Path | None = None) -> None:
        _ = ((store or self.store) / f"{name}.asc").write_text(
            self.gpg("--armor", "--export", primary)
        )


def environment(keyring: Path, root: Path, env_password: str | None) -> dict[str, str]:
    env = {
        "PATH": f"{root / 'bin'}:{os.environ.get('PATH', '/usr/bin:/bin')}",
        "HOME": str(root),
        "TMPDIR": str(root),
        "STUB_KEYS": str(keyring),
        "STUB_PASSWORD": PASSWORD,
        "STUB_ARGV": str(root / "sigul-argv"),
    }
    if env_password is not None:
        env["SIGUL_ADMIN_PASSWORD"] = env_password
    return env


def command(root: Path, *args: str) -> list[str]:
    return [
        "bash",
        str(SCRIPT),
        "-c",
        str(root / "client.conf"),
        "--now",
        str(NOW),
        *args,
    ]


def run(
    keyring: Path,
    root: Path,
    *args: str,
    env_password: str | None = PASSWORD,
    stdin: str = "",
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command(root, *args),
        env=environment(keyring, root, env_password),
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )


def run_open_stdin(keyring: Path, root: Path, stdin: str) -> tuple[int | None, str]:
    """Run with STDIN written but the pipe left open; None on a hang."""
    proc = subprocess.Popen(
        command(root),
        env=environment(keyring, root, None),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert proc.stdin is not None
    _ = proc.stdin.write(stdin)
    proc.stdin.flush()
    try:
        status: int | None = proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
        status = None
    out, _ = proc.communicate()
    return status, out


def line(
    status: str, key: str, primary: str, signing: str, expiry: str, days: str
) -> str:
    return (
        f"{status} key={key} primary={primary} signing={signing} "
        + f"expires={expiry} days={days}"
    )


def main() -> int:
    print("key-expiry.sh key expiry report tests")
    print(f"script: {SCRIPT}")
    print()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "bin").mkdir()
        stub = root / "bin" / "sigul"
        _ = stub.write_text(SIGUL)
        stub.chmod(0o755)
        _ = (root / "client.conf").write_text("[client]\n")
        ring = Keyring(root)

        # Expired 60 days ago: a primary that signs.
        expired = ring.key("expired", "sign", 40 * DAY)
        ring.publish("expired", expired)
        # Due in 10 days: a certify-only primary with a signing subkey,
        # and an encryption subkey, long expired, that must not count.
        due = ring.key("due", "cert", None)
        due_sign = ring.subkey(due, "ed25519", "sign", 110 * DAY + 12 * 3600)
        _ = ring.subkey(due, "cv25519", "encr", 95 * DAY)
        ring.publish("due", due)
        # 200 days out, with a signing subkey 45 days out.
        later = ring.key("later", "sign", 300 * DAY)
        later_sign = ring.subkey(later, "ed25519", "sign", 145 * DAY)
        ring.publish("later", later)
        never = ring.key("never", "sign", None)
        ring.publish("never", never)
        cannot = ring.key("cannot-sign", "cert", None)
        _ = ring.subkey(cannot, "cv25519", "encr", 400 * DAY)
        ring.publish("cannot-sign", cannot)
        # Kept apart: a certify-only primary expiring on
        # 2100-01-01T00:00:00Z, with a signing subkey a year later. gpg
        # itself caps the subkey once the primary has expired by the
        # real clock, so the primary's expiry lies far ahead of it and
        # the report is judged 10 days before it.
        apart = root / "apart"
        apart.mkdir()
        cert_first = ring.key("cert-first", "cert", Y2100 - CREATED)
        cert_first_sign = ring.subkey(
            cert_first, "ed25519", "sign", Y2100 - CREATED + 365 * DAY
        )
        ring.publish("cert-first", cert_first, apart)

        lines = {
            "expired": line(
                "EXPIRED", "expired", expired, expired, "2026-02-10T00:00:00Z", "-60"
            ),
            "due": line("DUE", "due", due, due_sign, "2026-04-21T12:00:00Z", "10"),
            "later-sub": line(
                "OK", "later", later, later_sign, "2026-05-26T00:00:00Z", "45"
            ),
            "later": line("OK", "later", later, later, "2026-10-28T00:00:00Z", "200"),
            "never": line("OK", "never", never, never, "never", "never"),
            "cannot": f"NOSIGN key=cannot-sign primary={cannot} signing=none "
            + "expires=never days=never",
        }

        done = run(ring.store, root)
        got = done.stdout.splitlines()
        want = [
            lines[k]
            for k in ("expired", "due", "later-sub", "later", "never", "cannot")
        ]
        check(
            "the report lists each signing (sub)key, expired and due first",
            got == want,
            "\n  " + "\n  ".join(got) + (f"\n{done.stderr}" if got != want else ""),
        )
        check(
            "an expired and a due key exit 1",
            done.returncode == 1,
            f"exit {done.returncode}",
        )
        check(
            "the summary counts keys, signing (sub)keys and flagged ones",
            "5 key(s), 5 signing (sub)key(s), 2 expired or due within 30 day(s)"
            in done.stderr,
            done.stderr.strip(),
        )

        done = run(apart, root, "--now", str(Y2100 - 10 * DAY))
        check(
            "a signing subkey is due with its certify-only primary",
            done.returncode == 1
            and done.stdout.splitlines()
            == [
                line(
                    "DUE",
                    "cert-first",
                    cert_first,
                    cert_first_sign,
                    "2100-01-01T00:00:00Z",
                    "10",
                )
            ],
            f"exit {done.returncode}\n  " + done.stdout + done.stderr,
        )
        padded = run(apart, root, "--now", f"0{Y2100 - 10 * DAY}")
        check(
            "a --now with a leading zero is read in base 10",
            padded.returncode == done.returncode and padded.stdout == done.stdout,
            f"exit {padded.returncode}\n  " + padded.stdout + padded.stderr,
        )

        done = run(ring.store, root, "--warn-days", "0")
        check(
            "--warn-days 0 leaves only the expired key flagged",
            done.returncode == 1
            and done.stdout.splitlines()[:2]
            == [lines["expired"], lines["due"].replace("DUE ", "OK ", 1)],
            f"exit {done.returncode}\n  " + "\n  ".join(done.stdout.splitlines()[:2]),
        )

        for name in ("expired", "due", "cannot-sign"):
            _ = (ring.store / f"{name}.asc").rename(root / f"{name}.asc")
        done = run(ring.store, root)
        check(
            "keys outside the threshold, or never expiring, exit 0",
            done.returncode == 0
            and done.stdout.splitlines()
            == [lines["later-sub"], lines["later"], lines["never"]],
            f"exit {done.returncode}",
        )
        done = run(ring.store, root, "--warn-days", "60")
        check(
            "--warn-days 60 makes the subkey 45 days out due, and exit 1",
            done.returncode == 1
            and done.stdout.splitlines()[:1]
            == [lines["later-sub"].replace("OK ", "DUE ", 1)],
            f"exit {done.returncode}, {done.stdout.splitlines()[:1]}",
        )
        _ = (root / "due.asc").rename(ring.store / "due.asc")
        done = run(ring.store, root, "--warn-days", "10")
        check(
            "a subkey expiring just after --warn-days is OK",
            done.returncode == 0
            and lines["due"].replace("DUE ", "OK ", 1) in done.stdout.splitlines(),
            f"exit {done.returncode}",
        )
        done = run(ring.store, root, "--warn-days", "11")
        check(
            "a subkey expiring inside --warn-days is DUE",
            done.returncode == 1 and done.stdout.splitlines()[:1] == [lines["due"]],
            f"exit {done.returncode}",
        )

        argv = root / "sigul-argv"
        argv.unlink()
        done = run(ring.store, root, env_password=None, stdin=f"{PASSWORD}\0")
        logged = argv.read_text() if argv.exists() else ""
        check(
            "the password is read from stdin when SIGUL_ADMIN_PASSWORD is unset",
            done.returncode == 1 and done.stdout.splitlines()[:1] == [lines["due"]],
            f"exit {done.returncode}"
            + (f"\n{done.stderr}" if done.returncode != 1 else ""),
        )
        calls = logged.splitlines()
        check(
            "sigul runs in batch mode, list-keys then get-public-key per key",
            len(calls) == 4
            and all(c.startswith("--batch -c ") for c in calls)
            and calls[0].endswith(" list-keys")
            and all(" get-public-key --password " in c for c in calls[1:]),
            f"{calls}",
        )
        outputs = [done.stdout, done.stderr, logged]
        status, out = run_open_stdin(ring.store, root, f"{PASSWORD}\n")
        check(
            "a newline ends the password on stdin left open",
            status == 1 and out.splitlines()[:1] == [lines["due"]],
            f"exit {status}" + (" (hung)" if status is None else ""),
        )
        outputs.append(out)
        for extra in (run(ring.store, root), run(ring.store, root, "--help")):
            outputs += [extra.stdout, extra.stderr]
        check(
            "the admin password appears in no output and no sigul argv",
            all(PASSWORD not in text for text in outputs) and bool(logged),
            f"{len(outputs)} streams searched",
        )

        done = run(ring.store, root, env_password="wrong")
        check(
            "a wrong admin password exits 2, naming the failure",
            done.returncode == 2
            and "list-keys failed: Error: Authentication failed" in done.stderr
            and not done.stdout,
            done.stderr.strip(),
        )
        _ = (ring.store / "broken.asc").write_text("")
        done = run(ring.store, root)
        check(
            "a key sigul cannot export exits 2, naming the key",
            done.returncode == 2
            and "get-public-key broken failed" in done.stderr
            and not done.stdout,
            done.stderr.strip(),
        )
        leftovers = [p.name for p in root.glob("key-expiry.*")]
        check("no scratch directory is left behind", not leftovers, f"{leftovers}")

        helped = run(ring.store, root, "--help")
        check(
            "--help documents every option and the exit status",
            helped.returncode == 0
            and all(
                o in helped.stdout
                for o in ("--config", "--warn-days", "--now", "--help", "Exit status")
            ),
            f"exit {helped.returncode}",
        )
        for label, args in (
            ("a negative --warn-days", ["--warn-days", "-1"]),
            ("an unknown option", ["--bogus"]),
        ):
            done = run(ring.store, root, *args)
            check(f"{label} exits 2", done.returncode == 2, f"exit {done.returncode}")

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("key-expiry.sh reports every signing key's expiry")
    return 0


if __name__ == "__main__":
    sys.exit(main())
