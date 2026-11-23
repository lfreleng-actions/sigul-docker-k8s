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
# Heartbeat has no stop, so every check leaves a publisher thread
# behind. Each is made overdue, and seen to withhold, before the
# temporary directory goes: one still writing would recreate its file
# under the cleanup and fail a run whose checks had all passed. A
# directory whose publishers were not all seen to stop is left alone.
#
# Run inside the sigul bridge image:
#   python3 test/test_bridge_heartbeat.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# bridge and double_tls are upstream code this repository only patches,
# and ship no type stubs, so their members are untyped by nature.

import logging
import os
import shutil
import sys
import tempfile
import threading
import time
from collections import Counter
from collections.abc import Callable, Generator
from contextlib import AbstractContextManager, contextmanager
from typing import Protocol, cast

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import bridge  # noqa: E402
import double_tls  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(bridge, "Heartbeat")

# Scaled down so each check takes a second or two: the publisher beats
# every INTERVAL, and slack of one INTERVAL is added to every bound.
INTERVAL = 0.2

# How long a publisher gets to act on a report before the run gives up
# on it. Each acts within one INTERVAL; the rest is for a slow runner.
RETIRE_TIMEOUT = 50 * INTERVAL

# Every started heartbeat, with its file and its publisher thread.
PUBLISHERS: list[tuple["Heartbeat", str, int]] = []

# Per publisher thread, how often it has said it is withholding.
WITHHELD: Counter[int] = Counter()


class Heartbeat(Protocol):
    """The slice of bridge.Heartbeat these checks drive."""

    def progress(self, bound: float | None = None) -> None: ...
    def start(self) -> None: ...
    def lease(self, bound: float) -> AbstractContextManager[None]: ...


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def _age(path: str) -> float:
    try:
        return time.time() - os.stat(path).st_mtime
    except OSError:
        return float("inf")


def _note_withheld(record: logging.LogRecord) -> bool:
    """Count a publisher's own word that it has stopped writing.

    A logger filter rather than a handler, so the warnings still reach
    the test's output as they always have.
    """
    if record.getMessage().startswith("Main loop overdue"):
        WITHHELD[record.thread or 0] += 1
    return True


def _started(path: str) -> Heartbeat:
    before = set(threading.enumerate())
    hb = cast(Heartbeat, bridge.Heartbeat(path))
    hb.start()
    (publisher,) = set(threading.enumerate()) - before
    PUBLISHERS.append((hb, path, publisher.ident or 0))
    return hb


def _mtime_ns(path: str) -> int:
    try:
        return os.stat(path).st_mtime_ns
    except OSError:
        return 0


def _wait_until_none(pending: Callable[[], list[str]]) -> list[str]:
    """Poll until nothing is pending; return what still is at the timeout."""
    deadline = time.monotonic() + RETIRE_TIMEOUT
    late = pending()
    while late and time.monotonic() < deadline:
        time.sleep(INTERVAL / 10)
        late = pending()
    return late


def _retire_publishers() -> bool:
    """Stop every publisher writing, and say whether each was seen to stop.

    A publisher withholds once its deadline has passed, and warns of
    it once a minute at most, so one that has warned already would
    stop without a sign. Each is therefore first made to publish,
    which shows in its file and rearms the warning, and is then made
    overdue as of now. The warning that follows is its word that it
    found the deadline passed; with no report after that, it never
    writes again, and the directory can go.

    The first report's bound outlasts the wait for the slowest
    publisher: one that had published and then run out while the
    others were waited for would warn before its count was taken,
    and then have nothing left to say.
    """
    for hb, _, _ in PUBLISHERS:
        hb.progress(2 * RETIRE_TIMEOUT)
    # Read after the reports, so only a write made under them counts.
    written = {path: _mtime_ns(path) for _, path, _ in PUBLISHERS}
    late = _wait_until_none(
        lambda: [path for path, was in written.items() if _mtime_ns(path) == was]
    )

    warned = {path: (thread, WITHHELD[thread]) for _, path, thread in PUBLISHERS}
    for hb, _, _ in PUBLISHERS:
        # A negative bound cancels the slack progress() adds, so the
        # deadline is now rather than one INTERVAL away.
        hb.progress(-bridge._HEARTBEAT_INTERVAL_SECONDS)
    late += _wait_until_none(
        lambda: [
            path for path, (thread, was) in warned.items() if WITHHELD[thread] == was
        ]
    )

    names = sorted({os.path.basename(path) for path in late})
    check(
        "every publisher stopped before cleanup",
        not late,
        f"still live after {RETIRE_TIMEOUT:.1f}s: {names}"
        if late
        else f"{len(PUBLISHERS)} withheld, none left writing",
    )
    return not late


@contextmanager
def _heartbeat_directory() -> Generator[str]:
    """A directory for heartbeat files, removed once nothing writes to it.

    Removed only then. A publisher that gave no sign of stopping may
    be paused short of its next write, and would recreate its file
    under the removal, which would end the run in a traceback in
    place of the failure already recorded against it. Its directory
    stays where it is, and the run fails on that check.
    """
    directory = tempfile.mkdtemp()
    try:
        yield directory
    finally:
        if _retire_publishers():
            shutil.rmtree(directory)
        else:
            print(f"      {directory} left in place: a publisher may still write")


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


def test_lease_survives_nested_reports(directory: str) -> None:
    """A short report inside a lease must not cut the lease short.

    The case a last-writer-wins deadline gets wrong: a handler phase
    allows thirty minutes for Koji, then does a routine 120 s read,
    then calls Koji again. If the read's bound replaced the phase's,
    a Koji call that outlasted the read's bound would stop the
    heartbeat and restart a healthy bridge.
    """
    path = os.path.join(directory, "leased")
    hb = _started(path)
    with hb.lease(20 * INTERVAL):  # the handler phase's allowance
        hb.progress(INTERVAL)  # a nested, much shorter I/O report
        time.sleep(12 * INTERVAL)  # a long Koji call, far past it
        age = _age(path)
    check(
        "a lease survives a shorter nested report",
        age < 3 * INTERVAL,
        f"age {age:.2f}s, {12 * INTERVAL:.1f}s after a {INTERVAL:.1f}s report "
        + f"inside a {20 * INTERVAL:.1f}s lease",
    )


def test_lease_released_on_exit(directory: str) -> None:
    """A lease must end with its block, even one that raised.

    Otherwise a failed thirty-minute phase would leave its allowance
    behind, and a wedge in the next thirty minutes would go unseen.
    """
    path = os.path.join(directory, "released")
    hb = _started(path)
    try:
        with hb.lease(100 * INTERVAL):
            raise RuntimeError("phase failed")
    except RuntimeError:
        pass
    hb.progress(2 * INTERVAL)  # then a short wait that never ends
    time.sleep(15 * INTERVAL)
    age = _age(path)
    check(
        "a lease is released when its block raises",
        age > 8 * INTERVAL,
        f"age {age:.2f}s, {15 * INTERVAL:.1f}s after the block, "
        + f"whose {100 * INTERVAL:.1f}s lease must not linger",
    )


def test_lease_leaves_no_inner_report_behind(directory: str) -> None:
    """A long report inside a lease must end with the lease (#38).

    A phase that ends on a long read reports that read's bound inside
    its lease. Once the phase is over, the read is too: if its bound
    outlived the lease, a bridge wedged straight after the phase would
    keep a fresh heartbeat for that long, and be replaced that late.
    """
    path = os.path.join(directory, "inner")
    hb = _started(path)
    with hb.lease(100 * INTERVAL):
        hb.progress(30 * INTERVAL)  # the phase's last, long read
    time.sleep(12 * INTERVAL)  # then the main loop wedges
    age = _age(path)
    check(
        "a report made inside a lease ends with the lease",
        age > 6 * INTERVAL,
        f"age {age:.2f}s, {12 * INTERVAL:.1f}s after the lease, whose last "
        + f"report of {30 * INTERVAL:.1f}s must not outlive it",
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
    logging.getLogger().addFilter(_note_withheld)
    with _heartbeat_directory() as directory:
        test_publishes_while_progressing(directory)
        test_fresh_within_declared_bound(directory)
        test_withheld_once_overdue(directory)
        test_lease_survives_nested_reports(directory)
        test_lease_released_on_exit(directory)
        test_lease_leaves_no_inner_report_behind(directory)
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
