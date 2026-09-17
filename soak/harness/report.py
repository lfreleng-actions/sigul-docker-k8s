# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Render a run's results: markdown for the job summary, PNG charts."""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path

from .models import Results
from .stats import read_csv

_MARKS = {"pass": "✅ pass", "fail": "❌ FAIL", "xfail": "⚠️ xfail", "xpass": "🔁 xpass"}
_ICONS = {
    "pass": "✅",
    "fail": "❌",
    "xfail": "⚠️ xfail:",
    "xpass": "🔁 xpass:",
    "skip": "ℹ️",
}


def _fault_table(results: Results) -> list[str]:
    lines = [
        "## Faults and recovery",
        "",
        "| Fault | Held | Requests during | Failed | Longest stall | Recovery | Verdict |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    for f in results.faults:
        rec = (
            f"{f.recovery_seconds:.1f}s" if f.recovery_seconds is not None else "never"
        )
        stall = f"{f.max_stall_seconds:.0f}s" + (
            " ⚠️" if f.max_stall_seconds > f.stall_bound_seconds else ""
        )
        lines.append(
            f"| `{f.name}` | {f.end - f.start:.0f}s | {f.requests_during} | {f.failures_during} | "
            f"{stall} | {rec} | {_MARKS.get(f.verdict, f.verdict)} |"
        )
    lines.append("")
    problems = [f for f in results.faults if f.verdict in ("fail", "xfail")]
    if problems:
        lines += ["### What the failures mean", ""]
        for f in problems:
            lines.append(f"- **`{f.name}`** - {f.description}")
            lines.append(f"  - {f.note}")
            if f.implication:
                lines.append(f"  - Implication: {f.implication}")
        lines.append("")
    return lines


def _latency_tables(results: Results) -> list[str]:
    lines = ["## Latency (successful requests, ms)", ""]
    for phase in ("baseline", "cooldown"):
        stats = results.phases.get(phase)
        if not stats:
            continue
        lines += [
            f"**{phase}**",
            "",
            "| Task | n | ok | p50 | p95 | p99 | max |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
        for task, s in stats.items():
            lines.append(
                f"| `{task}` | {s.count} | {s.success_rate:.0%} | {s.p50_ms:.0f} | "
                f"{s.p95_ms:.0f} | {s.p99_ms:.0f} | {s.max_ms:.0f} |"
            )
        lines.append("")
    return lines


def _resource_table(results: Results) -> list[str]:
    lines = [
        "## Resources",
        "",
        "| Unit | RSS start | RSS end | Slope | FDs start | FDs end | CLOSE-WAIT peak/end | FIN-WAIT-2 peak | Zombies | Restarts in window |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for unit, r in results.resources.items():
        lines.append(
            f"| `{unit}` | {r.rss_start_mb} MB | {r.rss_end_mb} MB | {r.rss_slope_mb_per_hour:+.1f} MB/h | "
            f"{r.fds_start} | {r.fds_end} | {r.close_wait_max}/{r.close_wait_end} | "
            f"{r.fin_wait_2_max} | {r.zombies_max} | {r.restarts_in_window} |"
        )
    lines.append("")
    return lines


def write_report(results: Results, output_dir: Path) -> str:
    """Markdown report, suitable for a GitHub job summary."""
    duration_min = (results.ended - results.started) / 60.0
    icon = "✅" if results.verdict == "pass" else "❌"
    lines = [
        f"# Sigul soak: {icon} {results.verdict.upper()} (`{results.profile}`, {duration_min:.0f} min)",
        "",
    ]
    lines += _fault_table(results)
    lines += _latency_tables(results)
    lines += _resource_table(results)
    for title, checks in (
        ("Invariants", results.invariants),
        ("Regressions vs baseline", results.regressions),
    ):
        if not checks:
            continue
        lines += [f"## {title}", ""]
        for c in checks:
            lines.append(f"- {_ICONS.get(c.verdict, '❌')} {c.name} - {c.detail}")
        lines.append("")

    text = "\n".join(lines)
    (output_dir / "report.md").write_text(text)
    return text


def _load_chart_inputs(output_dir: Path):  # noqa: ANN202 - internal tuple
    requests = read_csv(output_dir / "requests.csv")
    samples = read_csv(output_dir / "samples.csv")
    timeline = read_csv(output_dir / "timeline.csv")
    if not requests and not samples:
        return None
    t0 = min(
        [float(r["epoch"]) for r in requests] + [float(r["epoch"]) for r in samples]
    )
    faults = [
        (
            r["name"],
            (float(r["start_epoch"]) - t0) / 60,
            (float(r["end_epoch"]) - t0) / 60,
        )
        for r in timeline
        if r["kind"] == "fault"
    ]
    return requests, samples, faults, t0


def _shade_faults(ax, faults) -> None:  # noqa: ANN001 - matplotlib Axes
    top = ax.get_ylim()[1]
    for name, start, end in faults:
        ax.axvspan(start, end, color="red", alpha=0.08)
        ax.text(
            (start + end) / 2,
            top,
            name.replace("_", "\n"),
            fontsize=5,
            ha="center",
            va="top",
            rotation=90,
        )


def _latency_chart(plt, requests, faults, t0: float, path: Path) -> None:  # noqa: ANN001
    fig, ax = plt.subplots(figsize=(14, 5))
    by_task: dict[str, list[tuple[float, float]]] = defaultdict(list)
    fails: list[float] = []
    for r in requests:
        t = (float(r["epoch"]) - t0) / 60
        if r["ok"] == "1":
            by_task[r["task"]].append((t, float(r["latency_ms"]) / 1000))
        else:
            fails.append(t)
    for task, points in sorted(by_task.items()):
        ax.scatter(
            [p[0] for p in points], [p[1] for p in points], s=6, label=task, alpha=0.7
        )
    if fails:
        ax.scatter(
            fails, [0.05] * len(fails), marker="x", color="red", s=18, label="failed"
        )
    ax.set_yscale("log")
    ax.set_xlabel("minutes")
    ax.set_ylabel("latency (s, log)")
    ax.set_title("Request latency; shaded = fault window")
    ax.legend(fontsize=7, loc="upper left", ncol=3)
    _shade_faults(ax, faults)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


def _resources_chart(plt, samples, faults, t0: float, path: Path) -> None:  # noqa: ANN001
    by_unit: dict[str, list[dict[str, str]]] = defaultdict(list)
    for r in samples:
        by_unit[r["unit"]].append(r)
    fig, axes = plt.subplots(3, 1, figsize=(14, 10), sharex=True)
    for unit, rows in sorted(by_unit.items()):
        ts = [(float(r["epoch"]) - t0) / 60 for r in rows]
        axes[0].plot(ts, [int(r["rss_bytes"]) / (1 << 20) for r in rows], label=unit)
        axes[1].plot(ts, [int(r["open_fds"]) for r in rows], label=unit)
        axes[2].plot(
            ts, [int(r["close_wait"]) for r in rows], label=f"{unit} CLOSE-WAIT"
        )
        axes[2].plot(
            ts, [int(r["fin_wait_2"]) for r in rows], "--", label=f"{unit} FIN-WAIT-2"
        )
    axes[0].set_ylabel("RSS (MB)")
    axes[1].set_ylabel("open FDs")
    axes[2].set_ylabel("sockets")
    axes[2].set_xlabel("minutes")
    for ax in axes:
        ax.legend(fontsize=7, loc="upper left")
        _shade_faults(ax, faults)
    axes[0].set_title("Daemon resources; shaded = fault window")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


def write_charts(output_dir: Path) -> list[Path]:
    """Latency, RSS and socket-state charts with fault windows shaded."""
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return []

    loaded = _load_chart_inputs(output_dir)
    if loaded is None:
        return []
    requests, samples, faults, t0 = loaded

    written: list[Path] = []
    if requests:
        path = output_dir / "latency.png"
        _latency_chart(plt, requests, faults, t0, path)
        written.append(path)
    if samples:
        path = output_dir / "resources.png"
        _resources_chart(plt, samples, faults, t0, path)
        written.append(path)
    return written
