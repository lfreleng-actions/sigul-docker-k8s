#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for importing keys whose primary secret is a stub
# (patch 21, #96), for what a refused import logs (patch 27, #187), and
# for re-protecting every secret of a key under load (patch 28, #189).
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
# A key with two secrets is also re-protected with gpg paused between its
# secrets (patch 28, #189). The agent's cached passphrases expire
# meanwhile, so it asks for the second secret's old passphrase again, as
# on a busy runner; the server must answer with the old passphrase, not
# the new one. The pause is synchronised with the agent: it is stopped
# before a prompt's answer reaches it, and gpg is stopped once it waits
# on the agent, so gpg cannot reach the next secret before the pause.
# The agent can also lose only its cached new passphrase and ask for the
# second secret's new passphrase alone. gpg relays that as the same
# prompt, which the server answers with the old passphrase, leaving that
# secret on it, and then answers the next secret's old-passphrase prompt
# with the new one, which fails the session. Two checks arrange those
# states without racing the agent: one answers the second secret's
# new-passphrase prompt with the old passphrase, and one, on a key with
# three secrets, makes the server take that prompt for an old-passphrase
# prompt. The server must then re-protect each secret itself.
#
# Run inside the sigul server image, with the fixtures mounted:
#   python3 test/test_server_subkey_import.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# server_common is upstream code this repository only patches, and ships
# no type stubs, so its members are untyped by nature.

import logging
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from typing import override

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


class Logged(logging.Handler):
    """Keeps what server_common logs, so a check can read a refusal's reason."""

    def __init__(self) -> None:
        super().__init__()
        self.messages: list[str] = []

    @override
    def emit(self, record: logging.LogRecord) -> None:
        self.messages.append(record.getMessage())


def check(label: str, ok: bool, detail: str) -> None:
    # Flushed, so each result stays beside the server's log lines for its
    # case: standard output is otherwise held back until the test ends,
    # and every log line appears to precede every result (#187).
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}", flush=True)
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


def key_files_left(config: Config) -> list[str]:
    """Names of the key files in the home: keygrips, not key material."""
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
        # passphrase must surface as GPGError, never as a crash. Callers
        # keep its type alone, so say here what it reported.
        print(f"NOTE  import refused: {error}", flush=True)
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
        left = key_files_left(config)
        check(
            "deleting it leaves no secret behind",
            not left,
            f"key files left: {left or 'none'}",
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
    """Export a new subkey-only key holding a signing and an encryption secret."""
    return make_key(work, passphrase, ("sign", "encr"), subkeys_only=True)


def make_key(
    work: str, passphrase: str, usages: tuple[str, ...], subkeys_only: bool
) -> str:
    """Export a new key with a subkey for each usage; return its path.

    With subkeys_only, only the subkeys' secrets are exported and the
    primary secret is a stub; otherwise every secret is.

    Each call writes its own file: GnuPG in batch mode leaves an existing
    output file in place and still exits 0, which would hand a later caller
    an earlier key.
    """
    home = tempfile.mkdtemp(prefix="m", dir="/tmp")
    with open(os.path.join(home, "gpg-agent.conf"), "w", encoding="utf-8") as f:
        _ = f.write("allow-loopback-pinentry\n")
    base = ["gpg", "--homedir", home, "--batch", "--pinentry-mode", "loopback"]
    base += ["--passphrase", passphrase]
    output_fd, output = tempfile.mkstemp(prefix="key-", suffix=".asc", dir=work)
    os.close(output_fd)
    try:
        user = "Re-protect Test (THROWAWAY) <reprotect@example.invalid>"
        _ = subprocess.run(
            [*base, "--quick-gen-key", user, "rsa2048", "sign,cert", "never"],
            capture_output=True,
            check=True,
        )
        primary = listed_fingerprints(home)[0]
        for usage in usages:
            _ = subprocess.run(
                [*base, "--quick-add-key", primary, "rsa2048", usage, "5y"],
                capture_output=True,
                check=True,
            )
        if subkeys_only:
            subkeys = [f + "!" for f in listed_fingerprints(home)[1:]]
            export = ["--export-secret-subkeys", *subkeys]
        else:
            export = ["--export-secret-keys", primary]
        _ = subprocess.run(
            [*base, "--yes", "--armor", "--output", output, *export],
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
    """Re-protect one secret through the agent, as a partial edit would.

    The passphrases reach the agent on standard input, so none is written
    to disk.
    """
    assert "\n" not in old + new, "a passphrase line cannot hold a newline"
    script = (
        f"/let old {old}\n"
        f"/let new {new}\n"
        "/definq PASSPHRASE old\n"
        "/definq NEW_PASSPHRASE new\n"
        "OPTION pinentry-mode=loopback\n"
        f"PASSWD --preset {keygrip}\n"
        "/bye\n"
    )
    _ = subprocess.run(
        ["gpg-connect-agent", "--homedir", config.gnupg_home],
        input=script.encode(),
        capture_output=True,
        check=True,
    )


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


# Longer than the server agent's max-cache-ttl of 1 s, which the agent
# counts in whole seconds.
PAUSE_SECONDS = 2.5
# A bound on each wait while arranging a pause, so a gpg or agent that
# never gets there cannot hang the test.
SETTLE_SECONDS = 10.0


def gpg_children() -> list[int]:
    """Process IDs of the gpg processes this process started."""
    found: list[int] = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", encoding="utf-8") as handle:
                stat = handle.read()
            with open(f"/proc/{entry}/comm", encoding="utf-8") as handle:
                comm = handle.read().strip()
        except OSError:
            continue
        # The command name sits in parentheses and may hold spaces; the
        # parent's ID is the second field after it.
        parent = int(stat.rsplit(")", 1)[1].split()[1])
        if parent == os.getpid() and comm in ("gpg", "gpg2"):
            found.append(int(entry))
    return found


def sleeping(pid: int) -> bool:
    """Whether the process is blocked waiting, or has exited."""
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as handle:
            return handle.read().rsplit(")", 1)[1].split()[0] == "S"
    except OSError:
        return True


def agent_pid(config: Config) -> int:
    """Process ID of the home's gpg-agent, which the import started."""
    reply = subprocess.run(
        ["gpg-connect-agent", "--homedir", config.gnupg_home, "GETINFO pid", "/bye"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return int(next(line for line in reply.splitlines() if line.startswith("D "))[2:])


class PausedSession:
    """Answer the server's passphrase prompts with gpg paused between secrets.

    gpg asks the agent to re-protect each secret in turn. After one, the
    agent keeps the old and new passphrases cached and answers the next
    secret from that cache. Pausing gpg there for longer than
    max-cache-ttl lets the cache expire, so the agent asks for the next
    secret's passphrases again: what a busy runner does by chance.

    The pause is synchronised with the agent, not timed against it. When
    the responder answers a prompt numbered in pause_after, the agent is
    stopped first, so it cannot re-protect that secret yet. Once gpg has
    read the answer (GOT_IT) and sleeps waiting on the agent, gpg is
    stopped and the agent resumed: it re-protects the secret and replies
    to a gpg that cannot ask for the next one. gpg resumes PAUSE_SECONDS
    after the agent rewrites the key file. paused_at records when gpg was
    last stopped, and times when each prompt was answered.

    With misanswer_at, the prompt of that number is answered with the old
    passphrase where the responder gives the new one. With take_as_old,
    the responder takes the prompt of that number for an old-passphrase
    prompt, as it does when the agent has lost only its cached new
    passphrase. misanswered and taken record that each happened.

    Every process stopped is resumed in a finally clause, so a failing
    check never leaves gpg or the agent stopped.
    """

    def __init__(
        self,
        config: Config,
        pause_after: tuple[int, ...] = (2,),
        misanswer_at: int | None = None,
        take_as_old: int | None = None,
    ) -> None:
        self.directory: str = os.path.join(config.gnupg_home, "private-keys-v1.d")
        self.agent: int = agent_pid(config)
        self.pause_after: tuple[int, ...] = pause_after
        self.misanswer_at: int | None = misanswer_at
        self.take_as_old: int | None = take_as_old
        self.times: list[float] = []
        self.paused_at: float | None = None
        self.misanswered: bool = False
        self.taken: bool = False
        self.agent_stopped: bool = False
        self.stopped: list[int] = []
        self.before: dict[str, int] = {}
        self.original: Callable[..., object] = (
            server_common._ChangePasswordResponder.callback
        )

    def mtimes(self) -> dict[str, int]:
        found: dict[str, int] = {}
        for name in os.listdir(self.directory):
            if name.endswith(".key"):
                try:
                    found[name] = os.stat(
                        os.path.join(self.directory, name)
                    ).st_mtime_ns
                except FileNotFoundError:
                    continue
        return found

    def stop_agent(self) -> None:
        self.before = self.mtimes()
        os.kill(self.agent, signal.SIGSTOP)
        self.agent_stopped = True

    def resume(self) -> None:
        if self.agent_stopped:
            os.kill(self.agent, signal.SIGCONT)
            self.agent_stopped = False
        for pid in self.stopped:
            try:
                os.kill(pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        self.stopped = []

    def pause_gpg(self) -> None:
        deadline = time.monotonic() + SETTLE_SECONDS
        children = gpg_children()
        # Past GOT_IT, gpg sleeps only once it waits on the agent's reply
        while (
            not all(sleeping(pid) for pid in children) and time.monotonic() < deadline
        ):
            time.sleep(0.001)
        for pid in children:
            os.kill(pid, signal.SIGSTOP)
            self.stopped.append(pid)
        if self.stopped:
            self.paused_at = time.monotonic()
        os.kill(self.agent, signal.SIGCONT)
        self.agent_stopped = False
        while self.mtimes() == self.before and time.monotonic() < deadline:
            time.sleep(0.005)
        time.sleep(PAUSE_SECONDS)
        self.resume()

    def __enter__(self) -> "PausedSession":
        original = self.original
        constants = server_common.ourgpg.constants
        hidden = constants.STATUS_GET_HIDDEN
        got_it = constants.STATUS_GOT_IT

        def callback(responder: object, status: object, *rest: object) -> object:
            if (
                status == hidden
                and len(self.times) + 1 == self.take_as_old
                and hasattr(responder, "awaiting_new")
            ):
                responder.awaiting_new = False
                self.taken = True
            answer = original(responder, status, *rest)
            if status == got_it and self.agent_stopped:
                self.pause_gpg()
            if status != hidden:
                return answer
            self.times.append(time.monotonic())
            old_passphrase: object = getattr(responder, "old_passphrase", None)
            if (
                len(self.times) == self.misanswer_at
                and old_passphrase is not None
                and answer == getattr(responder, "new_passphrase", None)
            ):
                self.misanswered = True
                answer = old_passphrase
            if len(self.times) in self.pause_after:
                self.stop_agent()
            return answer

        server_common._ChangePasswordResponder.callback = callback
        return self

    def __exit__(self, *_: object) -> None:
        server_common._ChangePasswordResponder.callback = self.original
        self.resume()

    def asked_after_pause(self) -> bool:
        """Whether a secret asked for a passphrase after the last pause.

        Every secret's prompts come before the agent rewrites its key file,
        so such a prompt is a later secret's: proof the pause outlasted the
        agent's cache.
        """
        return self.paused_at is not None and any(
            when > self.paused_at for when in self.times
        )


def secret_states(
    config: Config, fingerprint: str, old: str
) -> list[tuple[str, bool, bool]]:
    """Return (usage, new unlocks, old unlocks) for each secret present."""
    key = server_common._gpg_open(config).get_key(fingerprint, True)
    return [
        (
            "sign" if subkey.can_sign else "encrypt",
            server_common._gpg_passphrase_unlocks(
                config, subkey.keygrip, NEW_PASSPHRASE.encode()
            ),
            server_common._gpg_passphrase_unlocks(config, subkey.keygrip, old.encode()),
        )
        for subkey in key.subkeys
        if subkey.secret
    ]


def test_reprotected_with_gpg_paused(
    label: str,
    key: str,
    old: str,
    secrets: int,
    pause_after: tuple[int, ...] = (2,),
    misanswer_at: int | None = None,
    take_as_old: int | None = None,
) -> None:
    """Re-protect key with gpg paused after the prompts in pause_after.

    Every secret must come out unlocked by the new passphrase and not by
    the old one, with the session's prompts arranged as asked.
    """
    config = server_home()
    try:
        with open(key, "rb") as key_file:
            fingerprint = server_common.gpg_import_key(config, key_file)
        error = ""
        with PausedSession(config, pause_after, misanswer_at, take_as_old) as session:
            try:
                server_common.gpg_change_password(
                    config, fingerprint, old, NEW_PASSPHRASE
                )
            except Exception as raised:
                # A secret left on the old passphrase surfaces as GPGError.
                error = type(raised).__name__
        arranged = session.asked_after_pause()
        if misanswer_at is not None:
            arranged = arranged and session.misanswered
        if take_as_old is not None:
            arranged = arranged and session.taken
        states = secret_states(config, fingerprint, old)
    finally:
        stop(config)
    check(
        f"{label} has every secret re-protected with gpg paused",
        arranged
        and not error
        and len(states) == secrets
        and all(new and not was_old for _, new, was_old in states),
        f"{len(session.times)} prompts; "
        + f"prompted after a {PAUSE_SECONDS} s pause: {arranged}; "
        + f"error {error or 'none'}; "
        + f"(secret, new unlocks, old unlocks): {states}",
    )


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
        logged = Logged()
        logging.getLogger().addHandler(logged)
        try:
            server_common._check_subkey_only_rewrap(
                config, stored, old.encode(), NEW_PASSPHRASE, "gpg-exit 33554433"
            )
            outcome = "accepted"
        except server_common.GPGError as error:
            outcome = f"refused: {error}"
        finally:
            logging.getLogger().removeHandler(logged)
        check(
            "a key with one secret left on the old passphrase is refused",
            outcome.startswith("refused"),
            f"signing secret re-protected, encryption secret not: {outcome}",
        )
        left_behind = [keygrip for keygrip, can_sign in secrets if not can_sign]
        check(
            "the refusal's log names the secret left behind",
            any(left_behind[0] in message for message in logged.messages),
            f"logged: {logged.messages or 'nothing'}",
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
        left = key_files_left(config)
        check(
            f"a wrong passphrase on {label} is refused, and cleaned up",
            error == "GPGError" and not left,
            f"raised {error or 'nothing'}, key files left: {left or 'none'}",
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
    # server_common logs through the root logger. Configure it here, as its
    # first message otherwise would, so that capturing a refusal's log in
    # one check does not take the others' off standard error.
    logging.basicConfig()
    print("Server subkey-only import regression tests")
    print(f"server_common: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    work = tempfile.mkdtemp(prefix="w", dir="/tmp")
    try:
        subkey_key = decode("sigul-import-subkey-test-key", work)
        full_key = decode("sigul-import-test-key", work)
        test_subkey_only_import(subkey_key)
        test_every_secret_is_reprotected(work)
        old = "two-secret-import-passphrase"
        test_reprotected_with_gpg_paused(
            "a subkey-only key with signing and encryption secrets",
            make_two_secret_key(work, old),
            old,
            secrets=2,
        )
        test_reprotected_with_gpg_paused(
            "a complete key with an encryption subkey",
            make_key(work, old, ("encr",), subkeys_only=False),
            old,
            secrets=2,
        )
        # The fourth prompt is the second secret's new passphrase (#190)
        test_reprotected_with_gpg_paused(
            "a complete key whose second secret gets the old passphrase as new",
            make_key(work, old, ("encr",), subkeys_only=False),
            old,
            secrets=2,
            misanswer_at=4,
        )
        # Taken for an old-passphrase prompt, the fourth leaves the server
        # expecting the new passphrase when the third secret asks for its
        # old one, which fails the session (#190)
        test_reprotected_with_gpg_paused(
            "a complete key whose session fails at its third secret",
            make_key(work, old, ("encr", "sign"), subkeys_only=False),
            old,
            secrets=3,
            pause_after=(2, 4),
            take_as_old=4,
        )
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
