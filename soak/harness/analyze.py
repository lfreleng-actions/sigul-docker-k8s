# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Turn the run's CSVs into a verdict.

Three inputs, all written independently during the run and joined
here on wall-clock time:

- `requests.csv`  every sigul invocation: when, what, how long, outcome
- `samples.csv`   the daemons' memory, descriptors and socket states
- `timeline.csv`  phases and fault windows

Two kinds of judgement come out:

Invariants are absolute. The service must recover after every fault
within a bound; descriptors and CLOSE-WAIT sockets must return to where
they started; nothing may be left as a zombie. Breaking one of these is
a defect regardless of what any previous run did.

Regressions are relative to a committed baseline: latency percentiles,
memory trend, success rate. They catch slow decay that no single
absolute threshold would.

A fault or invariant may be marked in `expectations.json` as expected
to fail, with the issue that tracks it. Such a check failing is
reported as XFAIL and does not fail the run; such a check *passing* is
reported as XPASS and does fail it, because the marker is now stale
and someone should remove it and close the issue.

Rendering (markdown, charts) lives in `report.py`.
"""

from __future__ import annotations

import json
import statistics
import time
from collections import defaultdict
from dataclasses import asdict
from pathlib import Path

from .checks import coverage, invariants, regressions
from .models import (
    Check,
    FaultMeta,
    FaultResult,
    RampStep,
    Results,
    TaskStats,
    UnitResources,
)
from .stats import Run, percentile, slope_per_hour, task_stats

#: Default bound on recovery: seconds from the end of a fault window to
#: the first successful request. Generous because Sigul's server
#: reconnects on a back-off schedule after a refused connection; tight
#: enough that anything approaching the old one-hour timeouts is a
#: clear fail.
DEFAULT_MAX_RECOVERY_SECONDS = 60.0

#: Longest tolerable gap between successful requests while a fault is
#: active. Sigul is serial, so a client that holds the bridge's slot
#: stalls everyone; a bridge with sensible handshake and read deadlines
#: should shed such a client well inside this bound.
DEFAULT_MAX_STALL_SECONDS = 30.0

#: Slack added to a fault's own duration when the fault removes the
#: service outright and only recovery can be judged.
STALL_SLACK_SECONDS = 15.0


def _ramp_steps(run: Run) -> list[RampStep]:
    """Requests and failures at each concurrency level of the ramp.

    The ramp exists to find the bridge's backlog cliff: with a listen
    backlog of five and clients accepted only between server pairings,
    there is some concurrency at which honest clients start being
    refused. This is where that shows up.
    """
    steps: list[RampStep] = []
    for row in run.timeline:
        if row["kind"] != "ramp":
            continue
        start, end = float(row["start_epoch"]), float(row["end_epoch"])
        during = run.between(start, end)
        steps.append(
            RampStep(
                users=int(row["name"].split("=", 1)[1]),
                seconds=round(end - start, 1),
                requests=len(during),
                failures=sum(1 for r in during if not r.ok),
                p95_ms=round(percentile([r.latency_ms for r in during if r.ok], 95), 1),
            )
        )
    return steps


def _phase_stats(run: Run) -> dict[str, dict[str, TaskStats]]:
    phases = {
        r["name"]: (float(r["start_epoch"]), float(r["end_epoch"]))
        for r in run.timeline
        if r["kind"] == "phase"
    }
    return {
        name: task_stats(run.between(start, end))
        for name, (start, end) in phases.items()
    }


def _longest_stall(
    run: Run, start: float, end: float, recovery_end: float
) -> tuple[float | None, float]:
    """Recovery time after `end`, and the widest success gap from `start`.

    Recovery is only credited within the fault's own recovery window.
    A success that arrives after the next fault has begun belongs to
    that fault's story, not this one's; without the bound a wedge could
    be marked recovered by a request served minutes later.
    """
    first_after = next((t for t in run.successes if end <= t <= recovery_end), None)
    recovery = (first_after - end) if first_after is not None else None

    # Anchors run from the fault's start to the first success after it
    # ends. The start is clamped to the fault itself: time without
    # requests before the fault began is not the fault's doing.
    window_end = first_after if first_after is not None else recovery_end
    anchors = [start] + [t for t in run.successes if start <= t <= window_end]
    if first_after is None:
        anchors.append(window_end)
    stall = max(
        (b - a for a, b in zip(anchors, anchors[1:], strict=False)), default=0.0
    )
    return recovery, stall


def _fault_result(
    run: Run,
    row: dict[str, str],
    meta: FaultMeta,
    expectation: dict,
    recovery_end: float,
) -> FaultResult:
    name = row["name"]
    start, end = float(row["start_epoch"]), float(row["end_epoch"])
    during = run.between(start, end)
    recovery, stall = _longest_stall(run, start, end, recovery_end)

    expected = expectation.get("expect", "pass")
    # The recovery window is also the observation window: a success can
    # only be seen inside it. The effective bound is therefore the
    # configured bound or the window, whichever is shorter, and that is
    # what the report shows.
    max_recovery = min(
        float(expectation.get("max_recovery_seconds", DEFAULT_MAX_RECOVERY_SECONDS)),
        recovery_end - end,
    )
    default_stall = (
        DEFAULT_MAX_STALL_SECONDS
        if meta.service_possible_during
        else (end - start) + STALL_SLACK_SECONDS
    )
    stall_bound = float(expectation.get("max_stall_seconds", default_stall))

    recovered = recovery is not None and recovery <= max_recovery
    # A fault that removes the service outright is judged on recovery
    # alone; its stall is reported but cannot be a failure.
    stalled = meta.service_possible_during and stall > stall_bound
    timeline_note = row.get("note", "")
    # The note is a list of "; "-separated entries. A fault may observe
    # the product failing directly ("defect: ..."), which counts like a
    # stall. Any other entry means the harness failed to inject or
    # remove the fault, and no product outcome excuses that.
    entries = [e.strip() for e in timeline_note.split(";") if e.strip()]
    defect_observed = any(e.startswith("defect:") for e in entries)
    harness_error = any(not e.startswith("defect:") for e in entries)

    if harness_error:
        note = f"harness: {timeline_note}"
    elif defect_observed:
        note = timeline_note
    elif recovery is None:
        note = "no successful request after the fault ended"
    elif not recovered:
        note = f"recovered after {recovery:.1f}s (bound {max_recovery:.0f}s)"
    elif stalled:
        note = (
            f"service stalled for {stall:.1f}s (bound {stall_bound:.0f}s); "
            f"recovered {recovery:.1f}s after the fault ended"
        )
    else:
        note = f"recovered in {recovery:.1f}s; longest stall {stall:.1f}s"
    if expectation.get("issue"):
        note += f" [expected {expected}: {expectation['issue']}]"

    # An expectation covers the stall only. Failing to recover once the
    # fault has ended, or the harness failing to inject or remove the
    # fault, is never an expected outcome: the first is the deadlock
    # class this suite exists to catch, the second invalidates the run.
    if harness_error or not recovered:
        verdict = "fail"
    elif stalled or defect_observed:
        verdict = "xfail" if expected == "fail" else "fail"
    else:
        verdict = "xpass" if expected == "fail" else "pass"

    return FaultResult(
        name=name,
        start=start,
        end=end,
        requests_during=len(during),
        failures_during=sum(1 for r in during if not r.ok),
        recovery_seconds=round(recovery, 1) if recovery is not None else None,
        max_recovery_seconds=max_recovery,
        max_stall_seconds=round(stall, 1),
        stall_bound_seconds=stall_bound,
        expected=expected,
        verdict=verdict,
        note=note,
        description=meta.description,
        implication=meta.implication,
    )


def _mean_rss_mb(rows: list[dict[str, str]]) -> float:
    return statistics.fmean(int(r["rss_bytes"]) for r in rows) / (1 << 20)


def _unit_resources(
    rows: list[dict[str, str]], windows: dict[str, tuple[float, float]]
) -> UnitResources:
    """Summarise one unit's samples.

    Start and end figures come from the baseline and cooldown phases -
    both clean load at the same concurrency - so the comparison is like
    for like. The trend fit covers the span from baseline to cooldown,
    the period the profile keeps free of restarts; peaks use every
    sample. A restart inside that span is counted and reported, because
    it resets everything the comparison measures.
    """
    rows.sort(key=lambda r: float(r["epoch"]))

    def within(phase: str) -> list[dict[str, str]]:
        if phase not in windows:
            return []
        lo, hi = windows[phase]
        return [r for r in rows if lo <= float(r["epoch"]) <= hi]

    tenth = max(1, len(rows) // 10)
    head = within("baseline") or rows[:tenth]
    tail = within("cooldown") or rows[-tenth:]
    span_lo = float(head[0]["epoch"])
    span_hi = float(tail[-1]["epoch"])
    span = [r for r in rows if span_lo <= float(r["epoch"]) <= span_hi]
    lifetimes = {r.get("started_at", "0") for r in span}
    return UnitResources(
        rss_start_mb=round(_mean_rss_mb(head), 1),
        rss_end_mb=round(_mean_rss_mb(tail), 1),
        rss_slope_mb_per_hour=round(
            slope_per_hour(
                [(float(r["epoch"]), int(r["rss_bytes"]) / (1 << 20)) for r in span]
            ),
            2,
        ),
        fds_start=round(statistics.fmean(int(r["open_fds"]) for r in head)),
        fds_end=round(statistics.fmean(int(r["open_fds"]) for r in tail)),
        close_wait_max=max(int(r["close_wait"]) for r in rows),
        # The last reading, not the phase mean: a leak that appears late
        # in cooldown must not be averaged away.
        close_wait_end=int(tail[-1]["close_wait"]),
        fin_wait_2_max=max(int(r["fin_wait_2"]) for r in rows),
        zombies_max=max(int(r["zombies"]) for r in rows),
        zombies_end=int(tail[-1]["zombies"]),
        samples=len(rows),
        restarts_in_window=max(0, len(lifetimes) - 1),
        span_seconds=round(span_hi - span_lo, 1),
    )


def analyse(
    output_dir: Path,
    profile_name: str,
    fault_meta: dict[str, FaultMeta],
    expectations: dict,
    baseline: dict | None,
    units: tuple[str, ...] = ("sigul-bridge", "sigul-server"),
    harness_failure: str | None = None,
) -> Results:
    run = Run.load(output_dir)
    now = time.time()
    started = min((float(r["start_epoch"]) for r in run.timeline), default=now)
    ended = max((float(r["end_epoch"]) for r in run.timeline), default=now)
    results = Results(profile=profile_name, started=started, ended=ended)

    results.phases = _phase_stats(run)
    results.ramp = _ramp_steps(run)

    fault_expectations = expectations.get("faults", {})
    recovery_windows = {
        (r["name"], float(r["start_epoch"])): float(r["end_epoch"])
        for r in run.timeline
        if r["kind"] == "recovery"
    }
    for row in run.timeline:
        if row["kind"] == "fault":
            fault_end = float(row["end_epoch"])
            results.faults.append(
                _fault_result(
                    run,
                    row,
                    fault_meta.get(row["name"], FaultMeta()),
                    fault_expectations.get(row["name"], {}),
                    recovery_windows.get((row["name"], fault_end), ended),
                )
            )

    by_unit: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in run.samples:
        by_unit[row["unit"]].append(row)
    windows = {
        r["name"]: (float(r["start_epoch"]), float(r["end_epoch"]))
        for r in run.timeline
        if r["kind"] == "phase"
    }
    results.resources = {
        unit: _unit_resources(rows, windows) for unit, rows in by_unit.items()
    }

    results.invariants = coverage(results, units, run, windows) + invariants(results)
    # A failure of the harness itself - load generator gone, sampler
    # stuck - is recorded as the first invariant so the published
    # report and results.json carry the same verdict the exit status
    # does, and no expectation can match it.
    results.invariants.insert(
        0,
        Check(
            "harness ran to completion",
            harness_failure is None,
            harness_failure or "load, sampling and fault injection all ran as planned",
        ),
    )
    if baseline:
        results.regressions = regressions(results, baseline)

    invariant_expectations = expectations.get("invariants", {})
    for check in results.invariants + results.regressions:
        check.judge(invariant_expectations)
    # An expectation that names nothing this run produced is as stale
    # as one whose subject now passes: the fault was renamed or dropped
    # from the profile, and the marker would otherwise live on unseen.
    emitted_faults = {f.name for f in results.faults}
    emitted_checks = {c.name for c in results.invariants + results.regressions}
    orphaned = [
        f"faults/{name}" for name in fault_expectations if name not in emitted_faults
    ] + [
        f"invariants/{name}"
        for name in invariant_expectations
        if name not in emitted_checks
    ]
    if orphaned:
        results.invariants.append(
            Check(
                "no orphaned expected-fail markers",
                False,
                "; ".join(f"{name} names nothing in this run" for name in orphaned),
                verdict="fail",
            )
        )
    stale = [c for c in results.invariants if c.verdict == "xpass"]
    if stale:
        results.invariants.append(
            Check(
                "no stale expected-fail invariant markers",
                False,
                "; ".join(
                    f"{c.name} now holds - remove its expectation" for c in stale
                ),
                verdict="fail",
            )
        )

    failed = [
        c
        for c in results.invariants + results.regressions
        if c.verdict in ("fail", "xpass")
    ]
    results.verdict = "pass" if not failed else "fail"
    return results


def write_results(results: Results, output_dir: Path) -> None:
    (output_dir / "results.json").write_text(
        json.dumps(asdict(results), indent=2, sort_keys=True)
    )
