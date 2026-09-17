# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Runs a profile's fault plan against the clock.

The scheduler owns the timeline. Every phase boundary and every fault
window is written to `timeline.csv` with wall-clock timestamps so the
analyser can lay latency, failures and resource readings over the
faults that caused them without any coupling between the processes
that produced them.
"""

from __future__ import annotations

import contextlib
import csv
import time
from collections.abc import Callable
from pathlib import Path

from .faults import Fault
from .faults.base import ProductDefect
from .profiles import FaultSlot, Profile


class Timeline:
    def __init__(self, output: Path) -> None:
        output.parent.mkdir(parents=True, exist_ok=True)
        self._handle = output.open("w", newline="")
        self._writer = csv.writer(self._handle)
        self._writer.writerow(["kind", "name", "start_epoch", "end_epoch", "note"])

    def record(
        self, kind: str, name: str, start: float, end: float, note: str = ""
    ) -> None:
        self._writer.writerow([kind, name, f"{start:.3f}", f"{end:.3f}", note])
        self._handle.flush()

    def close(self) -> None:
        self._handle.close()


class Scheduler:
    """Walk through a profile's phases, firing faults on cue."""

    def __init__(
        self,
        profile: Profile,
        registry: dict[str, Fault],
        timeline: Timeline,
        log=print,
    ) -> None:
        self._profile = profile
        self._registry = registry
        self._timeline = timeline
        self._log = log
        self._active: Fault | None = None

        missing = [
            slot.fault
            for slot in profile.preflight_faults + profile.warm_faults + profile.faults
            if slot.fault not in registry
        ]
        if missing:
            raise KeyError(f"profile {profile.name!r} names unknown faults: {missing}")

    def _sleep(self, seconds: float) -> None:
        time.sleep(seconds)

    def run_ramp(self) -> None:
        # Ramp is driven by Locust's own user spawning; here we only
        # record the phase so the analyser can bucket by concurrency.
        start = time.time()
        for users in self._profile.ramp_steps:
            step_start = time.time()
            self._log(
                f"[ramp] {users} users for {self._profile.ramp_step_seconds:.0f}s"
            )
            self._sleep(self._profile.ramp_step_seconds)
            self._timeline.record("ramp", f"users={users}", step_start, time.time())
        self._timeline.record("phase", "ramp", start, time.time())

    def run_baseline(self) -> None:
        start = time.time()
        self._log(f"[baseline] clean load for {self._profile.baseline_seconds:.0f}s")
        self._sleep(self._profile.baseline_seconds)
        self._timeline.record("phase", "baseline", start, time.time())

    def run_preflight(self, probe: Callable[[], None]) -> None:
        """Faults that need an idle stack, run before the load starts.

        No load generator is running, so recovery is measured by calling
        `probe` - one real request, logged like any other - every couple
        of seconds through the recovery window.
        """
        if not self._profile.preflight_faults:
            return
        start = time.time()
        self._run_slots(self._profile.preflight_faults, "preflight", probe)
        self._timeline.record("phase", "preflight", start, time.time())

    def run_warm_faults(self) -> None:
        """Restarts and other lifetime-resetting faults, before baseline."""
        if not self._profile.warm_faults:
            return
        start = time.time()
        self._run_slots(self._profile.warm_faults, "warm")
        self._timeline.record("phase", "warm", start, time.time())

    def run_faults(self) -> None:
        start = time.time()
        self._run_slots(self._profile.faults, "fault")
        self._timeline.record("phase", "faults", start, time.time())

    def _run_slots(
        self,
        slots: tuple[FaultSlot, ...],
        label: str,
        probe: Callable[[], None] | None = None,
    ) -> None:
        for index, slot in enumerate(slots, start=1):
            fault = self._registry[slot.fault]
            self._log(
                f"[{label} {index}/{len(slots)}] {fault.name}: on for {slot.duration:.0f}s, "
                f"then {slot.recovery:.0f}s recovery - {fault.description}"
            )
            start = time.time()
            note = ""
            try:
                self._active = fault
                fault.start()
            except ProductDefect as exc:
                # The fault worked and caught the product misbehaving.
                # Recorded with its own prefix so the analyser can treat
                # it as a product failure rather than a harness one.
                note = f"defect: {exc}"
                self._log(f"  ! {note}")
            except Exception as exc:  # noqa: BLE001 - report, do not abort the run
                note = f"start failed: {exc!r}"
                self._log(f"  ! {note}")
            if slot.duration > 0:
                self._sleep(slot.duration)
            try:
                fault.stop()
            except Exception as exc:  # noqa: BLE001
                note = (note + "; " if note else "") + f"stop failed: {exc!r}"
                self._log(f"  ! {note}")
            finally:
                self._active = None
            end = time.time()
            self._timeline.record("fault", fault.name, start, end, note)
            if probe is None:
                self._sleep(slot.recovery)
            else:
                deadline = time.time() + slot.recovery
                while time.time() < deadline:
                    probe()
                    self._sleep(min(2.0, max(0.0, deadline - time.time())))
            self._timeline.record("recovery", fault.name, end, time.time())

    def run_cooldown(self) -> None:
        start = time.time()
        self._log(f"[cooldown] clean load for {self._profile.cooldown_seconds:.0f}s")
        self._sleep(self._profile.cooldown_seconds)
        self._timeline.record("phase", "cooldown", start, time.time())

    def abort(self) -> None:
        """Best-effort cleanup if the run is interrupted mid-fault."""
        if self._active is not None:
            # Interrupt-path cleanup: a fault whose stop() fails here has
            # already been logged by the run loop if it failed there,
            # and there is nothing further to do with the error.
            with contextlib.suppress(Exception):
                self._active.stop()
            self._active = None
