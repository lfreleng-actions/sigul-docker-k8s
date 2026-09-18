#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for poll results after a timeout.
#
# nss.io.Socket.poll() returns PR_Poll()'s out_flags without checking
# whether anything was ready. NSPR only fills those in when at least
# one descriptor has an event; on a timeout each out_flags keeps the
# scratch bits NSPR wrote while translating the request, which read as
# PR_POLL_READ (0x1) and PR_POLL_ERR (0x8). Every timed poll therefore
# saw phantom events: the request idle deadline in forward_two_way()
# was reset on every timeout and never fired, and a buffer waiting to
# write was dropped as if its destination had failed.
#
# The checks are behavioural: each runs the real code against sockets
# on which nothing happens and asserts what it reports. Against
# unpatched double_tls the first check reports readable idle sockets
# and the idle deadline never fires; the bounded join reports that as a
# failure rather than hanging the run.
#
# Run inside the sigul server or bridge image, which provides
# python-nss:
#   python3 test/test_nspr_poll_timeout.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false
#
# double_tls and python-nss ship no type stubs, and double_tls is
# upstream code this repository only patches, so their members are
# untyped by nature. The Protocol below names the few NSPR socket
# methods the checks call.

import contextlib
import os
import socket
import sys
import threading
import time
from collections.abc import Callable
from typing import Protocol, cast

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import double_tls  # noqa: E402
import nss.error  # noqa: E402
import nss.io  # noqa: E402
import nss.nss  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(double_tls, "poll_sockets")

# Short enough to keep the run quick, long enough that scheduling jitter
# cannot be mistaken for the deadline firing.
IDLE_SECONDS = 2


class NsprSocket(Protocol):
    """The slice of nss.io.Socket these checks touch."""

    def set_socket_option(self, option: int, value: bool) -> None: ...
    def send(self, data: bytes) -> int: ...
    def recv(self, size: int) -> bytes: ...


def check(label: str, got: object, want: object) -> None:
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'}  {label}: got {got!r}, want {want!r}")
    if not ok:
        FAILURES.append(label)


def run_bounded(fn: Callable[[], None], limit: float) -> float | None:
    """Run fn in a thread. Return elapsed seconds, or None if it hung.

    An exception from fn is re-raised here, so a function that exits by
    raising cannot pass as one that returned.
    """
    done = threading.Event()
    failure: list[BaseException] = []

    def wrapper() -> None:
        try:
            fn()
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
    return elapsed


def _idle_connection() -> tuple[socket.socket, NsprSocket]:
    """An accepted, non-blocking NSPR socket whose peer never speaks."""
    listener = nss.io.Socket(nss.io.PR_AF_INET)
    listener.set_socket_option(nss.io.PR_SockOpt_Reuseaddr, True)
    listener.bind(nss.io.NetworkAddress(nss.io.PR_IpAddrLoopback, 0))
    listener.listen(1)
    port = listener.get_sock_name().port
    peer = socket.create_connection(("127.0.0.1", port))
    accepted = cast(NsprSocket, listener.accept()[0])
    _ = listener.close()
    accepted.set_socket_option(nss.io.PR_SockOpt_Nonblocking, True)
    return peer, accepted


def _poll(descs: list[tuple[NsprSocket, int]], milliseconds: int) -> list[int]:
    timeout = nss.io.milliseconds_to_interval(milliseconds)
    if PATCHED:
        return list(double_tls.poll_sockets(descs, timeout))
    return list(nss.io.Socket.poll(descs, timeout))


def test_timeout_reports_no_events() -> None:
    """A poll that times out must report every descriptor idle."""
    _peer_a, a = _idle_connection()
    _peer_b, b = _idle_connection()
    flags = _poll([(a, nss.io.PR_POLL_READ), (b, nss.io.PR_POLL_READ)], 200)
    check("idle READ interests report nothing on timeout", flags, [0, 0])
    # A WRITE interest is where the scratch bit reads as PR_POLL_ERR.
    # Polling for WRITE alone would return at once - a fresh socket is
    # always writable - so the interest has to sit on a descriptor that
    # cannot take more data: fill the send buffer first.
    sink, full = _idle_connection()
    with contextlib.suppress(nss.error.NSPRError):  # PR_WOULD_BLOCK_ERROR: full
        while True:
            _ = full.send(b"\0" * 65536)
    flags = _poll([(a, nss.io.PR_POLL_READ), (full, nss.io.PR_POLL_WRITE)], 200)
    check("blocked WRITE interest reports nothing on timeout", flags, [0, 0])
    sink.close()


def test_events_still_reported() -> None:
    """Real events must come through unchanged, alone or mixed with idle ones."""
    peer_a, a = _idle_connection()
    _peer_b, b = _idle_connection()
    peer_a.sendall(b"x")
    time.sleep(0.05)
    flags = _poll([(a, nss.io.PR_POLL_READ), (b, nss.io.PR_POLL_READ)], 200)
    check("data on one socket is reported for that socket only", flags, [1, 0])
    _ = a.recv(1)
    flags = _poll([(a, nss.io.PR_POLL_READ), (b, nss.io.PR_POLL_WRITE)], 200)
    check("a writable socket is reported writable", flags, [0, nss.io.PR_POLL_WRITE])
    peer_a.close()
    time.sleep(0.05)
    flags = _poll([(a, nss.io.PR_POLL_READ), (b, nss.io.PR_POLL_READ)], 200)
    check("a peer's FIN is reported as readable", flags[0] & nss.io.PR_POLL_READ, 1)
    check("... and not attributed to the other socket", flags[1], 0)


def _forward_until_idle(
    a: NsprSocket, b: NsprSocket, raised: list[BaseException]
) -> None:
    """Bridge a and b with the idle deadline; record the IdleTimeoutError."""
    buf_1 = double_tls._InnerBridgingBuffer(a, b, [])
    buf_2 = double_tls._InnerBridgingBuffer(b, a, [])
    try:
        double_tls._ForwardingBuffer.forward_two_way(
            buf_1, buf_2, idle_timeout=IDLE_SECONDS
        )
    except double_tls.IdleTimeoutError as e:
        raised.append(e)


def test_idle_deadline_fires() -> None:
    """forward_two_way(idle_timeout=) must raise once nothing has moved."""
    _peer_a, a = _idle_connection()
    _peer_b, b = _idle_connection()
    raised: list[BaseException] = []
    elapsed = run_bounded(lambda: _forward_until_idle(a, b, raised), IDLE_SECONDS * 3)
    check("idle deadline fires", elapsed is not None and len(raised) == 1, True)
    if elapsed is not None:
        check(
            f"... at about {IDLE_SECONDS}s",
            IDLE_SECONDS - 0.5 <= elapsed <= IDLE_SECONDS + 1,
            True,
        )


def test_idle_deadline_reset_by_traffic() -> None:
    """Bytes crossing the bridge push the deadline back; silence then fires it."""
    peer_a, a = _idle_connection()
    _peer_b, b = _idle_connection()
    traffic_seconds = IDLE_SECONDS + 1

    def feeder() -> None:
        deadline = time.monotonic() + traffic_seconds
        while time.monotonic() < deadline:
            time.sleep(0.25)
            peer_a.sendall(b"z")

    threading.Thread(target=feeder, daemon=True).start()
    raised: list[BaseException] = []
    elapsed = run_bounded(
        lambda: _forward_until_idle(a, b, raised), traffic_seconds + IDLE_SECONDS * 3
    )
    expected = traffic_seconds + IDLE_SECONDS
    check(
        f"deadline fires about {IDLE_SECONDS}s after the last byte",
        elapsed is not None and expected - 0.5 <= elapsed <= expected + 1,
        True,
    )


def main() -> int:
    nss.nss.nss_init_nodb()
    print("NSPR poll timeout regression tests")
    print(f"double_tls: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    test_timeout_reports_no_events()
    test_events_still_reported()
    test_idle_deadline_fires()
    test_idle_deadline_reset_by_traffic()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("poll results are trustworthy after a timeout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
