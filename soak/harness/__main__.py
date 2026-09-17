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
import csv
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import analyze, report
from .analyze import FaultMeta
from .cli import run_sigul
from .faults import build_registry
from .faults.network import configure_proxies
from .profiles import PROFILES, Profile
from .sampler import Sampler
from .scheduler import Scheduler, Timeline
from .target import DockerTarget

HERE = Path(__file__).resolve().parent


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


#: Total time allowed for the stack to serve its first request. One
#: bound for the whole phase, so a hanging stack fails here with a
#: report rather than being cancelled by the CI job's timeout.
STARTUP_BUDGET_SECONDS = 300.0


def wait_for_service(password: str) -> None:
    """Block until one real request succeeds, or give up."""
    deadline = time.monotonic() + STARTUP_BUDGET_SECONDS
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        remaining = deadline - time.monotonic()
        outcome = run_sigul(
            ["list-users"], [password], timeout=min(60.0, max(1.0, remaining))
        )
        if outcome.ok:
            log(f"stack is serving (attempt {attempt})")
            return
        if not outcome.timed_out:
            time.sleep(5)
    raise SystemExit(
        f"stack served no request within {STARTUP_BUDGET_SECONDS:.0f}s; aborting soak"
    )


def wait_for_load_start(
    marker: Path, locust: subprocess.Popen, timeout: float = 600.0
) -> float:
    """Wait for Locust's shape clock to start and return that instant.

    Locust's init creates the signing key on a fresh stack, which can
    take a while; the shape clock starts only after that. The ramp
    timeline is anchored to the instant Locust records, so each step's
    window is the concurrency Locust was actually running. Locust
    exiting first is a failure to start.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if locust.poll() is not None:
            raise SystemExit(
                f"locust exited during startup with status {locust.returncode}"
            )
        if marker.is_file():
            text = marker.read_text().strip()
            if text:
                log("load generator started")
                return float(text)
        time.sleep(0.2)
    raise SystemExit(f"locust did not start within {timeout:.0f}s")


def make_probe(requests_csv: Path, password: str):  # noqa: ANN201
    """One real request, logged in the same shape as Locust's rows."""

    def probe() -> None:
        started = time.perf_counter()
        outcome = run_sigul(["list-users"], [password], timeout=60)
        ok, detail = outcome.ok, ("" if outcome.ok else outcome.detail)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        new = not requests_csv.is_file() or requests_csv.stat().st_size == 0
        with requests_csv.open("a", newline="") as handle:
            writer = csv.writer(handle)
            if new:
                writer.writerow(["epoch", "task", "latency_ms", "ok", "detail"])
            writer.writerow(
                [
                    f"{time.time():.3f}",
                    "probe_list_users",
                    f"{elapsed_ms:.1f}",
                    int(ok),
                    detail,
                ]
            )

    return probe


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
    # The scheduler stops Locust when the run is over; this is only a
    # safety ceiling for a harness that dies without doing so. Fault
    # setup and cleanup are synchronous and uncounted in the plan, so
    # the ceiling is well clear of any plausible overrun.
    env["SOAK_TOTAL_SECONDS"] = str(duration * 2 + 3600)

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


def _restore_stack(
    scheduler: Scheduler, target: DockerTarget, units: tuple[str, ...]
) -> None:
    """Best-effort restoration on an interrupted run.

    A proxy or daemon we cannot reach is not something the interrupt
    path can fix, so every step here is allowed to fail quietly.
    """
    scheduler.abort()
    with contextlib.suppress(Exception):
        from .faults.network import client as toxiproxy

        toxiproxy().reset()
    for unit in (
        *units,
        os.environ.get("SOAK_SERVER_PEER_CONTAINER", "sigul-toxiproxy"),
    ):
        with contextlib.suppress(Exception):
            target.thaw(unit)


def _stop_load(locust: subprocess.Popen | None) -> str | None:
    """Stop Locust and reap it. Returns a failure description, if any.

    Locust ending before we asked it to means the advertised load was
    absent for part of the run; whatever it recorded up to then cannot
    support a verdict.
    """
    log("stopping load")
    if locust is None:
        return "load generator never started"
    if locust.poll() is not None:
        return f"load generator exited early with status {locust.returncode}"
    locust.send_signal(signal.SIGINT)
    try:
        locust.wait(timeout=60)
    except subprocess.TimeoutExpired:
        locust.kill()
        # Reap, so requests.csv has no writer left when the analyser
        # opens it.
        locust.wait()
    return None


def run(profile: Profile, output_dir: Path) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    for stale in ("requests.csv", "samples.csv", "timeline.csv", "locust-started"):
        (output_dir / stale).unlink(missing_ok=True)

    password = Path("/test-artifacts/admin-password").read_text().strip()
    bridge = os.environ.get("SOAK_BRIDGE_CONTAINER", "sigul-bridge")
    server = os.environ.get("SOAK_SERVER_CONTAINER", "sigul-server")

    log(f"profile {profile.name}: {profile.description}")
    log(
        f"planned duration {profile.total_seconds() / 60:.1f} min, "
        f"{len(profile.preflight_faults) + len(profile.warm_faults) + len(profile.faults)} faults"
    )

    configure_proxies(bridge)
    wait_for_service(password)

    target = DockerTarget()
    registry = build_registry(target)
    timeline = Timeline(output_dir / "timeline.csv")
    scheduler = Scheduler(profile, registry, timeline, log=log)
    sampler = Sampler(target, (bridge, server), output_dir / "samples.csv")

    locust: subprocess.Popen | None = None
    interrupted = False

    def on_signal(*_args) -> None:
        # Only flag and unwind; every teardown step lives in the finally
        # below so there is exactly one shutdown path. Later signals
        # while that runs are ignored rather than re-entering it.
        nonlocal interrupted
        if interrupted:
            return
        interrupted = True
        log("interrupted; cleaning up")
        raise SystemExit(130)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    sampler.start()
    started = time.time()
    try:
        # Preflight faults need an idle stack - no request in flight -
        # so they run before the load generator, with probe requests
        # standing in for it during their recovery windows.
        scheduler.run_preflight(make_probe(output_dir / "requests.csv", password))
        locust = start_locust(profile, output_dir, profile.total_seconds())
        anchor = wait_for_load_start(output_dir / "locust-started", locust)
        scheduler.run_ramp(anchor)
        scheduler.run_warm_faults()
        scheduler.run_baseline()
        scheduler.run_faults()
        scheduler.run_cooldown()
    finally:
        if interrupted:
            _restore_stack(scheduler, target, (bridge, server))
        failure = _stop_load(locust)
        # Stop the sampler before the timeline is closed so a stuck
        # sampler surfaces here, as a run failure, rather than as a
        # concurrent reader/writer during analysis.
        try:
            sampler.stop()
        except RuntimeError as exc:
            log(str(exc))
            failure = failure or str(exc)
        timeline.record("phase", "run", started, time.time())
        timeline.close()
        if sampler.errors:
            log(f"sampler: {sampler.errors} readings skipped (units restarting/frozen)")

    return analyse_and_report(
        profile.name, output_dir, registry, harness_failure=failure
    )


def analyse_and_report(
    profile_name: str,
    output_dir: Path,
    registry: dict | None = None,
    harness_failure: str | None = None,
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
        output_dir,
        profile_name,
        fault_meta,
        expectations,
        baseline,
        units,
        harness_failure,
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
