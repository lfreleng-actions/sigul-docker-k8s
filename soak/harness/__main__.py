# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Run one soak profile end to end.

    python3 -m harness [profile]        # run load, faults, sampling, analysis
    python3 -m harness --analyse-only   # re-run analysis on existing results

Order of operations:

1. Wait for the stack to serve a request at all.
2. Point Toxiproxy at the bridge (no toxics yet).
3. Start the sampler.
4. Start Locust headless with the profile's user count and duration.
5. Walk the profile: ramp, baseline, faults, cooldown.
6. Stop Locust, stop the sampler, analyse, write report and charts.

Exit status is the verdict, so CI can gate on it directly.
"""

from __future__ import annotations

import contextlib
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import analyze, report
from .analyze import FaultMeta
from .faults import build_registry
from .faults.network import configure_proxies
from .profiles import PROFILES, Profile
from .sampler import Sampler
from .scheduler import Scheduler, Timeline
from .target import DockerTarget

HERE = Path(__file__).resolve().parent


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def wait_for_service(config: str, password: str, attempts: int = 60) -> None:
    """Block until one real request succeeds, or give up."""
    for attempt in range(1, attempts + 1):
        proc = subprocess.run(  # noqa: S603
            ["sigul", "--batch", "-c", config, "list-users"],
            input=password.encode() + b"\0",
            capture_output=True,
            timeout=60,
            check=False,
        )
        if proc.returncode == 0:
            log(f"stack is serving (attempt {attempt})")
            return
        time.sleep(5)
    raise SystemExit("stack never served a request; aborting soak")


def start_locust(
    profile: Profile, output_dir: Path, duration: float
) -> subprocess.Popen:
    """Launch Locust headless. Concurrency follows `ProfileShape` in the
    locustfile, which reads the ramp and steady values passed here."""
    env = dict(os.environ)
    for task, weight in profile.task_weights.items():
        env[f"SOAK_W_{task.upper().replace('SIGN_DATA_', 'SIGN_')}"] = str(weight)
    env["SOAK_RAMP_STEPS"] = ",".join(str(s) for s in profile.ramp_steps)
    env["SOAK_RAMP_STEP_SECONDS"] = str(profile.ramp_step_seconds)
    env["SOAK_STEADY_USERS"] = str(profile.steady_users)
    env["SOAK_TOTAL_SECONDS"] = str(duration + 60)

    argv = [
        "locust",
        "-f",
        str(HERE / "locustfile.py"),
        "--headless",
        "--csv",
        str(output_dir / "locust"),
        "--csv-full-history",
        "--html",
        str(output_dir / "locust.html"),
        "--only-summary",
        "--loglevel",
        "WARNING",
    ]
    log(
        f"starting locust: ramp {profile.ramp_steps} x {profile.ramp_step_seconds:.0f}s, "
        f"then {profile.steady_users} users for the rest of {duration:.0f}s"
    )
    return subprocess.Popen(argv, env=env)  # noqa: S603


def run(profile: Profile, output_dir: Path) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    for stale in ("requests.csv", "samples.csv", "timeline.csv"):
        (output_dir / stale).unlink(missing_ok=True)

    config = os.environ.get("SIGUL_CONFIG", "/etc/sigul/client.conf")
    password = Path("/test-artifacts/admin-password").read_text().strip()
    bridge = os.environ.get("SOAK_BRIDGE_CONTAINER", "sigul-bridge")
    server = os.environ.get("SOAK_SERVER_CONTAINER", "sigul-server")

    log(f"profile {profile.name}: {profile.description}")
    log(
        f"planned duration {profile.total_seconds() / 60:.1f} min, {len(profile.faults)} faults"
    )

    configure_proxies(bridge)
    wait_for_service(config, password)

    target = DockerTarget()
    registry = build_registry(target)
    timeline = Timeline(output_dir / "timeline.csv")
    scheduler = Scheduler(profile, registry, timeline, log=log)
    sampler = Sampler(target, (bridge, server), output_dir / "samples.csv")

    locust: subprocess.Popen | None = None

    def shutdown(*_args) -> None:
        log("interrupted; cleaning up")
        scheduler.abort()
        # Best-effort restoration on the way out: a proxy or daemon we
        # cannot reach is not something the interrupt path can fix.
        with contextlib.suppress(Exception):
            from .faults.network import client as toxiproxy

            toxiproxy().reset()
        for unit in (bridge, server):
            with contextlib.suppress(Exception):
                target.thaw(unit)
        if locust is not None and locust.poll() is None:
            locust.send_signal(signal.SIGINT)
        sampler.stop()
        timeline.close()
        raise SystemExit(130)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    sampler.start()
    locust = start_locust(profile, output_dir, profile.total_seconds())
    started = time.time()
    try:
        scheduler.run_ramp()
        scheduler.run_baseline()
        scheduler.run_faults()
        scheduler.run_cooldown()
    finally:
        log("stopping load")
        if locust.poll() is None:
            locust.send_signal(signal.SIGINT)
            try:
                locust.wait(timeout=60)
            except subprocess.TimeoutExpired:
                locust.kill()
        sampler.stop()
        timeline.record("phase", "run", started, time.time())
        timeline.close()
        if sampler.errors:
            log(f"sampler: {sampler.errors} readings skipped (units restarting/frozen)")

    return analyse_and_report(profile.name, output_dir, registry)


def analyse_and_report(
    profile_name: str, output_dir: Path, registry: dict | None = None
) -> int:
    if registry is None:
        registry = build_registry(DockerTarget())
    fault_meta = {
        name: FaultMeta(f.description, f.implication, f.service_possible_during)
        for name, f in registry.items()
    }

    expectations_path = HERE / "expectations.json"
    all_expectations = (
        json.loads(expectations_path.read_text()) if expectations_path.is_file() else {}
    )
    expectations = all_expectations.get(profile_name, {})
    baseline_path = HERE / f"baseline-{profile_name}.json"
    baseline = (
        json.loads(baseline_path.read_text()) if baseline_path.is_file() else None
    )
    if baseline is None:
        log(f"no baseline at {baseline_path.name}; regression checks skipped")

    units = (
        os.environ.get("SOAK_BRIDGE_CONTAINER", "sigul-bridge"),
        os.environ.get("SOAK_SERVER_CONTAINER", "sigul-server"),
    )
    results = analyze.analyse(
        output_dir, profile_name, fault_meta, expectations, baseline, units
    )
    analyze.write_results(results, output_dir)
    text = report.write_report(results, output_dir)
    charts = report.write_charts(output_dir)
    print()
    print(text)
    if charts:
        log("charts: " + ", ".join(p.name for p in charts))
    log(f"verdict: {results.verdict.upper()}")
    return 0 if results.verdict == "pass" else 1


def main(argv: list[str]) -> int:
    output_dir = Path(os.environ.get("SOAK_OUTPUT_DIR", "/results"))
    profile_name = os.environ.get("SOAK_PROFILE", "pr")
    analyse_only = False
    for arg in argv:
        if arg == "--analyse-only":
            analyse_only = True
        elif arg in PROFILES:
            profile_name = arg
        else:
            print(
                f"unknown argument {arg!r}; profiles: {', '.join(PROFILES)}",
                file=sys.stderr,
            )
            return 2

    if analyse_only:
        return analyse_and_report(profile_name, output_dir)
    return run(PROFILES[profile_name], output_dir)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
