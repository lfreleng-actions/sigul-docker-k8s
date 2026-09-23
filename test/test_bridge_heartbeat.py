#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for the bridge's liveness heartbeat (patch 15).
#
# Every health check the chart ran against the bridge tested state a
# wedged daemon keeps - a live process and a listening socket - so a
# frozen or stuck bridge stayed Ready indefinitely while every request
# hung. Patch 15 gives it a heartbeat file that a publisher thread keeps
# fresh only while the main loop is inside the bound it last declared,
# and the chart's liveness probe reads the file's age.
#
# The checks are behavioural, against the real Heartbeat class and the
# real double_tls hook, and cover both ways the heartbeat can be wrong:
#
# - stale when it should be fresh, which would let liveness kill a
#   healthy bridge - while it waits for a server, or for a peer that has
#   paused mid-request within its declared bound;
# - fresh when it should be stale, which is the defect itself - a main
#   loop that has overrun its bound, still beaten for by the thread.
#
# Timings are scaled down through the module's own constants, so the
# run takes seconds rather than minutes.
#
# Run inside the sigul bridge image:
#   python3 test/test_bridge_heartbeat.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# bridge and double_tls are upstream code this repository only patches,
# and ship no type stubs, so their members are untyped by nature.

import os
import sys
import tempfile
import time
from typing import Protocol, cast

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import bridge  # noqa: E402
import double_tls  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(bridge, "Heartbeat")

# Scaled down so each check takes a second or two: the publisher beats
# every INTERVAL, and slack of one INTERVAL is added to every bound.
INTERVAL = 0.2


class Heartbeat(Protocol):
    """The slice of bridge.Heartbeat these checks drive."""

    def progress(self, bound: float | None = None) -> None: ...
    def start(self) -> None: ...


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def _age(path: str) -> float:
    try:
        return time.time() - os.stat(path).st_mtime
    except OSError:
        return float("inf")


def _started(path: str) -> Heartbeat:
    hb = cast(Heartbeat, bridge.Heartbeat(path))
    hb.start()
    return hb


def test_publishes_while_progressing(directory: str) -> None:
    """A main loop that keeps reporting keeps the heartbeat fresh."""
    path = os.path.join(directory, "progressing")
    hb = _started(path)
    worst = 0.0
    for _ in range(15):
        hb.progress(INTERVAL)
        time.sleep(INTERVAL)
        worst = max(worst, _age(path))
    check(
        "fresh while the main loop reports",
        worst < 3 * INTERVAL,
        f"oldest {worst:.2f}s over {15 * INTERVAL:.1f}s, bound {3 * INTERVAL:.2f}s",
    )


def test_fresh_within_declared_bound(directory: str) -> None:
    """A long declared wait must not look like a wedge.

    This is the case a heartbeat beaten only from the main loop gets
    wrong: the bridge blocked on a slow peer, or waiting for a server
    that is restarting, is healthy, and must not be restarted.
    """
    path = os.path.join(directory, "declared")
    hb = _started(path)
    hb.progress(20 * INTERVAL)  # declare a long wait, then stay silent
    time.sleep(15 * INTERVAL)
    age = _age(path)
    check(
        "fresh throughout a long declared wait",
        age < 3 * INTERVAL,
        f"age {age:.2f}s after {15 * INTERVAL:.1f}s of a {20 * INTERVAL:.1f}s wait",
    )


def test_withheld_once_overdue(directory: str) -> None:
    """A main loop that overruns its bound must stop the heartbeat.

    The defect itself: the process alive, the publisher thread running,
    the loop stuck. A thread that beat unconditionally would keep this
    bridge looking healthy forever.
    """
    path = os.path.join(directory, "overdue")
    hb = _started(path)
    hb.progress(2 * INTERVAL)  # declare a short wait, then never report
    time.sleep(15 * INTERVAL)
    age = _age(path)
    # Bound plus slack is 3 * INTERVAL; well past it, the file must have
    # stopped being rewritten.
    check(
        "withheld once the main loop overruns",
        age > 8 * INTERVAL,
        f"age {age:.2f}s, {15 * INTERVAL:.1f}s after a {2 * INTERVAL:.1f}s bound",
    )


def test_hook_default_is_inert() -> None:
    """The server and client share double_tls and never set the hook."""
    check(
        "double_tls progress hook unset by default",
        double_tls.progress_hook is None,
        f"progress_hook is {double_tls.progress_hook!r}",
    )
    try:
        double_tls._progress(5)
        ok, detail = True, "a call with no hook installed does nothing"
    except Exception as e:  # noqa: BLE001 - any exception is the failure
        ok, detail = False, f"raised {e!r}"
    check("progress with no hook is a no-op", ok, detail)


def test_hook_feeds_heartbeat(directory: str) -> None:
    """Progress reported through double_tls reaches the heartbeat.

    This is the path the request relay uses: if the hook were not
    wired, a long relay would look like a wedge.
    """
    path = os.path.join(directory, "hooked")
    hb = _started(path)
    saved = (double_tls.progress_hook, bridge._heartbeat)
    try:
        bridge._heartbeat = hb
        double_tls.progress_hook = bridge._progress
        hb.progress(INTERVAL)
        for _ in range(12):
            double_tls._progress(INTERVAL)  # as the relay loop does
            time.sleep(INTERVAL)
        age = _age(path)
    finally:
        double_tls.progress_hook, bridge._heartbeat = saved
    check(
        "progress through double_tls keeps it fresh",
        age < 3 * INTERVAL,
        f"age {age:.2f}s after {12 * INTERVAL:.1f}s of relay progress",
    )


def main() -> int:
    print("Bridge liveness heartbeat regression tests")
    print(f"bridge: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    if not PATCHED:
        print("FAIL  bridge has no Heartbeat: patch 15 is not applied")
        return 1
    bridge._HEARTBEAT_INTERVAL_SECONDS = INTERVAL
    bridge._IDLE_WAIT_SLICE_SECONDS = INTERVAL
    with tempfile.TemporaryDirectory() as directory:
        test_publishes_while_progressing(directory)
        test_fresh_within_declared_bound(directory)
        test_withheld_once_overdue(directory)
        test_hook_default_is_inert()
        test_hook_feeds_heartbeat(directory)
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("the heartbeat tells a healthy bridge from a wedged one")
    return 0


if __name__ == "__main__":
    sys.exit(main())
