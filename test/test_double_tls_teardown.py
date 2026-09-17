#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for the double-TLS teardown deadlock.
#
# Production failure this locks down: a peer that receives our FIN but
# never sends its own left the forwarding child in an unbounded poll(),
# which left outer_close() in an unbounded waitpid(), which left the
# daemon's main loop blocked on that. Three processes wedged, the
# service answering nothing further, while the process was still
# present and the liveness check still passed.
#
# The checks are behavioural, not structural: each runs the real code
# with a deliberately misbehaving peer and asserts it returns. Against
# unpatched sigul they hang, and the bounded join below reports that as
# a failure rather than hanging the run.
#
# Run inside the sigul server image, which provides python-nss:
#   python3 test/test_double_tls_teardown.py

# pyright: reportUnusedFunction=false, reportUnknownMemberType=false
# pyright: reportUnknownArgumentType=false, reportUnknownVariableType=false
#
# The stub buffer's methods are never called from this file: they are
# invoked by forward_two_way() through duck typing, so the checker
# cannot see the call sites. double_tls itself ships no type stubs, and
# it is upstream code this repository only patches, so its members are
# untyped by nature.

import os
import sys
import threading
import time
from collections.abc import Callable
from typing import final

# Where to import double_tls from. Defaults to the installed location;
# set SIGUL_LIB to test a build tree or a patched copy before it ships.
sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import double_tls  # noqa: E402

FAILURES: list[str] = []

# Bounds the patch introduces. Fall back to generous values so the
# checks still execute - and fail honestly - against unpatched code.
LINGER = getattr(double_tls, "_SHUTDOWN_LINGER_SECONDS", 30)
CHILD_TIMEOUT = getattr(double_tls, "_CHILD_EXIT_TIMEOUT_SECONDS", 10)
PATCHED = hasattr(double_tls, "_SHUTDOWN_LINGER_SECONDS")


def check(label: str, got: object, want: object) -> None:
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'}  {label}: got {got!r}, want {want!r}")
    if not ok:
        FAILURES.append(label)


def run_bounded(fn: Callable[[], None], limit: float) -> float | None:
    """Run fn in a thread. Return elapsed seconds, or None if it hung."""
    done = threading.Event()

    def wrapper() -> None:
        try:
            fn()
        finally:
            done.set()

    started = time.monotonic()
    threading.Thread(target=wrapper, daemon=True).start()
    if not done.wait(limit):
        return None
    return time.monotonic() - started


@final
class _Buffer:
    """Minimal _ForwardingBuffer stand-in; does nothing, makes no progress."""

    def __init__(self, active: bool) -> None:
        self._active_value: bool = active

    @property
    def _active(self) -> bool:
        return self._active_value

    def _prepare_poll(self, descs: object) -> None:
        del descs  # protocol stub: nothing to forward

    def _handle_errors(self, descs: object) -> None:
        del descs  # protocol stub: nothing to forward

    def _send(self, descs: object) -> None:
        del descs  # protocol stub: nothing to forward

    def _receive(self, descs: object) -> None:
        del descs  # protocol stub: nothing to forward

    def _check_shutdown(self) -> None:
        pass


def test_teardown_is_bounded() -> None:
    """Local side closed + peer that never closes must not block forever."""

    def body() -> None:
        double_tls._ForwardingBuffer.forward_two_way(_Buffer(False), _Buffer(True))

    elapsed = run_bounded(body, LINGER + 20)
    check("forward_two_way returns after local shutdown", elapsed is not None, True)
    if elapsed is not None:
        print(f"     returned after {elapsed:.1f}s (linger {LINGER}s)")
    else:
        print(f"     STILL BLOCKED after {LINGER + 20}s - this is the deadlock")


def test_idle_still_blocks() -> None:
    """An idle connection must keep waiting; the daemon idles for hours."""

    def body() -> None:
        double_tls._ForwardingBuffer.forward_two_way(_Buffer(True), _Buffer(True))

    elapsed = run_bounded(body, LINGER + 10)
    check("idle loop keeps waiting", elapsed is None, True)
    if elapsed is None:
        print(f"     still polling after {LINGER + 10}s, as intended")
    else:
        print(f"     RETURNED after {elapsed:.1f}s - idle behaviour was broken")


def test_wedged_child_is_reaped() -> None:
    """outer_close() must not block on a child that will not exit."""
    if not hasattr(double_tls.DoubleTLSClient, "_DoubleTLSClient__reap_child"):
        check("__reap_child exists (bounded child wait)", False, True)
        print("     unpatched: outer_close() uses a blocking waitpid()")
        return

    client = double_tls.DoubleTLSClient.__new__(double_tls.DoubleTLSClient)
    pid = os.fork()
    if pid == 0:
        try:
            while True:
                time.sleep(60)
        finally:
            os._exit(0)
    client._DoubleTLSClient__child_pid = pid

    result: dict[str, int] = {}

    def body() -> None:
        result["status"] = client._DoubleTLSClient__reap_child()

    elapsed = run_bounded(body, CHILD_TIMEOUT + 15)
    check("__reap_child returns", elapsed is not None, True)
    if elapsed is None:
        print("     STILL BLOCKED - killing the stray child")
        try:
            os.kill(pid, 9)
            _ = os.waitpid(pid, 0)
        except OSError:
            pass
        return
    print(f"     returned after {elapsed:.1f}s (timeout {CHILD_TIMEOUT}s)")
    check("wedged child was killed", os.WIFSIGNALED(result["status"]), True)
    try:
        os.kill(pid, 0)
        check("child reaped", False, True)
    except OSError:
        check("child reaped", True, True)


def main() -> int:
    print("double-TLS teardown regression tests")
    state = "PATCHED" if PATCHED else "UNPATCHED"
    print(f"double_tls: {state}  (linger={LINGER}s, child-exit={CHILD_TIMEOUT}s)")
    print()
    test_teardown_is_bounded()
    test_idle_still_blocks()
    test_wedged_child_is_reaped()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("all teardown bounds hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
