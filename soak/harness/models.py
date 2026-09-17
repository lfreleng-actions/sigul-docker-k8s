# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Result types shared by the analyser and the report writer."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Check:
    name: str
    ok: bool
    detail: str
    #: pass | fail | xfail | xpass | skip, once expectations are applied.
    verdict: str = ""
    #: An informational reading that the run had too little data to
    #: judge. Reported, never failed, never matched to an expectation.
    informational: bool = False

    def judge(self, expectations: dict[str, dict]) -> Check:
        if self.informational:
            self.verdict = "skip"
            return self
        expectation = expectations.get(self.name, {})
        expected_fail = expectation.get("expect") == "fail"
        if self.ok and not expected_fail:
            self.verdict = "pass"
        elif not self.ok and expected_fail:
            self.verdict = "xfail"
        elif self.ok and expected_fail:
            self.verdict = "xpass"
        else:
            self.verdict = "fail"
        if expectation.get("issue"):
            self.detail += f" [expected fail: {expectation['issue']}]"
        return self


@dataclass
class TaskStats:
    count: int = 0
    ok: int = 0
    p50_ms: float = 0.0
    p95_ms: float = 0.0
    p99_ms: float = 0.0
    max_ms: float = 0.0

    @property
    def success_rate(self) -> float:
        return self.ok / self.count if self.count else 0.0


@dataclass
class FaultResult:
    name: str
    start: float
    end: float
    requests_during: int
    failures_during: int
    recovery_seconds: float | None
    max_recovery_seconds: float
    #: Longest gap between successful requests from the fault's start
    #: until service resumed. The fault window itself counts: a fault
    #: that blocks the service for its whole duration and then releases
    #: it shows fast recovery and a stall the length of the window.
    max_stall_seconds: float
    stall_bound_seconds: float
    expected: str
    verdict: str = ""
    note: str = ""
    description: str = ""
    implication: str = ""


@dataclass
class UnitResources:
    rss_start_mb: float
    rss_end_mb: float
    rss_slope_mb_per_hour: float
    fds_start: int
    fds_end: int
    close_wait_max: int
    close_wait_end: int
    fin_wait_2_max: int
    zombies_max: int
    samples: int
    #: Distinct container lifetimes seen from the start of the baseline
    #: phase to the end of cooldown, minus one. Anything but zero means
    #: the unit restarted inside the measured window, which resets
    #: memory, descriptors and sockets and invalidates the comparison.
    restarts_in_window: int = 0
    #: Seconds from the first baseline sample to the last cooldown one:
    #: the span the RSS trend is fitted over.
    span_seconds: float = 0.0


@dataclass
class Results:
    profile: str
    started: float
    ended: float
    phases: dict[str, dict[str, TaskStats]] = field(default_factory=dict)
    faults: list[FaultResult] = field(default_factory=list)
    resources: dict[str, UnitResources] = field(default_factory=dict)
    invariants: list[Check] = field(default_factory=list)
    regressions: list[Check] = field(default_factory=list)
    verdict: str = "fail"


@dataclass(frozen=True)
class FaultMeta:
    """What the fault registry knows about a fault, for the report."""

    description: str = ""
    implication: str = ""
    service_possible_during: bool = True
