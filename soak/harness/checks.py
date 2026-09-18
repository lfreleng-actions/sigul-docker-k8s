# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""The checks a run must pass: monitoring coverage, invariants, regressions."""

from __future__ import annotations

from .models import Check, Results
from .stats import Run

#: Steepest RSS trend tolerated, from a least-squares fit over every
#: sample. A fit is the right detector for a linear leak: it uses the
#: whole run rather than two endpoints, and its units do not change
#: with the profile's length. Observed without a leak: within +/-10
#: MB/h on the bridge. Observed with the zombie leak: +50 to +270 MB/h.
MAX_RSS_SLOPE_MB_PER_HOUR = 30.0

#: Shortest span over which a fitted RSS trend is worth judging. Below
#: this the fit is dominated by a few requests' worth of allocation
#: noise (observed: +10 to +370 MB/h for the same healthy daemon over
#: ninety seconds), so the reading is reported but not judged.
MIN_TREND_SPAN_SECONDS = 600.0

#: Descriptor growth tolerated between the baseline and cooldown phase
#: means. Samples land mid-request, and a request in flight holds
#: around a dozen descriptors on the server, so phase means of a few
#: dozen samples wobble by several either way. The leak this catches
#: was +105 on the bridge in twenty minutes; a fall is never a leak.
MAX_FD_GROWTH = 10
MAX_CLOSE_WAIT_END = 1

#: Regression tolerances against the committed baseline. p95 may grow
#: by 50% or by 250 ms, whichever is larger: the floor stops a 300 ms
#: control-plane call failing the run over 150 ms of scheduler noise
#: on a shared CI host, and the ratio governs everything slower.
P95_TOLERANCE_RATIO = 1.5
P95_TOLERANCE_FLOOR_MS = 250.0
SUCCESS_RATE_TOLERANCE = 0.05
MIN_REGRESSION_SAMPLES = 5

#: Lowest success rate tolerated at any ramp step. The ramp is where a
#: too-small listen backlog shows itself, as connections refused to
#: honest clients once several arrive together.
MIN_RAMP_SUCCESS_RATE = 0.95

#: The clean phases must carry real, mostly successful load, or the
#: comparisons built on them mean nothing.
MIN_CLEAN_PHASE_REQUESTS = 10
MIN_CLEAN_PHASE_SUCCESS_RATE = 0.95

#: Monitoring coverage: a unit must have been sampled for at least this
#: fraction of the run's ticks for its resource invariants to mean
#: anything. Restarts and freezes legitimately cost a few readings;
#: losing half of them means the sampler was not working.
MIN_SAMPLE_COVERAGE = 0.5
SAMPLE_INTERVAL_SECONDS = 5.0

#: The end-of-run readings (zombies, CLOSE-WAIT) come from the last
#: cooldown sample, so that sample must actually be from the end of
#: cooldown: a sampler that died halfway through would otherwise leave
#: a stale "last" row that says nothing about the final state.
MAX_TAIL_STALENESS_SECONDS = SAMPLE_INTERVAL_SECONDS * 3


def coverage(
    results: Results,
    units: tuple[str, ...],
    run: Run,
    windows: dict[str, tuple[float, float]],
) -> list[Check]:
    """Every monitored unit must have been sampled for most of the run,
    and specifically through the two clean phases.

    Resource invariants are only generated for units with samples, and
    their start/end figures come from the baseline and cooldown phases.
    Without these checks a sampler that failed, or a run cut short, would
    make the leak checks vanish or compare the wrong periods, and pass.
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
        for phase in ("baseline", "cooldown"):
            if phase not in windows:
                checks.append(
                    Check(
                        f"{unit}: monitored through {phase}",
                        False,
                        "phase never recorded",
                    )
                )
                continue
            lo, hi = windows[phase]
            want = max(1, int((hi - lo) / SAMPLE_INTERVAL_SECONDS))
            have = sum(
                1
                for r in run.samples
                if r["unit"] == unit and lo <= float(r["epoch"]) <= hi
            )
            checks.append(
                Check(
                    f"{unit}: monitored through {phase}",
                    have >= want * MIN_SAMPLE_COVERAGE,
                    f"{have} of ~{want} samples",
                )
            )
        if "cooldown" in windows:
            _, hi = windows["cooldown"]
            last = max(
                (
                    float(r["epoch"])
                    for r in run.samples
                    if r["unit"] == unit and float(r["epoch"]) <= hi
                ),
                default=0.0,
            )
            staleness = hi - last
            checks.append(
                Check(
                    f"{unit}: sampled to the end of cooldown",
                    staleness <= MAX_TAIL_STALENESS_SECONDS,
                    f"last sample {staleness:.0f}s before cooldown ended (bound {MAX_TAIL_STALENESS_SECONDS:.0f}s)",
                )
            )
    return checks


def _ramp_checks(results: Results) -> list[Check]:
    checks: list[Check] = []
    for step in results.ramp:
        if step.requests == 0:
            checks.append(
                Check(
                    f"ramp at {step.users} users: requests served",
                    False,
                    "no requests completed",
                )
            )
            continue
        checks.append(
            Check(
                f"ramp at {step.users} users: success rate >= {MIN_RAMP_SUCCESS_RATE:.0%}",
                step.success_rate >= MIN_RAMP_SUCCESS_RATE,
                f"{step.success_rate:.0%} of {step.requests} requests, p95 {step.p95_ms:.0f} ms",
            )
        )
    return checks


def _clean_phase_checks(results: Results) -> list[Check]:
    checks: list[Check] = []
    for phase in ("baseline", "cooldown"):
        stats = results.phases.get(phase, {})
        requests = sum(s.count for s in stats.values())
        ok = sum(s.ok for s in stats.values())
        rate = ok / requests if requests else 0.0
        checks.append(
            Check(
                f"{phase}: carried clean load",
                requests >= MIN_CLEAN_PHASE_REQUESTS
                and rate >= MIN_CLEAN_PHASE_SUCCESS_RATE,
                f"{ok} of {requests} requests succeeded",
            )
        )
    return checks


def _fault_checks(results: Results) -> list[Check]:
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
    return checks


def _resource_checks(results: Results) -> list[Check]:
    checks: list[Check] = []
    for unit, res in results.resources.items():
        checks.append(
            Check(
                f"{unit}: no restart between baseline and cooldown",
                res.restarts_in_window == 0,
                f"{res.restarts_in_window} restart(s) inside the measured window"
                if res.restarts_in_window
                else "one container lifetime throughout",
            )
        )
        trend_detail = (
            f"{res.rss_slope_mb_per_hour:+.1f} MB/h "
            f"(baseline {res.rss_start_mb} MB, cooldown {res.rss_end_mb} MB)"
        )
        if res.span_seconds < MIN_TREND_SPAN_SECONDS:
            checks.append(
                Check(
                    f"{unit}: RSS trend < {MAX_RSS_SLOPE_MB_PER_HOUR:.0f} MB/h",
                    True,
                    f"not judged: {trend_detail} over {res.span_seconds:.0f}s, "
                    f"need {MIN_TREND_SPAN_SECONDS:.0f}s",
                    informational=True,
                )
            )
        else:
            checks.append(
                Check(
                    f"{unit}: RSS trend < {MAX_RSS_SLOPE_MB_PER_HOUR:.0f} MB/h",
                    res.rss_slope_mb_per_hour < MAX_RSS_SLOPE_MB_PER_HOUR,
                    trend_detail,
                )
            )
        checks.append(
            Check(
                f"{unit}: open descriptors return to baseline",
                res.fds_end - res.fds_start <= MAX_FD_GROWTH,
                f"{res.fds_start} -> {res.fds_end} (bound +{MAX_FD_GROWTH})",
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
                res.zombies_end == 0,
                f"median of last 3 samples={res.zombies_end} (peak {res.zombies_max})",
            )
        )
    return checks


def invariants(results: Results) -> list[Check]:
    """Absolute checks: hold regardless of any baseline."""
    return (
        _ramp_checks(results)
        + _clean_phase_checks(results)
        + _fault_checks(results)
        + _resource_checks(results)
    )


def regressions(results: Results, baseline: dict) -> list[Check]:
    checks: list[Check] = []
    baseline_phases = baseline.get("phases", {})
    for phase in ("baseline", "cooldown"):
        reference = baseline_phases.get(phase, {})
        current = results.phases.get(phase, {})
        # Iterate the baseline's tasks, not the run's: a task that has
        # vanished or become too slow to complete five times in the
        # phase is a regression, not a gap in the data.
        for task, ref in reference.items():
            stats = current.get(task)
            if stats is None or stats.count < MIN_REGRESSION_SAMPLES:
                checks.append(
                    Check(
                        f"{phase}/{task}: enough requests to compare",
                        False,
                        f"{stats.count if stats else 0} completed, need {MIN_REGRESSION_SAMPLES}",
                    )
                )
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
