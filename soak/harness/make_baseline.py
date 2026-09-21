#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard
"""Build a regression baseline from several green soak runs.

The committed baseline is what every later run is judged against, so
how it was produced has to be reproducible and recorded rather than
hand-assembled. This reads the `results.json` of runs that passed and
writes `soak/harness/baseline-<profile>.json`.

The reference for each figure is the *worst* value observed across the
runs given - the slowest latency, the fewest completions - with the
tolerances in checks.py on top. That is a deliberate trade rather than
a free one: measuring against the unluckiest green run instead of a
typical one means smaller degradations pass unnoticed. It buys a gate
that does not fail on ordinary run-to-run variance, which for a
blocking check is worth more than the sensitivity it costs.
soak/README.md records what survives the trade.

Percentiles are recorded only where enough requests completed to
estimate them (see MIN_SAMPLES_P50 / MIN_SAMPLES_P95): Sigul serves one
request at a time behind a 64 MiB signing task, so a tail drawn from a
handful of completions measures scheduling luck, not the service.

Usage:

    python3 soak/harness/make_baseline.py \\
        --profile pr \\
        --phase cooldown \\
        --note 'v2.3.1, ubuntu-latest, runs 35368560978 and 35368576211' \\
        run1/results.json run2/results.json ...

Refreshing the baseline is a deliberate act. Legitimate reasons: an
intended performance change, a change of runner image, a change to the
load profile. "The gate is red" is not one - that is the gate working.
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent

#: What platform.machine() reports, against the names used for the
#: runners and image tags. Both spellings are in use across the
#: repository, so they name the same hardware and are folded together
#: before anything is compared.
_ALIASES = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "linux-amd64": "x86_64",
    "aarch64": "aarch64",
    "arm64": "aarch64",
    "linux-arm64": "aarch64",
}


def canonical(name: str) -> str:
    """Fold a platform spelling onto one name, or fail loudly."""
    try:
        return _ALIASES[name]
    except KeyError:
        raise SystemExit(
            f"unknown platform {name!r}; expected one of " + ", ".join(sorted(_ALIASES))
        ) from None


# Imported rather than duplicated, so the floors and the profile's
# task list cannot drift away from the harness they came from. This
# module is run both as part of the package and as a bare script -
# soak/README.md documents the latter - so cope with both rather than
# degrade when the relative import fails. Everything in this chain is
# standard library, so there is no case where the import legitimately
# cannot happen; treating one as if there were is how the
# completeness check came to be silently disabled.
if __package__:
    from .checks import MIN_SAMPLES_P50, MIN_SAMPLES_P95, MIN_TASK_COMPLETIONS
    from .profiles import PROFILES
else:  # pragma: no cover - script invocation
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from harness.checks import MIN_SAMPLES_P50, MIN_SAMPLES_P95, MIN_TASK_COMPLETIONS
    from harness.profiles import PROFILES


def _phase_tasks(
    phase: str,
    per_run: list[dict[str, Any]],
    expected_tasks: set[str],
    profile: str,
) -> list[str]:
    """The tasks to record, or refuse if the runs cannot describe them."""
    # Filtering the empty ones out would build the baseline from a
    # subset while the provenance still claimed every run, so a missing
    # phase is refused rather than skipped.
    short = [i for i, p in enumerate(per_run, 1) if not p]
    if short:
        raise SystemExit(
            f"run(s) {', '.join(map(str, short))} carry no {phase!r} phase; "
            "refusing to build from a subset of the runs given"
        )
    tasks = sorted({t for p in per_run for t in p})
    absent = expected_tasks - set(tasks)
    if absent:
        # The union across runs cannot reveal a task that no run
        # exercised, and a task missing from the file can never fail the
        # activity floor - so it would be unmonitored for the life of
        # the baseline. The aggregate clean-phase checks would not
        # notice either: they judge total requests and overall success
        # rate.
        raise SystemExit(
            f"no run exercised {', '.join(sorted(absent))} in {phase!r}; "
            "the baseline would leave them unmonitored"
        )
    unexpected = set(tasks) - expected_tasks
    if unexpected:
        # The mirror image, and worse: a task the profile no longer has
        # - renamed, or dropped - would be written in with the
        # completions it once managed, and no current run could ever
        # produce it. Every run would then fail its activity floor, for
        # good.
        raise SystemExit(
            f"runs exercised {', '.join(sorted(unexpected))} in {phase!r}, "
            f"which profile {profile!r} no longer defines; "
            "they predate a rename or removal"
        )
    return tasks


def _task_entry(seen: list[dict[str, Any]]) -> dict[str, Any]:
    """One task's reference figures, from every run that exercised it."""
    ok = min(s["ok"] for s in seen)
    # Take count and ok as a *pair* from the run with the worst success
    # rate, rather than minimising each independently. Minimising
    # separately can synthesise a rate that occurred in no run and is
    # stricter than all of them: 90/100 and 50/50 would yield 50/50,
    # demanding 100% where the worst run managed 90%. The lowest rate
    # actually observed is the honest reference. Ties - every run at
    # 100%, usually - go to the fewest completions, so the file does not
    # depend on the order the runs were named in.
    worst = min(
        seen,
        key=lambda s: (s["ok"] / s["count"] if s["count"] else 1.0, s["ok"]),
    )
    entry: dict[str, Any] = {
        "count": worst["count"],
        "ok": worst["ok"],
        # How much of this task the run is expected to get through, kept
        # apart from the pair above because they answer different
        # questions. Reusing that pair here would reintroduce the same
        # class of error: with 900/1000 and 100/100 accepted, the rate
        # reference is 900, and a floor derived from it would fail the
        # 100/100 run that helped produce the baseline.
        "min_ok": ok,
    }
    for metric, floor in (("p50", MIN_SAMPLES_P50), ("p95", MIN_SAMPLES_P95)):
        key = f"{metric}_ms"
        # The fewest completions any run managed decides whether the
        # percentile is worth recording at all; checks.py then only has
        # to ask whether the run being judged has enough.
        if ok >= floor:
            entry[key] = round(max(s[key] for s in seen), 1)
    return entry


def _comment(platform: str) -> list[str]:
    return [
        "Regression baseline. Generated by make_baseline.py from green",
        "runs - do not hand-edit; regenerate and say why in the commit.",
        "",
        "Each figure is the worst observed across those runs: the",
        "slowest latency, the fewest completions. Comparisons in",
        "checks.py are one-sided and add their own tolerance on top.",
        "That trades sensitivity for stability: a regression is judged",
        "against the unluckiest green run rather than a typical one, so",
        "smaller degradations pass. See soak/README.md for what does",
        "not.",
        "",
        "Percentiles appear only where enough requests completed to",
        f"estimate them ({MIN_SAMPLES_P50} for p50, {MIN_SAMPLES_P95} for",
        "p95). Sigul is strictly serial and the load mix contains a",
        "64 MiB signing task, so a tail drawn from fewer samples",
        "measures which request queued behind it, not the service.",
        "",
        "Only the phases listed here are compared. The short baseline",
        "phase is deliberately absent: at ~20 completions per task its",
        "p95 swung 7x across green runs.",
        "",
        f"Captured on {platform}. Architectures differ by more than",
        "run-to-run noise - arm64 completed 1.6x the work of amd64 in",
        "the same cooldown - so these figures describe one platform.",
        "Since every comparison is one-sided and the gate runs on",
        "amd64, an amd64 baseline is safe on faster hardware; it is",
        "simply less sensitive there.",
    ]


def build(
    runs: list[dict[str, Any]],
    phases: list[str],
    note: str,
    platform: str,
    profile: str,
    expected_tasks: set[str],
) -> dict[str, Any]:
    out_phases: dict[str, Any] = {}
    for phase in phases:
        per_run = [r["phases"].get(phase, {}) for r in runs]
        tasks = _phase_tasks(phase, per_run, expected_tasks, profile)
        out_tasks: dict[str, Any] = {}
        missing: list[str] = []
        scarce: list[str] = []
        for task in tasks:
            seen = [p[task] for p in per_run if task in p]
            if len(seen) < len(per_run):
                # Dropping the task here would quietly narrow the gate
                # for good: regressions() iterates the baseline's tasks,
                # so a task absent from the file can never trigger the
                # activity floor. Refuse instead, and let whoever is
                # capturing decide - usually by choosing runs where
                # every task appeared, or by asking why one did not.
                missing.append(
                    f"{phase}/{task}: present in {len(seen)} of {len(per_run)} runs"
                )
                continue
            entry = _task_entry(seen)
            if entry["min_ok"] < MIN_TASK_COMPLETIONS:
                # The activity floor in checks.py never goes below
                # MIN_TASK_COMPLETIONS, so a task this rare would give
                # a baseline that fails the very runs it was built
                # from. Too few completions to judge is a reason to
                # gather more, not to write a reference that cannot be
                # met - most likely the profile is too short for this
                # task's weight.
                scarce.append(
                    f"{phase}/{task}: {entry['min_ok']} completions at worst, "
                    f"below the floor of {MIN_TASK_COMPLETIONS}"
                )
                continue
            out_tasks[task] = entry
        if missing or scarce:
            raise SystemExit(
                "refusing to write a baseline these runs cannot support:\n  "
                + "\n  ".join(missing + scarce)
            )
        out_phases[phase] = {
            "total_ok": min(sum(s["ok"] for s in p.values()) for p in per_run),
            "tasks": out_tasks,
        }
    return {
        "_comment": _comment(platform),
        "provenance": {
            "generated": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d"),
            "platform": platform,
            "runs": len(runs),
            "note": note,
        },
        "phases": out_phases,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="+", type=Path)
    parser.add_argument("--profile", default="pr")
    parser.add_argument(
        "--phase",
        action="append",
        dest="phases",
        help="phase to record; repeatable (default: cooldown)",
    )
    parser.add_argument(
        "--note",
        required=True,
        help="provenance: which runs, which images, which runner",
    )
    parser.add_argument(
        "--platform",
        default="linux-amd64",
        help="platform these runs came from; the gate's is linux-amd64",
    )
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    if not args.note.strip():
        raise SystemExit("--note must say which runs and images this came from")
    want = canonical(args.platform)

    runs = []
    platforms: set[str] = set()
    for path in args.results:
        data = json.loads(path.read_text())
        if data.get("verdict") not in ("pass",):
            raise SystemExit(f"{path}: verdict is {data.get('verdict')!r}, not 'pass'")
        if data.get("profile") != args.profile:
            raise SystemExit(
                f"{path}: profile is {data.get('profile')!r}, not {args.profile!r}"
            )
        # Runs from before the harness recorded this carry no platform;
        # they are accepted, and the file says how many, so the claim
        # can be checked against the run IDs in --note.
        if data.get("platform"):
            platforms.add(canonical(data["platform"]))
        runs.append(data)
    unlabelled = sum(1 for d in runs if not d.get("platform"))
    if len(platforms) > 1:
        raise SystemExit(
            "refusing to mix architectures in one baseline: "
            + ", ".join(sorted(platforms))
            + "\narm64 has completed 1.6x the work amd64 did on the same"
            "\nprofile, so a mixed reference describes neither."
        )
    if platforms and want not in platforms:
        raise SystemExit(
            f"runs were measured on {next(iter(platforms))!r}, "
            f"which is not --platform {args.platform!r}"
        )
    if len(runs) < 2:
        print("warning: a baseline from a single run records luck, not behaviour")
    if unlabelled:
        print(
            f"warning: {unlabelled} of {len(runs)} runs predate platform"
            f" recording; --platform {args.platform} is taken on trust for those"
        )

    baseline = build(
        runs,
        args.phases or ["cooldown"],
        args.note,
        args.platform,
        args.profile,
        set(PROFILES[args.profile].task_weights),
    )
    out = args.out or HERE / f"baseline-{args.profile}.json"
    out.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out} from {len(runs)} run(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
