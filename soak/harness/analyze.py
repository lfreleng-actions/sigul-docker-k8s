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

from .models import Check, FaultMeta, FaultResult, Results, TaskStats, UnitResources
from .stats import Run, slope_per_hour, task_stats

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

#: How much RSS may grow across the run before it is called a leak.
#: The daemons are small Python processes; tens of MB in half an hour
#: of constant load is not noise.
MAX_RSS_GROWTH_MB = 40.0

#: Descriptor and CLOSE-WAIT drift tolerated between the baseline and
#: cooldown phases. Zero would be ideal; a little allows for a sample
#: landing mid-request.
MAX_FD_DRIFT = 4
MAX_CLOSE_WAIT_END = 1

#: Regression tolerances against the committed baseline. p95 may grow
#: by 50% or by 250 ms, whichever is larger: the floor stops a 300 ms
#: control-plane call failing the run over 150 ms of scheduler noise
#: on a shared CI host, and the ratio governs everything slower.
P95_TOLERANCE_RATIO = 1.5
P95_TOLERANCE_FLOOR_MS = 250.0
SUCCESS_RATE_TOLERANCE = 0.05

#: Monitoring coverage: a unit must have been sampled for at least this
#: fraction of the run's ticks for its resource invariants to mean
#: anything. Restarts and freezes legitimately cost a few readings;
#: losing half of them means the sampler was not working.
MIN_SAMPLE_COVERAGE = 0.5
SAMPLE_INTERVAL_SECONDS = 5.0


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
    run: Run, start: float, end: float, run_end: float
) -> tuple[float | None, float]:
    """Recovery time after `end`, and the widest success gap from `start`."""
    first_after = next((t for t in run.successes if t >= end), None)
    recovery = (first_after - end) if first_after is not None else None

    window_end = first_after if first_after is not None else max(end, run_end)
    before = [t for t in run.successes if t < start]
    anchors = ([before[-1]] if before else [start]) + [
        t for t in run.successes if start <= t <= window_end
    ]
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
    run_end: float,
) -> FaultResult:
    name = row["name"]
    start, end = float(row["start_epoch"]), float(row["end_epoch"])
    during = run.between(start, end)
    recovery, stall = _longest_stall(run, start, end, run_end)

    expected = expectation.get("expect", "pass")
    max_recovery = float(
        expectation.get("max_recovery_seconds", DEFAULT_MAX_RECOVERY_SECONDS)
    )
    default_stall = (
        DEFAULT_MAX_STALL_SECONDS
        if meta.service_possible_during
        else (end - start) + STALL_SLACK_SECONDS
    )
    stall_bound = float(expectation.get("max_stall_seconds", default_stall))

    recovered = recovery is not None and recovery <= max_recovery
    stalled = stall > stall_bound
    harness_error = bool(row.get("note"))

    if harness_error:
        note = f"harness: {row['note']}"
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
    elif stalled:
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


def _unit_resources(rows: list[dict[str, str]]) -> UnitResources:
    rows.sort(key=lambda r: float(r["epoch"]))
    tenth = max(1, len(rows) // 10)
    head, tail = rows[:tenth], rows[-tenth:]
    return UnitResources(
        rss_start_mb=round(_mean_rss_mb(head), 1),
        rss_end_mb=round(_mean_rss_mb(tail), 1),
        rss_slope_mb_per_hour=round(
            slope_per_hour(
                [(float(r["epoch"]), int(r["rss_bytes"]) / (1 << 20)) for r in rows]
            ),
            2,
        ),
        fds_start=round(statistics.fmean(int(r["open_fds"]) for r in head)),
        fds_end=round(statistics.fmean(int(r["open_fds"]) for r in tail)),
        close_wait_max=max(int(r["close_wait"]) for r in rows),
        close_wait_end=round(statistics.fmean(int(r["close_wait"]) for r in tail)),
        fin_wait_2_max=max(int(r["fin_wait_2"]) for r in rows),
        zombies_max=max(int(r["zombies"]) for r in rows),
        samples=len(rows),
    )


def _coverage(results: Results, units: tuple[str, ...]) -> list[Check]:
    """Every monitored unit must have been sampled for most of the run.

    Resource invariants are only generated for units with samples, so
    without this a sampler that silently failed would make every leak
    check vanish and the run pass on no evidence.
    """
    expected = max(1, int((results.ended - results.started) / SAMPLE_INTERVAL_SECONDS))
    checks: list[Check] = []
    for unit in units:
        got = results.resources[unit].samples if unit in results.resources else 0
        checks.append(
            Check(
                f"{unit}: monitored for the whole run",
                got >= expected * MIN_SAMPLE_COVERAGE,
                f"{got} of ~{expected} samples",
            )
        )
    return checks


def _invariants(results: Results) -> list[Check]:
    checks: list[Check] = []
    unexpected = [f for f in results.faults if f.verdict == "fail"]
    stale = [f for f in results.faults if f.verdict == "xpass"]
    checks.append(
        Check(
            "service recovers after every fault",
            not unexpected,
            "; ".join(f"{f.name}: {f.note}" for f in unexpected)
            or "all recovered within bounds",
        )
    )
    checks.append(
        Check(
            "no stale expected-fail markers",
            not stale,
            "; ".join(f"{f.name} now recovers - remove its expectation" for f in stale)
            or "none",
        )
    )
    for unit, res in results.resources.items():
        growth = res.rss_end_mb - res.rss_start_mb
        checks.append(
            Check(
                f"{unit}: RSS growth < {MAX_RSS_GROWTH_MB:.0f} MB",
                growth < MAX_RSS_GROWTH_MB,
                f"{res.rss_start_mb} -> {res.rss_end_mb} MB (slope {res.rss_slope_mb_per_hour:+.1f} MB/h)",
            )
        )
        checks.append(
            Check(
                f"{unit}: open descriptors return to baseline",
                abs(res.fds_end - res.fds_start) <= MAX_FD_DRIFT,
                f"{res.fds_start} -> {res.fds_end}",
            )
        )
        checks.append(
            Check(
                f"{unit}: no CLOSE-WAIT sockets left behind",
                res.close_wait_end <= MAX_CLOSE_WAIT_END,
                f"end={res.close_wait_end} (peak {res.close_wait_max})",
            )
        )
        checks.append(
            Check(
                f"{unit}: no zombie processes",
                res.zombies_max == 0,
                f"peak {res.zombies_max}",
            )
        )
    return checks


def _regressions(results: Results, baseline: dict) -> list[Check]:
    checks: list[Check] = []
    baseline_phases = baseline.get("phases", {})
    for phase in ("baseline", "cooldown"):
        reference = baseline_phases.get(phase, {})
        for task, stats in results.phases.get(phase, {}).items():
            ref = reference.get(task)
            if not ref or stats.count < 5:
                continue
            limit = max(
                ref["p95_ms"] * P95_TOLERANCE_RATIO,
                ref["p95_ms"] + P95_TOLERANCE_FLOOR_MS,
            )
            checks.append(
                Check(
                    f"{phase}/{task}: p95 within +{(P95_TOLERANCE_RATIO - 1):.0%} "
                    f"or +{P95_TOLERANCE_FLOOR_MS:.0f} ms of baseline",
                    stats.p95_ms <= limit,
                    f"{stats.p95_ms:.0f} ms vs baseline {ref['p95_ms']:.0f} ms",
                )
            )
            ref_rate = ref["ok"] / ref["count"] if ref["count"] else 1.0
            checks.append(
                Check(
                    f"{phase}/{task}: success rate within {SUCCESS_RATE_TOLERANCE:.0%} of baseline",
                    stats.success_rate >= ref_rate - SUCCESS_RATE_TOLERANCE,
                    f"{stats.success_rate:.1%} vs baseline {ref_rate:.1%}",
                )
            )
    return checks


def analyse(
    output_dir: Path,
    profile_name: str,
    fault_meta: dict[str, FaultMeta],
    expectations: dict,
    baseline: dict | None,
    units: tuple[str, ...] = ("sigul-bridge", "sigul-server"),
) -> Results:
    run = Run.load(output_dir)
    now = time.time()
    started = min((float(r["start_epoch"]) for r in run.timeline), default=now)
    ended = max((float(r["end_epoch"]) for r in run.timeline), default=now)
    results = Results(profile=profile_name, started=started, ended=ended)

    results.phases = _phase_stats(run)

    fault_expectations = expectations.get("faults", {})
    for row in run.timeline:
        if row["kind"] == "fault":
            results.faults.append(
                _fault_result(
                    run,
                    row,
                    fault_meta.get(row["name"], FaultMeta()),
                    fault_expectations.get(row["name"], {}),
                    ended,
                )
            )

    by_unit: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in run.samples:
        by_unit[row["unit"]].append(row)
    results.resources = {unit: _unit_resources(rows) for unit, rows in by_unit.items()}

    results.invariants = _coverage(results, units) + _invariants(results)
    if baseline:
        results.regressions = _regressions(results, baseline)

    invariant_expectations = expectations.get("invariants", {})
    for check in results.invariants + results.regressions:
        check.judge(invariant_expectations)
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
