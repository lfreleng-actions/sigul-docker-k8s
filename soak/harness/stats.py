# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Loading the run's CSVs, and the arithmetic over them."""

from __future__ import annotations

import csv
import math
import statistics
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from .models import TaskStats


@dataclass(frozen=True)
class Request:
    """One row of requests.csv."""

    t: float
    task: str
    latency_ms: float
    ok: bool


@dataclass
class Run:
    """The three CSVs, parsed once."""

    requests: list[Request]
    samples: list[dict[str, str]]
    timeline: list[dict[str, str]]
    successes: list[float]

    @classmethod
    def load(cls, output_dir: Path) -> Run:
        requests = [
            Request(
                float(r["epoch"]), r["task"], float(r["latency_ms"]), r["ok"] == "1"
            )
            for r in read_csv(output_dir / "requests.csv")
        ]
        return cls(
            requests=requests,
            samples=read_csv(output_dir / "samples.csv"),
            timeline=read_csv(output_dir / "timeline.csv"),
            successes=sorted(r.t for r in requests if r.ok),
        )

    def between(self, start: float, end: float) -> list[Request]:
        return [r for r in self.requests if start <= r.t <= end]


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(newline="") as handle:
        return list(csv.DictReader(handle))


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(pct / 100.0 * len(ordered)) - 1))
    return ordered[index]


def task_stats(rows: list[Request]) -> dict[str, TaskStats]:
    by_task: dict[str, list[Request]] = defaultdict(list)
    for row in rows:
        by_task[row.task].append(row)
    out: dict[str, TaskStats] = {}
    for task, task_rows in sorted(by_task.items()):
        latencies = [r.latency_ms for r in task_rows if r.ok]
        out[task] = TaskStats(
            count=len(task_rows),
            ok=sum(1 for r in task_rows if r.ok),
            p50_ms=round(percentile(latencies, 50), 1),
            p95_ms=round(percentile(latencies, 95), 1),
            p99_ms=round(percentile(latencies, 99), 1),
            max_ms=round(max(latencies), 1) if latencies else 0.0,
        )
    return out


def slope_per_hour(points: list[tuple[float, float]]) -> float:
    """Least-squares slope of value against time, in units per hour."""
    if len(points) < 2:
        return 0.0
    mean_x = statistics.fmean(p[0] for p in points)
    mean_y = statistics.fmean(p[1] for p in points)
    denominator = sum((x - mean_x) ** 2 for x, _ in points)
    if denominator == 0:
        return 0.0
    slope_per_second = sum((x - mean_x) * (y - mean_y) for x, y in points) / denominator
    return slope_per_second * 3600.0
