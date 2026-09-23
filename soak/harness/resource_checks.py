# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Per-daemon resource checks: memory, descriptors, sockets, children.

The leak detectors, kept apart from the rest of checks.py because
they share one subject and one set of thresholds, each of which was
tuned against a leak this suite actually found. Reading them together
is how to tell what each one exists to catch and what it deliberately
lets through.
"""

from __future__ import annotations

from .models import Check, Results, UnitResources

#: Steepest RSS trend tolerated, from a least-squares fit over every
#: sample. A fit is the right detector for a linear leak: it uses the
#: whole run rather than two endpoints, and its units do not change
#: with the profile's length. Set to catch the zombie leak (+50 to
#: +270 MB/h) on runs as short as the PR gate's, where a tighter bound
#: would trip on a few requests' worth of allocation. It deliberately
#: admits slower growth; MAX_SUSTAINED_RSS_SLOPE_MB_PER_HOUR judges
#: that, over spans long enough to measure it.
MAX_RSS_SLOPE_MB_PER_HOUR = 30.0

#: Growth tolerated once a daemon has had hours to reach steady state.
#: A long-lived daemon serving a fixed load should stop growing; this
#: bound catches one that never does, which the bound above admits
#: indefinitely. Found that way: both daemons grow at 7-21 MB/h every
#: nightly, passing the 30 MB/h check while implying the bridge would
#: reach its 512 Mi limit in about a day of sustained load (#32).
#:
#: Over a nightly's four hours the fitted slope's standard error is
#: 0.01-0.1 MB/h, so this is a policy line rather than a noise margin:
#: 5 MB/h is 120 MB a day, material against that limit, and every
#: growth observed so far sits more than twenty standard errors above
#: it.
MAX_SUSTAINED_RSS_SLOPE_MB_PER_HOUR = 5.0

#: Shortest span over which sustained growth is judged. Long enough
#: that warm-up and the heaviest requests no longer steer the fit; the
#: PR gate's half hour is reported but not judged, so this belongs to
#: the nightly.
MIN_SUSTAINED_SPAN_SECONDS = 7200.0

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


def _sustained_growth_check(unit: str, res: UnitResources) -> Check:
    """Whether a daemon kept growing once it had time to settle.

    Named without its bound, unlike the trend check, because it is the
    key an expectation is filed under: changing the threshold must not
    orphan the marker that tracks the defect it measures.
    """
    name = f"{unit}: no sustained RSS growth"
    reading = f"{res.rss_slope_mb_per_hour:+.1f} MB/h"
    if res.span_seconds < MIN_SUSTAINED_SPAN_SECONDS:
        return Check(
            name,
            True,
            f"not judged: {reading} over {res.span_seconds / 60:.0f} min, "
            f"need {MIN_SUSTAINED_SPAN_SECONDS / 3600:.0f} h",
            informational=True,
        )
    return Check(
        name,
        res.rss_slope_mb_per_hour < MAX_SUSTAINED_RSS_SLOPE_MB_PER_HOUR,
        f"{reading} over {res.span_seconds / 3600:.1f} h "
        f"(bound {MAX_SUSTAINED_RSS_SLOPE_MB_PER_HOUR:.0f} MB/h; baseline "
        f"{res.rss_start_mb} MB, cooldown {res.rss_end_mb} MB)",
    )


def resource_checks(results: Results) -> list[Check]:
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
        checks.append(_sustained_growth_check(unit, res))
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
