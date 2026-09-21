#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for client admission on the bridge.
#
# The bridge pairs one client with one server at a time, but before
# ClientAdmission it also accepted clients one at a time and handshaked
# each on the accept loop's critical path. Twenty connections that
# never sent a ClientHello, queued ahead of an honest client, kept it
# waiting for twenty handshake deadlines - the soak harness measured
# the stall as `client_backlog_flood`.
#
# These checks run a real TLS listener from a throwaway NSS database
# and put real peers against ClientAdmission.wait_for_client(): silent
# ones, an honest one, a peer whose certificate is not trusted. They
# assert the honest client is served in milliseconds regardless of how
# many silent peers are ahead of it, that silent peers are shed at the
# deadline, that the deadline is charged only for time the bridge
# spends waiting for a client, and that the loss of the server is
# reported. Nothing here touches the network beyond loopback.
#
# The last two checks cover the server side of the same question
# (patch 14): a peer that connects to the server port and leaves is
# reported as a fact, not as a failure with a traceback, while a
# genuine handshake failure keeps both. Since the server's entrypoint
# no longer probes the bridge with a TCP connect, nothing else
# exercises that path.
#
# Run inside the sigul bridge or server image, which provides
# python-nss and certutil:
#   python3 test/test_bridge_client_admission.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false
#
# bridge, double_tls and python-nss ship no type stubs, and the first
# two are upstream code this repository only patches, so their members
# are untyped by nature. The Protocols below name the slices the checks
# call.

import logging
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import types
from collections.abc import Callable
from typing import Protocol, cast, final, override

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import bridge  # noqa: E402
import nss.error  # noqa: E402
import nss.io  # noqa: E402
import nss.nss  # noqa: E402
import nss.ssl  # noqa: E402
import utils  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(bridge, "ClientAdmission")
DEADLINE = float(getattr(bridge, "_HANDSHAKE_TIMEOUT_SECONDS", 5))

# How long an honest client may take to be admitted with silent peers
# ahead of it. Generous next to the milliseconds it actually takes,
# and far below a single handshake deadline, which is what the old
# code charged per silent peer.
ADMIT_BOUND = 1.0

NICKNAME = "admission-test"
CA_NICKNAME = "admission-test-ca"


class Certificate(Protocol):
    """The slice of nss.nss.Certificate these checks touch."""

    @property
    def subject_common_name(self) -> str: ...


class NsprSocket(Protocol):
    """The slice of nss.io.Socket / nss.ssl.SSLSocket these checks touch."""

    def get_socket_option(self, option: int) -> bool: ...
    def get_peer_certificate(self) -> Certificate: ...
    def close(self) -> None: ...


class Admission(Protocol):
    """bridge.ClientAdmission's one public method."""

    def wait_for_client(self, server_sock: NsprSocket) -> NsprSocket | None: ...


# What one bounded wait_for_client() produced: elapsed seconds and the
# admitted socket (None when the server was lost), or None if it hung.
WaitResult = tuple[float, NsprSocket | None] | None
# What one honest client thread produced: its socket, or the error.
ClientOutcome = NsprSocket | BaseException


def check(label: str, got: object, want: object) -> None:
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'}  {label}: got {got!r}, want {want!r}")
    if not ok:
        FAILURES.append(label)


def run_bounded(fn: Callable[[], NsprSocket | None], limit: float) -> WaitResult:
    """Run fn in a thread. Return (elapsed, result), or None if it hung.

    An exception from fn is re-raised here, so a function that exits by
    raising cannot pass as one that returned.
    """
    done = threading.Event()
    failure: list[BaseException] = []
    result: list[NsprSocket | None] = []

    def wrapper() -> None:
        try:
            result.append(fn())
        except BaseException as e:
            failure.append(e)
        finally:
            done.set()

    started = time.monotonic()
    thread = threading.Thread(target=wrapper, daemon=True)
    thread.start()
    if not done.wait(limit):
        return None
    elapsed = time.monotonic() - started
    thread.join(5)
    if failure:
        raise failure[0]
    return elapsed, result[0]


def _make_nss_db() -> str:
    """A fresh NSS database: a CA and one leaf cert usable both ways.

    Mirrors the real PKI - a trusted CA issuing an end-entity cert with
    both serverAuth and clientAuth - because NSS will not validate a
    self-signed end-entity certificate as its own trust anchor.
    """
    directory = tempfile.mkdtemp(prefix="sigul-admission-")
    noise = os.path.join(directory, "noise")
    with open(noise, "wb") as f:
        _ = f.write(os.urandom(2048))
    db = f"sql:{directory}"
    _ = subprocess.run(["certutil", "-N", "-d", db, "--empty-password"], check=True)
    _ = subprocess.run(
        [
            "certutil", "-S", "-d", db, "-n", CA_NICKNAME,
            "-s", "CN=Admission Test CA", "-x", "-t", "CT,C,C", "-m", "1",
            "-v", "1", "-g", "2048", "-z", noise,
            "--keyUsage", "certSigning,crlSigning", "-2",
        ],
        input=b"y\n-1\ny\n",
        check=True,
        capture_output=True,
    )  # fmt: skip
    _ = subprocess.run(
        [
            "certutil", "-S", "-d", db, "-n", NICKNAME,
            "-s", "CN=localhost", "-c", CA_NICKNAME, "-t", "u,u,u", "-m", "2",
            "-v", "1", "-g", "2048", "-z", noise,
            "--keyUsage", "digitalSignature,keyEncipherment",
            "--extKeyUsage", "serverAuth,clientAuth",
            "-8", "localhost",
        ],
        check=True,
        capture_output=True,
    )  # fmt: skip
    return db


def _config(nss_dir: str) -> types.SimpleNamespace:
    return types.SimpleNamespace(
        nss_dir=nss_dir,
        nss_password="",
        nss_min_tls="tls1.2",
        nss_max_tls="tls1.3",
        bridge_cert_nickname=NICKNAME,
    )


def _recv_until_closed(peer: socket.socket, timeout: float) -> bool:
    """Block until the bridge closes peer. Return False if it did not in time."""
    peer.settimeout(timeout)
    try:
        data = peer.recv(1)
    except TimeoutError:
        return False
    except OSError:
        return True
    if data:
        FAILURES.append("silent peer received data")
    return True


@final
class Fixture:
    """A listening bridge socket, its admission object and a fake server.

    One per test: ClientAdmission is single-threaded by design, so a
    wait that overruns its bound must not be joined by another on the
    same object.
    """

    def __init__(self, config: types.SimpleNamespace) -> None:
        self.config = config
        self.listen_sock = bridge.create_listen_sock(config, 0)
        self.port: int = self.listen_sock.get_sock_name().port
        self.admission = cast(Admission, bridge.ClientAdmission(self.listen_sock))
        # The "server" is one end of a loopback pair: it never speaks,
        # exactly like a real server waiting for a client, and closing
        # the other end is how the server's loss is simulated.
        pair = nss.io.Socket.new_tcp_pair()
        self.server_sock = cast(NsprSocket, pair[0])
        self.server_peer = cast(NsprSocket, pair[1])
        self.cert = nss.nss.find_cert_from_nickname(NICKNAME)
        self.hung = False

    def silent_peer(self) -> socket.socket:
        return socket.create_connection(("127.0.0.1", self.port))

    def honest_client(
        self, trust: bool = True
    ) -> tuple[threading.Thread, list[ClientOutcome]]:
        """Connect a real TLS client in a thread; its outcome lands in the list."""
        outcome: list[ClientOutcome] = []

        def approve(*_args: object) -> bool:
            # The CA is trusted by the database, but decide explicitly
            # (or refuse to) so the check is independent of what
            # certutil recorded.
            return trust

        def run() -> None:
            sock = nss.ssl.SSLSocket(nss.io.PR_AF_INET)
            sock.set_client_auth_data_callback(
                utils.nss_client_auth_callback_single, self.cert
            )
            sock.set_hostname("localhost")
            sock.set_auth_certificate_callback(approve)
            try:
                sock.connect(nss.io.NetworkAddress(nss.io.PR_IpAddrLoopback, self.port))
                sock.force_handshake()
                outcome.append(cast(NsprSocket, sock))
            except nss.error.NSPRError as e:
                outcome.append(e)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread, outcome

    def wait(self, limit: float) -> WaitResult:
        """wait_for_client() bounded by limit; None marks the fixture unusable."""
        result = run_bounded(
            lambda: self.admission.wait_for_client(self.server_sock), limit
        )
        if result is None:
            self.hung = True
        return result

    def replace_server(self) -> None:
        """A fresh server connection, as after the real server reconnects."""
        pair = nss.io.Socket.new_tcp_pair()
        self.server_sock = cast(NsprSocket, pair[0])
        self.server_peer = cast(NsprSocket, pair[1])

    def wait_in_background(
        self, limit: float
    ) -> tuple[threading.Thread, list[WaitResult]]:
        outcome: list[WaitResult] = []
        thread = threading.Thread(
            target=lambda: outcome.append(self.wait(limit)), daemon=True
        )
        thread.start()
        return thread, outcome

    def serve_one(self, waiter: threading.Thread) -> None:
        """Connect an honest client so a background wait can return."""
        thread, _ = self.honest_client()
        waiter.join(DEADLINE)
        thread.join(2)


def test_honest_client_behind_silent_peers(fx: Fixture) -> None:
    """Twenty silent peers ahead must not delay an honest client."""
    silent = [fx.silent_peer() for _ in range(20)]
    time.sleep(0.2)  # let them all queue before the client connects
    thread, outcome = fx.honest_client()
    result = fx.wait(DEADLINE)
    check("honest client admitted with 20 silent peers ahead", result is not None, True)
    if result is None:
        return
    elapsed, client = result
    if client is None:
        FAILURES.append("wait returned None with the server still connected")
        return
    check(f"... within {ADMIT_BOUND}s, not 20 deadlines", elapsed < ADMIT_BOUND, True)
    check(
        "... with its handshake complete",
        client.get_peer_certificate().subject_common_name,
        "localhost",
    )
    check(
        "... in blocking mode",
        client.get_socket_option(nss.io.PR_SockOpt_Nonblocking),
        False,
    )
    thread.join(2)
    check(
        "... and the client side agrees",
        isinstance(outcome[0], nss.ssl.SSLSocket),
        True,
    )
    client.close()
    # The silent peers are still pending. They must all be shed one
    # deadline into the next wait, and every one must see the bridge
    # close on it.
    started = time.monotonic()
    waiter, _ = fx.wait_in_background(DEADLINE * 3)
    seen: list[float] = []
    for peer in silent:
        if _recv_until_closed(peer, DEADLINE * 3):
            seen.append(time.monotonic() - started)
    check("all 20 silent peers dropped", len(seen), 20)
    check(
        f"... at about the {DEADLINE:.0f}s deadline",
        all(DEADLINE - 0.5 <= t <= DEADLINE + 1.5 for t in seen),
        True,
    )
    fx.serve_one(waiter)
    check("waiter returned after the drops", waiter.is_alive(), False)


def test_deadline_charged_only_while_attended(fx: Fixture) -> None:
    """A peer pending while the bridge is busy is not charged for that time."""
    peer = fx.silent_peer()
    time.sleep(0.2)
    # First wait: the peer is accepted and attended for a moment, then
    # an honest client wins and the wait returns. The peer has spent
    # only a fraction of its deadline.
    thread, _ = fx.honest_client()
    result = fx.wait(DEADLINE)
    thread.join(2)
    check("client admitted while a silent peer is pending", result is not None, True)
    if result is None or result[1] is None:
        return
    result[1].close()
    # "Busy" for longer than the whole deadline: no wait_for_client()
    # call in progress, as during a request.
    time.sleep(DEADLINE + 1)
    check(
        "silent peer still pending after an unattended deadline",
        _recv_until_closed(peer, 0.2),
        False,
    )
    # Attended again: now its clock runs and it is shed at the deadline,
    # measured from here rather than from accept().
    started = time.monotonic()
    waiter, _ = fx.wait_in_background(DEADLINE * 3)
    _ = _recv_until_closed(peer, DEADLINE * 3)
    dropped_after = time.monotonic() - started
    check(
        f"... then dropped about {DEADLINE:.0f}s of attention later",
        DEADLINE - 1.0 <= dropped_after <= DEADLINE + 1.5,
        True,
    )
    fx.serve_one(waiter)


def test_rejected_client_does_not_end_the_wait(fx: Fixture) -> None:
    """A client that fails its handshake is dropped; the wait goes on."""
    waiter, outcome = fx.wait_in_background(DEADLINE * 2)
    time.sleep(0.2)
    # With the bridge attending, a client that refuses the bridge's
    # certificate fails its own handshake and sends an alert; the bridge
    # must drop it and keep waiting rather than return it or give up.
    thread, refused = fx.honest_client(trust=False)
    thread.join(DEADLINE)
    check(
        "untrusting client failed its own handshake",
        len(refused) == 1 and isinstance(refused[0], nss.error.NSPRError),
        True,
    )
    time.sleep(0.2)
    check("the wait is still in progress", waiter.is_alive(), True)
    fx.serve_one(waiter)
    result = outcome[0] if outcome else None
    check("next honest client admitted after a rejected one", result is not None, True)
    if result is not None and result[1] is not None:
        check(
            "... and it is the honest one",
            result[1].get_peer_certificate().subject_common_name,
            "localhost",
        )
        result[1].close()


def test_server_loss_reported(fx: Fixture) -> None:
    """Losing the server while waiting returns None promptly.

    The pending set outlives the pairing, so the time a peer was
    attended before the server went must still count against it.
    """
    attended_before_loss = DEADLINE / 2
    peer = fx.silent_peer()
    time.sleep(0.2)

    def close_server_soon() -> None:
        time.sleep(attended_before_loss)
        fx.server_peer.close()

    threading.Thread(target=close_server_soon, daemon=True).start()
    result = fx.wait(DEADLINE)
    check("server loss ends the wait", result is not None, True)
    if result is None:
        return
    elapsed, value = result
    check("... returning None", value, None)
    check(
        "... promptly, not at the peer's deadline",
        elapsed < attended_before_loss + 1.0,
        True,
    )
    # A new server pairs. The peer was attended for half its deadline
    # before the loss, so it has half left, not a full deadline.
    fx.replace_server()
    started = time.monotonic()
    waiter, _ = fx.wait_in_background(DEADLINE * 3)
    _ = _recv_until_closed(peer, DEADLINE * 3)
    dropped_after = time.monotonic() - started
    remaining = DEADLINE - attended_before_loss
    check(
        f"attention before the loss still counts: dropped about {remaining:.1f}s in",
        remaining - 1.0 <= dropped_after <= remaining + 1.0,
        True,
    )
    fx.serve_one(waiter)


class _Captured(logging.Handler):
    """Collects log records so a test can assert on level and message."""

    def __init__(self) -> None:
        super().__init__(level=logging.DEBUG)
        self.records: list[logging.LogRecord] = []

    @override
    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)

    def noisy(self) -> list[tuple[str, int, bool]]:
        """Records that would draw the eye: high level, or a traceback.

        Both halves matter. A record logged at INFO still prints a
        traceback if it carries exc_info, which is most of what made
        the original startup log alarming, so testing the level alone
        would let the thing being fixed back in.
        """
        return [
            (r.getMessage()[:60], r.levelno, r.exc_info is not None)
            for r in self.records
            if r.levelno >= logging.WARNING or r.exc_info is not None
        ]

    def saying(self, fragment: str) -> list[logging.LogRecord]:
        return [r for r in self.records if fragment in r.getMessage()]


def _install_capture() -> tuple[_Captured, Callable[[], None]]:
    """Attach a capturing handler to the root logger; return it and its undo."""
    handler = _Captured()
    root = logging.getLogger()
    previous = root.level
    root.setLevel(logging.DEBUG)
    root.addHandler(handler)

    def restore() -> None:
        root.removeHandler(handler)
        root.setLevel(previous)

    return handler, restore


def _bridge_one_request_against(
    fx: Fixture, misbehave: Callable[[int], None]
) -> _Captured | None:
    """Run one accept cycle against a peer that misbehaves on the server port.

    Returns the captured log, or None if the call did not return in time.
    """
    server_listen = bridge.create_listen_sock(fx.config, 0)
    port: int = server_listen.get_sock_name().port
    threading.Thread(target=misbehave, args=(port,), daemon=True).start()

    def one_cycle() -> None:
        bridge.bridge_one_request(fx.config, server_listen, fx.admission)

    log, restore = _install_capture()
    try:
        done = run_bounded(one_cycle, DEADLINE * 3)
    finally:
        restore()
    server_listen.close()
    return log if done is not None else None


def test_vanished_server_peer_is_quiet(fx: Fixture) -> None:
    """A peer that connects to the server port and leaves is not an error.

    This is the path a health check, a port scanner or a load balancer
    takes. Nothing else exercises it now that the server's entrypoint no
    longer probes the bridge with a TCP connect, so without this check a
    regression would be silent.

    Both ways of leaving are covered, because the fix names both: a
    clean FIN raises PR_END_OF_FILE_ERROR, an abortive close raises
    PR_CONNECT_RESET_ERROR, and dropping either from the fix should
    fail here.
    """

    def connect_and_hang_up(port: int) -> None:
        socket.create_connection(("127.0.0.1", port)).close()

    def connect_and_reset(port: int) -> None:
        sock = socket.create_connection(("127.0.0.1", port))
        # Linger zero turns close() into an immediate RST.
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        sock.close()

    for label, misbehave in (("FIN", connect_and_hang_up), ("RST", connect_and_reset)):
        log = _bridge_one_request_against(fx, misbehave)
        check(
            f"[{label}] a vanished server peer ends the accept cycle",
            log is not None,
            True,
        )
        if log is None:
            continue
        check(
            f"[{label}] ... logged once, at INFO, as 'went away'",
            [r.levelno for r in log.saying("went away during its TLS handshake")],
            [logging.INFO],
        )
        check(f"[{label}] ... with nothing loud and no traceback", log.noisy(), [])


def test_real_handshake_failure_still_loud(fx: Fixture) -> None:
    """A genuine protocol failure keeps its error and its traceback.

    The peer sends a TLS record header declaring a length no record may
    have, which NSS rejects the moment it reads it -
    SSL_ERROR_RX_RECORD_TOO_LONG. That is the shape of failure the fix
    must leave alone: not a peer going away, so it is still logged at
    ERROR and still re-raised, and the re-raise is what produces the
    traceback from the handler above.

    Asserting the traceback matters because it is the only externally
    visible consequence of the re-raise. A fix that logged the error and
    then swallowed the exception would look identical without it.
    """
    held: list[socket.socket] = []

    def send_oversized_record(port: int) -> None:
        sock = socket.create_connection(("127.0.0.1", port))
        held.append(sock)  # keep it open, or this is just another EOF
        sock.sendall(bytes.fromhex("160301ffff") + b"A" * 64)
        time.sleep(DEADLINE * 2)

    log = _bridge_one_request_against(fx, send_oversized_record)
    check("a bad handshake ends the accept cycle", log is not None, True)
    if log is None:
        return
    check(
        "... logged as a handshake failure at ERROR",
        [r.levelno for r in log.saying("Server TLS handshake failed")],
        [logging.ERROR],
    )
    check(
        "... and re-raised, so a traceback is still produced",
        any(r.exc_info is not None for r in log.records),
        True,
    )
    check(
        "... and not mistaken for a peer going away",
        log.saying("went away during its TLS handshake"),
        [],
    )
    for sock in held:
        sock.close()


def main() -> int:
    logging.basicConfig(level=logging.WARNING, format="        bridge: %(message)s")
    print("bridge client admission regression tests")
    print(
        f"bridge: {'PATCHED' if PATCHED else 'UNPATCHED'}  (deadline={DEADLINE:.0f}s)"
    )
    print()
    if not PATCHED:
        print("FAIL  bridge.ClientAdmission is missing; nothing to test")
        return 1
    config = _config(_make_nss_db())
    utils.nss_init(config)
    for test in (
        test_honest_client_behind_silent_peers,
        test_deadline_charged_only_while_attended,
        test_rejected_client_does_not_end_the_wait,
        test_server_loss_reported,
        test_vanished_server_peer_is_quiet,
        test_real_handshake_failure_still_loud,
    ):
        print(f"-- {test.__name__}")
        fx = Fixture(config)
        test(fx)
        if fx.hung:
            print(
                "FAIL  a wait overran its bound; later checks on this fixture skipped"
            )
            FAILURES.append(f"{test.__name__}: wait_for_client hung")
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("client admission holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
