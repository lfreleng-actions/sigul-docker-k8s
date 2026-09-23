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
    #: Seconds to hold the fault active. Zero for a fault that is
    #: complete when start() returns, such as a restart, so the
    #: recovery clock begins the moment the disturbance ends.
    duration: float = 60.0
    #: Seconds of clean running afterwards. This is also the window in
    #: which recovery can be observed, so the effective recovery bound
    #: is the smaller of the configured bound and this. Profiles that
    #: judge recovery keep it at least as long as the default bound;
    #: the smoke profile keeps it short and accepts the tighter bound.
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

    #: Faults run before the load generator starts, against an idle
    #: stack. The production deadlock struck an idle server child - one
    #: with no request in flight - and the fix deliberately refuses to
    #: abandon a connection that still has data to deliver, so the
    #: fault must find the child idle to be testing the right thing.
    #: Recovery is measured with the harness's own probe requests.
    preflight_faults: tuple[FaultSlot, ...] = (
        FaultSlot("server_teardown_vs_silent_peer", 0, 60),
    )

    #: Faults run after the ramp and before the baseline. Restarts go
    #: here: a restart resets memory, descriptors and sockets, so one
    #: anywhere between baseline and cooldown would make the leak
    #: comparison meaningless. Recovery is still measured for them.
    warm_faults: tuple[FaultSlot, ...] = (
        FaultSlot("proc_restart_server", 0, 60),
        FaultSlot("proc_restart_bridge", 0, 60),
    )

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
        faults = sum(
            f.duration + f.recovery
            for f in self.preflight_faults + self.warm_faults + self.faults
        )
        return ramp + self.baseline_seconds + faults + self.cooldown_seconds


# The fault ordering matters. Cheap, well-understood faults come first
# so an early abort still yields useful data, and the two faults that
# reproduce the known production incident are placed mid-run where the
# stack has been under load long enough for state to have accumulated.
_PR_FAULTS: tuple[FaultSlot, ...] = (
    FaultSlot("client_connect_and_hang", 60, 60),
    # Held past the bridge's 120 s request idle deadline (patch 11), so
    # the run asserts that a frozen client is shed, not merely that the
    # service recovers once the client is killed.
    FaultSlot("client_handshake_then_hang", 150, 60),
    FaultSlot("client_abrupt_reset", 45, 60),
    FaultSlot("net_latency_client", 60, 60),
    FaultSlot("client_backlog_flood", 45, 60),
    FaultSlot("net_blackhole_server_link", 90, 90),
    FaultSlot("proc_freeze_bridge", 45, 60),
    # Complete when start() returns - the kill has been delivered - so
    # no hold; the recovery window is what matters.
    FaultSlot("client_kill_mid_sign", 0, 60),
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
    warm_faults=(FaultSlot("proc_restart_server", 0, 30),),
    faults=(FaultSlot("client_connect_and_hang", 20, 30),),
    cooldown_seconds=30.0,
)

NIGHTLY = Profile(
    name="nightly",
    description="Overnight soak: every fault, repeated, with long leak-detection windows.",
    ramp_steps=(1, 2, 4, 8, 12),
    ramp_step_seconds=60.0,
    preflight_faults=(FaultSlot("server_teardown_vs_silent_peer", 0, 60),) * 6,
    warm_faults=(
        FaultSlot("proc_restart_server", 0, 60),
        FaultSlot("proc_restart_bridge", 0, 60),
    )
    * 6,
    baseline_seconds=600.0,
    steady_users=3,
    faults=(
        _PR_FAULTS
        + (
            FaultSlot("client_slow_loris", 120, 60),
            FaultSlot("client_half_close_hang", 60, 60),
            FaultSlot("client_garbage_handshake", 60, 60),
            FaultSlot("client_stop_mid_sign", 150, 60),
            FaultSlot("net_bandwidth_squeeze", 90, 60),
            FaultSlot("net_reset_peer_client", 60, 60),
            FaultSlot("net_blackhole_client", 60, 60),
            FaultSlot("proc_freeze_server", 45, 60),
        )
    )
    * 6,
    cooldown_seconds=900.0,
)

#: The Kubernetes target's own profile. It names only faults that
#: target can honestly inject, which is a shorter list than Compose's
#: and deliberately so:
#:
#: - The raw-socket client faults dial the bridge directly, and its
#:   Service is ClusterIP - unreachable from where this harness runs.
#:   Compose covers that ground thoroughly.
#: - Network toxics need Toxiproxy in the request path, which is a
#:   separate piece of plumbing in a cluster.
#:
#: What is left is what this target exists for: pods dying and being
#: replaced by their controllers, with the chart's probes deciding
#: when the replacement may serve. Restarts cost far more here than
#: under Compose - a StatefulSet pod measured 22 s against a
#: container's 2 s - so the windows are longer and the load lighter,
#: since every request also pays for a kubectl exec.
#:
#: And pods that wedge rather than die. The wedge faults freeze a
#: daemon from its kind node and leave it frozen, to see whether the
#: chart's probes notice. It is the one question Compose cannot ask,
#: because nothing there would replace a failing container anyway.
#: They are why this profile needs a kind cluster: on any other, the
#: freeze capability is absent and the run is refused before it starts.
#:
#: All of them are warm faults, before the baseline, for the same
#: reason the Compose profiles place restarts there: the leak
#: comparison runs from baseline to cooldown and means nothing across
#: a restart, and "no restart between baseline and cooldown" is an
#: invariant rather than something to be marked expected-fail. A wedge
#: ends in a restart one way or another - by the kubelet if the probes
#: notice, by the fault itself if they do not. Their stalls and
#: recovery times are measured exactly as any other fault's.
K8S = Profile(
    name="k8s",
    description="Kubernetes target: chart probes, controller replacement, wedges.",
    ramp_steps=(1, 2),
    ramp_step_seconds=30.0,
    preflight_faults=(),
    warm_faults=(
        FaultSlot("proc_restart_bridge", 0, 90),
        FaultSlot("proc_restart_server", 0, 120),
        # No hold: start() itself waits for the replacement, up to the
        # fault's own bound, so the window is as long as the wedge.
        FaultSlot("proc_wedge_bridge", 0, 90),
        FaultSlot("proc_wedge_server", 0, 120),
    ),
    baseline_seconds=90.0,
    steady_users=2,
    faults=(),
    cooldown_seconds=180.0,
)

PROFILES: dict[str, Profile] = {p.name: p for p in (SMOKE, PR, NIGHTLY, K8S)}
