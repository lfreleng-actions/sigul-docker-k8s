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

#: Monitoring coverage: a unit must have been sampled for at least this
#: fraction of the run's ticks for its resource invariants to mean
#: anything. Restarts and freezes legitimately cost a few readings;
#: losing half of them means the sampler was not working.
MIN_SAMPLE_COVERAGE = 0.5
SAMPLE_INTERVAL_SECONDS = 5.0


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
    return checks


def invariants(results: Results) -> list[Check]:
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
        checks.append(
            Check(
                f"{unit}: RSS trend < {MAX_RSS_SLOPE_MB_PER_HOUR:.0f} MB/h",
                res.rss_slope_mb_per_hour < MAX_RSS_SLOPE_MB_PER_HOUR,
                f"{res.rss_slope_mb_per_hour:+.1f} MB/h "
                f"(baseline {res.rss_start_mb} MB, cooldown {res.rss_end_mb} MB)",
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
                res.zombies_max == 0,
                f"peak {res.zombies_max}",
            )
        )
    return checks


def regressions(results: Results, baseline: dict) -> list[Check]:
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
