# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Periodic readings of the daemons' health.

Runs in a background thread for the whole soak and writes one CSV row
per unit per tick. The analyser fits trends to these; a single reading
means little, but RSS or open descriptors climbing steadily across
thirty minutes of constant load means a leak, and CLOSE-WAIT sockets
that never return to zero mean connections nobody is closing.
"""

from __future__ import annotations

import csv
import threading
import time
from pathlib import Path

from .target import Target

COLUMNS = (
    "epoch",
    "unit",
    "rss_bytes",
    "cpu_percent",
    "pids",
    "open_fds",
    "zombies",
    "established",
    "close_wait",
    "fin_wait_2",
    "time_wait",
    "syn_recv",
    "started_at",
)


#: Long enough for a whole tick of readings to fail on the target's
#: API bound: two units, each with several calls that may each take
#: DockerTarget.API_TIMEOUT_SECONDS.
STOP_TIMEOUT_SECONDS = 180.0


class Sampler:
    def __init__(
        self,
        target: Target,
        units: tuple[str, ...],
        output: Path,
        interval: float = 5.0,
    ) -> None:
        self._target = target
        self._units = units
        self._output = output
        self._interval = interval
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.errors = 0

    def start(self) -> None:
        self._output.parent.mkdir(parents=True, exist_ok=True)
        self._thread = threading.Thread(target=self._run, name="sampler", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        """Stop sampling and wait for the writer to have closed the file.

        One in-flight reading may take up to the target's full API bound
        to fail, and the loop finishes the units of the current tick
        before it checks the stop flag. Wait long enough for that, and
        report loudly if the thread is still alive afterwards: analysis
        reading a file the sampler still has open is not acceptable.
        """
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=STOP_TIMEOUT_SECONDS)
            if self._thread.is_alive():
                raise RuntimeError(
                    f"sampler thread still running {STOP_TIMEOUT_SECONDS:.0f}s after stop()"
                )

    def _run(self) -> None:
        with self._output.open("w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(COLUMNS)
            while not self._stop.is_set():
                tick = time.time()
                for unit in self._units:
                    if self._stop.is_set():
                        break
                    row = self._sample(unit, tick)
                    if row is not None:
                        writer.writerow(row)
                handle.flush()
                # Fixed cadence regardless of how long sampling took, so
                # a frozen container (which makes exec slow) does not
                # also distort the time axis.
                self._stop.wait(max(0.0, self._interval - (time.time() - tick)))

    def _sample(self, unit: str, tick: float) -> list | None:
        try:
            stats = self._target.stats(unit)
            sockets = self._target.sockets(unit)
            fds = self._target.open_fds(unit)
            zombies = self._target.zombies(unit)
            started_at = self._target.started_at(unit)
        except Exception:  # noqa: BLE001 - a frozen or restarting unit is expected
            self.errors += 1
            return None
        return [
            f"{tick:.3f}",
            unit,
            stats.rss_bytes,
            stats.cpu_percent,
            stats.pids,
            fds,
            zombies,
            sockets.established,
            sockets.close_wait,
            sockets.fin_wait_2,
            sockets.time_wait,
            sockets.syn_recv,
            f"{started_at:.3f}",
        ]
