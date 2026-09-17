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

import inspect
import os
import re
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
TICK = getattr(double_tls, "_SHUTDOWN_POLL_TICK_SECONDS", 1)
CHILD_TIMEOUT = getattr(double_tls, "_CHILD_EXIT_TIMEOUT_SECONDS", 10)
PATCHED = hasattr(double_tls, "_SHUTDOWN_LINGER_SECONDS")


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
    _wait_single_threaded()
    if failure:
        raise failure[0]
    return elapsed


def _wait_single_threaded() -> None:
    """Wait for the last worker's OS thread to finish leaving.

    join() returns before the thread has fully exited, and the checks
    that fork() next warn about forking a multi-threaded process.
    """
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        with open("/proc/self/status") as f:
            threads = [line for line in f if line.startswith("Threads:")]
        if threads and threads[0].split()[1] == "1":
            return
        time.sleep(0.01)


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


def _forward(buf_1: _Buffer, buf_2: _Buffer, linger: int | None) -> None:
    """Call forward_two_way() with the linger where the signature allows it."""
    if PATCHED:
        double_tls._ForwardingBuffer.forward_two_way(buf_1, buf_2, linger)
    else:
        double_tls._ForwardingBuffer.forward_two_way(buf_1, buf_2)


def test_teardown_is_bounded() -> None:
    """Local side closed + peer that never closes must not block forever."""

    def body() -> None:
        _forward(_Buffer(False), _Buffer(True), LINGER)

    elapsed = run_bounded(body, LINGER + 20)
    check("forward_two_way returns after local shutdown", elapsed is not None, True)
    if elapsed is not None:
        print(f"     returned after {elapsed:.1f}s (linger {LINGER}s)")
    else:
        print(f"     STILL BLOCKED after {LINGER + 20}s - this is the deadlock")


def test_bridge_forwarding_has_no_linger() -> None:
    """Without a linger requested, one side inactive must not end the loop.

    The bridge's inner-stream forwarding shares this primitive, and there
    buf_1 inactive means only that the client has finished its half of
    the inner session while the server's half is still in flight. A
    linger applied unconditionally would abandon live requests.
    """

    def body() -> None:
        _forward(_Buffer(False), _Buffer(True), None)

    elapsed = run_bounded(body, LINGER + 5)
    check("forwarding without linger keeps waiting", elapsed is None, True)
    if elapsed is None:
        print(f"     still polling after {LINGER + 5}s, as the bridge needs")
    else:
        print(f"     RETURNED after {elapsed:.1f}s - the bridge would drop requests")


def test_idle_still_blocks() -> None:
    """An idle connection must keep waiting; the daemon idles for hours."""

    def body() -> None:
        _forward(_Buffer(True), _Buffer(True), LINGER)

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


def test_linger_completes_before_kill() -> None:
    """The graceful bound must fire before the kill, on the real path.

    outer_close() closes the local pipes and immediately reaps. The
    forwarding child's linger is its chance to close cleanly; if the
    reap timeout were shorter, every teardown against a silent peer
    would end in SIGKILL and the linger would never run in production.
    """
    if not hasattr(double_tls.DoubleTLSClient, "_DoubleTLSClient__reap_child"):
        check("reap timeout exceeds linger", False, True)
        print("     unpatched: no bounds to compare")
        return

    check("reap timeout exceeds linger + tick", CHILD_TIMEOUT > LINGER + TICK, True)

    # The real outer_close(): closes both pipes, reaps, inspects status.
    client = double_tls.DoubleTLSClient.__new__(double_tls.DoubleTLSClient)
    client._DoubleTLSClient__inner_pipe = _ClosablePipe()
    client._DoubleTLSClient__outer_pipe = _ClosablePipe()
    pid = os.fork()
    if pid == 0:
        try:
            # What __child() does once outer_close() has shut the pipes:
            # local side inactive, peer never closes.
            _forward(_Buffer(False), _Buffer(True), LINGER)
        finally:
            os._exit(0)
    client._DoubleTLSClient__child_pid = pid

    def body() -> None:
        client.outer_close()

    elapsed = run_bounded(body, CHILD_TIMEOUT + 15)
    check("outer_close returns", elapsed is not None, True)
    if elapsed is None:
        try:
            os.kill(pid, 9)
            _ = os.waitpid(pid, 0)
        except OSError:
            pass
        return
    print(
        f"     returned after {elapsed:.1f}s (linger {LINGER}s, kill at {CHILD_TIMEOUT}s)"
    )
    check("child exited before the kill deadline", elapsed < CHILD_TIMEOUT, True)
    try:
        os.kill(pid, 0)
        check("child reaped by outer_close", False, True)
    except OSError:
        check("child reaped by outer_close", True, True)


@final
class _ClosablePipe:
    """Stands in for the parent's end of a pipe; outer_close() only closes it."""

    def close(self) -> None:
        pass


def test_child_passes_linger() -> None:
    """__child() must request the linger; it is the only caller that should.

    Running __child() needs NSS and a TLS peer, so this is a source check.
    scripts/run-lifecycle-tests.sh phase 4 covers the same wiring
    behaviourally against the live stack.
    """
    if not PATCHED:
        check("__child() requests the shutdown linger", False, True)
        print("     unpatched: forward_two_way() takes no linger")
        return
    child_src = inspect.getsource(double_tls.DoubleTLSClient._DoubleTLSClient__child)
    call = re.search(r"forward_two_way\((.*?)\)", child_src, re.S)
    args = call.group(1) if call else ""
    check(
        "__child() requests the shutdown linger",
        "_SHUTDOWN_LINGER_SECONDS" in args,
        True,
    )
    bridge_src = inspect.getsource(double_tls.bridge_inner_stream)
    call = re.search(r"forward_two_way\((.*?)\)", bridge_src, re.S)
    args = call.group(1) if call else ""
    check("bridge_inner_stream() requests no linger", "LINGER" not in args, True)


def main() -> int:
    print("double-TLS teardown regression tests")
    state = "PATCHED" if PATCHED else "UNPATCHED"
    print(f"double_tls: {state}  (linger={LINGER}s, child-exit={CHILD_TIMEOUT}s)")
    print()
    # The checks that leave a thread parked in poll() for the rest of
    # the run go last, after the fork-based ones.
    test_teardown_is_bounded()
    test_wedged_child_is_reaped()
    test_linger_completes_before_kill()
    test_child_passes_linger()
    test_bridge_forwarding_has_no_linger()
    test_idle_still_blocks()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("all teardown bounds hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
