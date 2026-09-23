# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""The checks a run must pass: monitoring coverage, invariants, regressions."""

from __future__ import annotations

import math

from .models import Check, Results
from .resource_checks import resource_checks
from .stats import Run

#: Regression tolerances against the committed baseline. Latency may
#: grow by 50% or by 250 ms, whichever is larger: the floor stops a
#: 300 ms control-plane call failing the run over 150 ms of scheduler
#: noise on a shared CI host, and the ratio governs everything slower.
LATENCY_TOLERANCE_RATIO = 1.5
LATENCY_TOLERANCE_FLOOR_MS = 250.0
SUCCESS_RATE_TOLERANCE = 0.05

#: Completions a task needs before its percentiles mean anything.
#:
#: Sigul serves one request at a time and the load mix contains a
#: 64 MiB signing task taking 8-22 s, so every other request can queue
#: behind one. That makes the upper tail a property of scheduling luck
#: rather than of the task: measured across four green CI runs, a p95
#: drawn from ~20 completions swung by 7.3x, while the same task's p95
#: over 50 or more completions held to within 1.23x. A p95 over twenty
#: samples is not a percentile, it is the second-worst observation.
#:
#: So each percentile is compared only where enough requests completed
#: - in the baseline and in the run - to estimate it. Below that the
#: comparison is skipped and said to be skipped, rather than being
#: made on a number that carries no information.
MIN_SAMPLES_P50 = 20
MIN_SAMPLES_P95 = 50

#: Activity floor per task, below which the run is failed outright.
#: A task that has all but stopped is nearly as bad as one that has
#: stopped, and neither the percentile thresholds nor the phase total
#: would notice: percentiles are skipped for want of samples, and the
#: other tasks can hold the total above its own floor. Judged against
#: the baseline's own completions so it scales with each task's share
#: of the load, with an absolute floor for the rare ones. Every green
#: run measured has come in at or above its baseline figure, so half
#: of it leaves a wide margin.
MIN_TASK_COMPLETIONS = 5
MIN_TASK_COMPLETION_RATIO = 0.5

#: Share of the baseline's completions a phase must still deliver.
#: For a strictly serial service this is the capacity metric: work
#: that takes longer shows up first as less of it getting done, and a
#: uniform slowdown too small to trip the latency bounds still shows
#: here. One-sided - more throughput never fails.
#:
#: Four green runs completed 243, 253, 266 and 290 requests in the
#: cooldown phase: a 1.19x spread, mean 263, standard deviation 21.
#: Against the committed reference of 243 (the worst of them) this
#: leaves a floor of 207, below mean minus two standard deviations, so
#: an ordinarily slow run should not reach it. It catches a capacity
#: loss of about a third and will not notice one of a fifth; the
#: latency bounds cover the rest. Worth revisiting once more runs have
#: accumulated - tightening it needs evidence, not optimism.
MIN_THROUGHPUT_RATIO = 0.85

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
    # Stale means the defect no longer reproduces, which is a property of
    # the fault rather than of one injection. A timing-dependent defect
    # passes some injections while still failing others - the bandwidth
    # squeeze only stalls the service when a large upload happens to be
    # in flight - and one lucky draw is not evidence of a fix. Judged per
    # injection, a single pass among five failures would fail the run as
    # a stale marker while the defect it names was plainly still there.
    # So a marker is stale only once every injection of its fault passed.
    verdicts: dict[str, list[str]] = {}
    for f in results.faults:
        verdicts.setdefault(f.name, []).append(f.verdict)
    stale = sorted(n for n, vs in verdicts.items() if all(v == "xpass" for v in vs))
    partial = sorted(
        f"{n}: {vs.count('xpass')} of {len(vs)} injections passed"
        for n, vs in verdicts.items()
        if "xpass" in vs and n not in stale
    )
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
            "; ".join(
                f"{n} now recovers every time - remove its expectation" for n in stale
            )
            or (
                "none; still reproducing: " + "; ".join(partial) if partial else "none"
            ),
        )
    )
    return checks


def invariants(results: Results) -> list[Check]:
    """Absolute checks: hold regardless of any baseline."""
    return (
        _ramp_checks(results)
        + _clean_phase_checks(results)
        + _fault_checks(results)
        + resource_checks(results)
    )


def _latency_check(label: str, measured: float, reference: float) -> Check:
    """One-sided latency comparison: only slower than baseline fails."""
    limit = max(
        reference * LATENCY_TOLERANCE_RATIO,
        reference + LATENCY_TOLERANCE_FLOOR_MS,
    )
    return Check(
        f"{label} within +{(LATENCY_TOLERANCE_RATIO - 1):.0%} "
        f"or +{LATENCY_TOLERANCE_FLOOR_MS:.0f} ms of baseline",
        measured <= limit,
        f"{measured:.0f} ms vs baseline {reference:.0f} ms",
    )


def regressions(results: Results, baseline: dict) -> list[Check]:
    """Compare this run against the committed baseline.

    Only the phases the baseline file carries are compared, so which
    phases are worth judging is a property of the data rather than of
    this code. Every comparison is one-sided: slower, less successful
    or less productive than the baseline fails; better never does.
    """
    checks: list[Check] = []
    for phase, reference in baseline.get("phases", {}).items():
        current = results.phases.get(phase, {})
        ref_tasks: dict[str, dict] = reference.get("tasks", {})

        ref_total = reference.get("total_ok")
        if ref_total:
            # Phase durations are fixed by the profile, and the baseline
            # is per-profile, so completions compare directly without
            # needing the elapsed time.
            total = sum(s.ok for s in current.values())
            checks.append(
                Check(
                    f"{phase}: completes at least "
                    f"{MIN_THROUGHPUT_RATIO:.0%} of the baseline's requests",
                    total >= ref_total * MIN_THROUGHPUT_RATIO,
                    f"{total} vs baseline {ref_total}",
                )
            )

        # Iterate the baseline's tasks, not the run's: a task that has
        # vanished, or become too slow to complete at all, is a
        # regression rather than a gap in the data.
        for task, ref in ref_tasks.items():
            stats = current.get(task)
            # Ceiling, not rounding: round() breaks ties to even, so a
            # reference of 45 would give 22 and let a run through at
            # 48.9% while the constant promises half.
            expected = ref.get("min_ok", ref["ok"])
            floor = max(
                MIN_TASK_COMPLETIONS,
                math.ceil(expected * MIN_TASK_COMPLETION_RATIO),
            )
            if stats is None or stats.ok < floor:
                done = stats.ok if stats else 0
                checks.append(
                    Check(
                        f"{phase}/{task}: still completing requests",
                        False,
                        f"{done} succeeded against the baseline's {expected}, "
                        f"below the floor of {floor}",
                    )
                )
                continue

            ref_rate = ref["ok"] / ref["count"] if ref["count"] else 1.0
            checks.append(
                Check(
                    f"{phase}/{task}: success rate within "
                    f"{SUCCESS_RATE_TOLERANCE:.0%} of baseline",
                    stats.success_rate >= ref_rate - SUCCESS_RATE_TOLERANCE,
                    f"{stats.success_rate:.1%} vs baseline {ref_rate:.1%}",
                )
            )

            for metric, floor in (("p50", MIN_SAMPLES_P50), ("p95", MIN_SAMPLES_P95)):
                key = f"{metric}_ms"
                if key not in ref:
                    continue
                # Only the run being judged needs checking here: a
                # percentile appears in the baseline at all only when
                # every run behind it cleared the same floor, which
                # make_baseline.py enforces when it writes the file.
                if stats.ok < floor:
                    checks.append(
                        Check(
                            f"{phase}/{task}: {metric} comparable",
                            True,
                            f"skipped - {stats.ok} completions, "
                            f"{floor} needed to estimate {metric}",
                            informational=True,
                        )
                    )
                    continue
                checks.append(
                    _latency_check(
                        f"{phase}/{task}: {metric}",
                        getattr(stats, key),
                        ref[key],
                    )
                )
    return checks
