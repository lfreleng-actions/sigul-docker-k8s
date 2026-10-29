#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for importing keys whose primary secret is a stub
# (patch 21, #96).
#
# A key exported with 'gpg --export-secret-subkeys' carries its primary
# secret as a gnu-dummy stub: the shape in which a project hands over a
# signing key while keeping its primary key offline. sigul re-protects an
# imported key's secrets through 'gpg --edit-key' 'passwd'. GnuPG cannot
# re-protect a primary secret it does not have, so that session ends in
# FAILURE although the subkey was re-protected; the status reached a
# callback with no case for it, which raised NotImplementedError and took
# the server down. A wrong import passphrase ends the same way for any
# key. Deleting the half-imported key then left the subkey's secret
# behind, so every retry was refused.
#
# The checks run the server's own import, re-protection and deletion
# code - the calls import_gnupg_key makes - against the publicly known
# fixtures in test/fixtures, in a throwaway GnuPG home.
#
# Run inside the sigul server image, with the fixtures mounted:
#   python3 test/test_server_subkey_import.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# server_common is upstream code this repository only patches, and ships
# no type stubs, so its members are untyped by nature.

import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import server_common  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(server_common, "_check_subkey_only_rewrap")

FIXTURES = os.environ.get(
    "SIGUL_FIXTURES",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures"),
)
NEW_PASSPHRASE = "sigul-server-side-passphrase"


class Config:
    """The one server configuration field the GnuPG helpers read."""

    def __init__(self, gnupg_home: str) -> None:
        self.gnupg_home: str = gnupg_home


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def fixture(name: str) -> str:
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return handle.read().strip()


def decode(name: str, work: str) -> str:
    """Decode a double-encoded fixture key; return the armoured key's path."""
    home = tempfile.mkdtemp(prefix="g", dir="/tmp")
    output = os.path.join(work, name + ".asc")
    try:
        with open(os.path.join(FIXTURES, name + ".b64"), "rb") as encoded:
            _ = subprocess.run(
                [
                    "gpg",
                    "--homedir",
                    home,
                    "--batch",
                    "--pinentry-mode",
                    "loopback",
                    "--passphrase-file",
                    os.path.join(FIXTURES, "sigul-import-test.passphrase"),
                    "--output",
                    output,
                    "--decrypt",
                ],
                input=subprocess.run(
                    ["base64", "-d"],
                    stdin=encoded,
                    capture_output=True,
                    check=True,
                ).stdout,
                capture_output=True,
                check=True,
            )
    finally:
        _ = subprocess.run(["gpgconf", "--homedir", home, "--kill", "all"], check=False)
        shutil.rmtree(home, ignore_errors=True)
    return output


def server_home() -> Config:
    """A fresh GnuPG home configured the way the server configures its own."""
    home = tempfile.mkdtemp(prefix="s", dir="/tmp")
    os.rmdir(home)  # generate_gpg_config creates it, mode 0700
    config = Config(home)
    server_common.gpg_modify_environ(config)
    return config


def secrets_left(config: Config) -> list[str]:
    directory = os.path.join(config.gnupg_home, "private-keys-v1.d")
    if not os.path.isdir(directory):
        return []
    return sorted(name for name in os.listdir(directory) if name.endswith(".key"))


def import_key(config: Config, path: str, old: str) -> tuple[str, str]:
    """Import and re-protect as import_gnupg_key does.

    Return the key's fingerprint and the name of the exception raised, or
    an empty string. On failure the key is deleted, as import_gnupg_key's
    handler does.
    """
    with open(path, "rb") as key_file:
        fingerprint = server_common.gpg_import_key(config, key_file)
    try:
        server_common.gpg_change_password(config, fingerprint, old, NEW_PASSPHRASE)
    except Exception as error:
        # Any exception type is the result under test: a refused
        # passphrase must surface as GPGError, never as a crash.
        server_common.gpg_delete_key(config, fingerprint)
        return fingerprint, type(error).__name__
    return fingerprint, ""


def verify_issuer(config: Config, fingerprint: str) -> str:
    """Sign with the key; return the VALIDSIG line a clean verifier reports."""
    work = tempfile.mkdtemp(prefix="v", dir="/tmp")
    verifier = tempfile.mkdtemp(prefix="k", dir="/tmp")
    try:
        cleartext = os.path.join(work, "payload")
        signature = os.path.join(work, "payload.sig")
        with open(cleartext, "wb") as handle:
            _ = handle.write(b"sigul subkey import test payload\n")
        with open(cleartext, "rb") as source, open(signature, "wb") as sink:
            server_common.gpg_detached_signature(
                config, sink, source, fingerprint, NEW_PASSPHRASE, False
            )
        public = server_common.gpg_public_key(config, fingerprint)
        _ = subprocess.run(
            ["gpg", "--homedir", verifier, "--batch", "--import"],
            input=public if isinstance(public, bytes) else public.encode(),
            capture_output=True,
            check=True,
        )
        done = subprocess.run(
            [
                "gpg",
                "--homedir",
                verifier,
                "--batch",
                "--status-fd",
                "1",
                "--verify",
                signature,
                cleartext,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        return next(
            (line for line in done.stdout.splitlines() if " VALIDSIG " in line), ""
        )
    finally:
        _ = subprocess.run(
            ["gpgconf", "--homedir", verifier, "--kill", "all"], check=False
        )
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(verifier, ignore_errors=True)


def stop(config: Config) -> None:
    _ = subprocess.run(
        ["gpgconf", "--homedir", config.gnupg_home, "--kill", "all"], check=False
    )
    shutil.rmtree(config.gnupg_home, ignore_errors=True)


def test_subkey_only_import(subkey_key: str) -> None:
    primary = fixture("sigul-import-subkey-test-key.primary.fingerprint")
    subkey = fixture("sigul-import-subkey-test-key.subkey.fingerprint")
    old = fixture("sigul-import-subkey-test-key.passphrase")
    config = server_home()
    try:
        fingerprint, error = import_key(config, subkey_key, old)
        check(
            "a subkey-only key imports and is re-protected",
            fingerprint == primary and not error,
            f"fingerprint {fingerprint}, error {error or 'none'}",
        )
        if error:
            return
        keygrips = [
            subkey.keygrip
            for subkey in server_common._gpg_open(config)
            .get_key(fingerprint, True)
            .subkeys
            if subkey.secret
        ]
        unlocks = {
            label: server_common._gpg_passphrase_unlocks(
                config, keygrips[0], passphrase.encode()
            )
            for label, passphrase in (
                ("new", NEW_PASSPHRASE),
                ("old", old),
                ("wrong", "not-any-passphrase-of-this-key"),
            )
        }
        check(
            "only the server-side passphrase unlocks the subkey afterwards",
            len(keygrips) == 1
            and unlocks == {"new": True, "old": False, "wrong": False},
            ", ".join(f"{k} passphrase unlocks: {v}" for k, v in unlocks.items()),
        )
        validsig = verify_issuer(config, fingerprint)
        fields = validsig.split()
        check(
            "its signatures come from the subkey and verify against the key",
            len(fields) > 11 and fields[2] == subkey and fields[11] == primary,
            validsig or "no VALIDSIG",
        )
        server_common.gpg_delete_key(config, fingerprint)
        left = secrets_left(config)
        check(
            "deleting it leaves no secret behind",
            not left,
            f"secret files left: {left or 'none'}",
        )
        again, error = import_key(config, subkey_key, old)
        check(
            "it can then be imported again",
            again == primary and not error,
            f"error {error or 'none'}",
        )
    finally:
        stop(config)


# gpg --with-colons names its fingerprint record this; spelled out, codespell
# reads it as a typo.
FINGERPRINT_RECORD = "f" + "pr:"


def listed_fingerprints(home: str) -> list[str]:
    """Fingerprints in a GnuPG home: the primary key's first, then subkeys'."""
    listing = subprocess.run(
        ["gpg", "--homedir", home, "--list-keys", "--with-colons"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [
        line.split(":")[9]
        for line in listing.splitlines()
        if line.startswith(FINGERPRINT_RECORD)
    ]


def make_two_secret_key(work: str, passphrase: str) -> str:
    """Export a new subkey-only key holding a signing and an encryption secret.

    Each call writes its own file: GnuPG in batch mode leaves an existing
    output file in place and still exits 0, which would hand a later caller
    an earlier key.
    """
    home = tempfile.mkdtemp(prefix="m", dir="/tmp")
    with open(os.path.join(home, "gpg-agent.conf"), "w", encoding="utf-8") as f:
        _ = f.write("allow-loopback-pinentry\n")
    base = ["gpg", "--homedir", home, "--batch", "--pinentry-mode", "loopback"]
    base += ["--passphrase", passphrase]
    output_fd, output = tempfile.mkstemp(prefix="two-secret-", suffix=".asc", dir=work)
    os.close(output_fd)
    try:
        user = "Two Secret Test (THROWAWAY) <two@example.invalid>"
        _ = subprocess.run(
            [*base, "--quick-gen-key", user, "rsa2048", "sign,cert", "never"],
            capture_output=True,
            check=True,
        )
        primary = listed_fingerprints(home)[0]
        for usage in ("sign", "encr"):
            _ = subprocess.run(
                [*base, "--quick-add-key", primary, "rsa2048", usage, "5y"],
                capture_output=True,
                check=True,
            )
        subkeys = [fingerprint + "!" for fingerprint in listed_fingerprints(home)[1:]]
        _ = subprocess.run(
            [*base, "--yes", "--armor", "--output", output]
            + ["--export-secret-subkeys", *subkeys],
            capture_output=True,
            check=True,
        )
    finally:
        _ = subprocess.run(["gpgconf", "--homedir", home, "--kill", "all"], check=False)
        shutil.rmtree(home, ignore_errors=True)
    return output


def secret_subkeys(config: Config, fingerprint: str) -> list[tuple[str, bool]]:
    """Return (keygrip, can_sign) for each subkey whose secret is present."""
    key = server_common._gpg_open(config).get_key(fingerprint, True)
    return [(s.keygrip, bool(s.can_sign)) for s in key.subkeys[1:] if s.secret]


def reprotect(config: Config, keygrip: str, old: str, new: str) -> None:
    """Re-protect one secret through the agent, as a partial edit would."""
    old_file = os.path.join(config.gnupg_home, "old-passphrase")
    new_file = os.path.join(config.gnupg_home, "new-passphrase")
    for path, value in ((old_file, old), (new_file, new)):
        with open(path, "w", encoding="utf-8") as handle:
            _ = handle.write(value)
    try:
        _ = subprocess.run(
            [
                "gpg-connect-agent",
                "--homedir",
                config.gnupg_home,
                "/definqfile PASSPHRASE " + old_file,
                "/definqfile NEW_PASSPHRASE " + new_file,
                "OPTION pinentry-mode=loopback",
                "PASSWD --preset " + keygrip,
                "/bye",
            ],
            capture_output=True,
            check=True,
        )
    finally:
        os.remove(old_file)
        os.remove(new_file)


def test_every_secret_is_reprotected(work: str) -> None:
    old = "two-secret-import-passphrase"
    key = make_two_secret_key(work, old)
    config = server_home()
    try:
        fingerprint, error = import_key(config, key, old)
        secrets = secret_subkeys(config, fingerprint) if not error else []
        states = [
            (
                "sign" if can_sign else "encrypt",
                server_common._gpg_passphrase_unlocks(
                    config, keygrip, NEW_PASSPHRASE.encode()
                ),
                server_common._gpg_passphrase_unlocks(config, keygrip, old.encode()),
            )
            for keygrip, can_sign in secrets
        ]
        check(
            "a key with signing and encryption secrets has both re-protected",
            not error
            and len(states) == 2
            and all(new and not was_old for _, new, was_old in states),
            f"error {error or 'none'}; (secret, new unlocks, old unlocks): {states}",
        )
    finally:
        stop(config)


def test_partial_reprotect_is_refused(work: str) -> None:
    old = "two-secret-import-passphrase"
    key = make_two_secret_key(work, old)
    config = server_home()
    try:
        with open(key, "rb") as key_file:
            fingerprint = server_common.gpg_import_key(config, key_file)
        secrets = secret_subkeys(config, fingerprint)
        signing = [keygrip for keygrip, can_sign in secrets if can_sign]
        reprotect(config, signing[0], old, NEW_PASSPHRASE)
        stored = server_common._gpg_open(config).get_key(fingerprint, True)
        try:
            server_common._check_subkey_only_rewrap(
                config, stored, old.encode(), NEW_PASSPHRASE, "gpg-exit 33554433"
            )
            outcome = "accepted"
        except server_common.GPGError as error:
            outcome = f"refused: {error}"
        check(
            "a key with one secret left on the old passphrase is refused",
            outcome.startswith("refused"),
            f"signing secret re-protected, encryption secret not: {outcome}",
        )
        for keygrip, can_sign in secrets:
            if not can_sign:
                reprotect(config, keygrip, old, NEW_PASSPHRASE)
        stored = server_common._gpg_open(config).get_key(fingerprint, True)
        try:
            server_common._check_subkey_only_rewrap(
                config, stored, old.encode(), NEW_PASSPHRASE, "gpg-exit 33554433"
            )
            outcome = "accepted"
        except server_common.GPGError as error:
            outcome = f"refused: {error}"
        check(
            "the same key is accepted once every secret is re-protected",
            outcome == "accepted",
            outcome,
        )
        server_common.gpg_delete_key(config, fingerprint)
    finally:
        stop(config)


def test_wrong_passphrase(label: str, key: str) -> None:
    config = server_home()
    try:
        _, error = import_key(config, key, "not-the-import-passphrase")
        left = secrets_left(config)
        check(
            f"a wrong passphrase on {label} is refused, and cleaned up",
            error == "GPGError" and not left,
            f"raised {error or 'nothing'}, secret files left: {left or 'none'}",
        )
    finally:
        stop(config)


def test_complete_key_unchanged(full_key: str) -> None:
    config = server_home()
    try:
        fingerprint, error = import_key(
            config, full_key, fixture("sigul-import-test-key.passphrase")
        )
        check(
            "a complete key still imports as before",
            fingerprint == fixture("sigul-import-test-key.fingerprint") and not error,
            f"error {error or 'none'}",
        )
    finally:
        stop(config)


def main() -> int:
    print("Server subkey-only import regression tests")
    print(f"server_common: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    work = tempfile.mkdtemp(prefix="w", dir="/tmp")
    try:
        subkey_key = decode("sigul-import-subkey-test-key", work)
        full_key = decode("sigul-import-test-key", work)
        test_subkey_only_import(subkey_key)
        test_every_secret_is_reprotected(work)
        test_partial_reprotect_is_refused(work)
        test_wrong_passphrase("a subkey-only key", subkey_key)
        test_wrong_passphrase("a complete key", full_key)
        test_complete_key_unchanged(full_key)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("subkey-only keys import, a bad passphrase is refused, nothing is left")
    return 0


if __name__ == "__main__":
    sys.exit(main())
