# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Run shapes.

A profile says how long to run, how much steady load to apply, and
which faults to fire in what order. The structure is deliberately flat
so a reviewer can see the whole test plan on one screen.

Timings assume Sigul's serial architecture: the bridge pairs exactly
one server with one client at a time, so a "fault window" is not just
a period of degraded service - it is a period in which a single bad
client may be holding the only slot there is. The recovery window that
follows each fault is where the important measurement happens: how
long after the fault stops does the service serve again.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class FaultSlot:
    """One fault, and the quiet period used to measure recovery."""

    fault: str
    #: Seconds to hold the fault active.
    duration: float = 60.0
    #: Seconds of clean running afterwards. Recovery time is measured
    #: from the end of the fault to the next successful request, so
    #: this must be comfortably longer than the worst tolerable
    #: recovery or the measurement is censored rather than failed.
    recovery: float = 60.0


@dataclass(frozen=True)
class Profile:
    """A complete run definition."""

    name: str
    description: str

    #: Concurrency steps for the opening ramp. Sigul is serial, so this
    #: is not a search for a throughput knee - it is a search for the
    #: point where the bridge's listen backlog (5) starts refusing
    #: clients, which is a real and undocumented production limit.
    ramp_steps: tuple[int, ...] = (1, 2, 4, 8)
    ramp_step_seconds: float = 45.0

    #: Clean load before any faults, used as the within-run reference
    #: for latency and as the start point for leak trends.
    baseline_seconds: float = 120.0

    #: Concurrency held during the fault phase. Low by design: the
    #: point is to see what one bad client does to a small number of
    #: honest ones, not to saturate.
    steady_users: int = 3

    faults: tuple[FaultSlot, ...] = ()

    #: Clean load after the last fault. Compared against the baseline
    #: phase to expose leaks and permanent degradation.
    cooldown_seconds: float = 300.0

    #: Relative frequency of each operation under steady load. Weighted
    #: towards cheap control-plane calls because that is what CI does
    #: most, with enough large signing to keep real payloads moving.
    task_weights: dict[str, int] = field(
        default_factory=lambda: {
            "list_users": 4,
            "list_keys": 4,
            "sign_text": 6,
            "sign_data_1mb": 3,
            "sign_data_64mb": 1,
        }
    )

    def total_seconds(self) -> float:
        ramp = len(self.ramp_steps) * self.ramp_step_seconds
        faults = sum(f.duration + f.recovery for f in self.faults)
        return ramp + self.baseline_seconds + faults + self.cooldown_seconds


# The fault ordering matters. Cheap, well-understood faults come first
# so an early abort still yields useful data, and the two faults that
# reproduce the known production incident are placed mid-run where the
# stack has been under load long enough for state to have accumulated.
_PR_FAULTS: tuple[FaultSlot, ...] = (
    FaultSlot("client_connect_and_hang", 60, 45),
    FaultSlot("client_handshake_then_hang", 60, 60),
    FaultSlot("client_abrupt_reset", 45, 45),
    FaultSlot("net_latency_client", 60, 30),
    FaultSlot("client_backlog_flood", 45, 60),
    FaultSlot("net_blackhole_server_link", 90, 90),
    FaultSlot("proc_freeze_bridge", 45, 60),
    FaultSlot("proc_server_teardown_vs_frozen_bridge", 30, 60),
    FaultSlot("client_kill_mid_sign", 45, 45),
    FaultSlot("proc_restart_server", 30, 75),
    FaultSlot("proc_restart_bridge", 30, 75),
)

PR = Profile(
    name="pr",
    description="Pull-request gate: ~30 minutes, the eleven highest-value faults.",
    faults=_PR_FAULTS,
)

SMOKE = Profile(
    name="smoke",
    description="Harness self-test: proves every moving part works, proves nothing about Sigul.",
    ramp_steps=(1, 2),
    ramp_step_seconds=15.0,
    baseline_seconds=30.0,
    steady_users=2,
    faults=(
        FaultSlot("client_connect_and_hang", 20, 20),
        FaultSlot("proc_restart_server", 15, 40),
    ),
    cooldown_seconds=30.0,
)

NIGHTLY = Profile(
    name="nightly",
    description="Overnight soak: every fault, repeated, with long leak-detection windows.",
    ramp_steps=(1, 2, 4, 8, 12),
    ramp_step_seconds=60.0,
    baseline_seconds=600.0,
    steady_users=3,
    faults=(
        _PR_FAULTS
        + (
            FaultSlot("client_slow_loris", 120, 60),
            FaultSlot("client_half_close_hang", 60, 60),
            FaultSlot("client_garbage_handshake", 60, 45),
            FaultSlot("client_stop_mid_sign", 60, 60),
            FaultSlot("net_bandwidth_squeeze", 90, 45),
            FaultSlot("net_reset_peer_client", 60, 45),
            FaultSlot("net_blackhole_client", 60, 60),
            FaultSlot("proc_freeze_server", 45, 60),
        )
    )
    * 6,
    cooldown_seconds=900.0,
)

PROFILES: dict[str, Profile] = {p.name: p for p in (SMOKE, PR, NIGHTLY)}
