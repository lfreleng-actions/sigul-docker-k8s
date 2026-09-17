# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Steady load, generated with the real Sigul client.

Every task shells out to the `sigul` CLI inside the client image, so
the traffic is genuine double-TLS: NSS handshakes, the inner session,
the forked forwarding child, the lot. A reimplementation of the
protocol would be faster and would test nothing, because every defect
found so far has lived in exactly the machinery a reimplementation
would skip.

Locust drives this with gevent, so a few dozen concurrent `sigul`
processes cost one OS thread. Locust's own HTTP machinery is unused.
"""

from __future__ import annotations

import csv
import logging
import os
import subprocess
import time
from pathlib import Path

from locust import LoadTestShape, User, between, events, task

CONFIG = os.environ.get("SIGUL_CONFIG", "/etc/sigul/client.conf")
OUTPUT_DIR = Path(os.environ.get("SOAK_OUTPUT_DIR", "/results"))
WORK_DIR = Path("/tmp/soak-work")

#: Name of the signing key the soak run uses. Created once at startup.
KEY_NAME = "soak-test-key"
KEY_PASSPHRASE = "soak-key-passphrase"

_admin_password = ""
log = logging.getLogger("soak")


class RequestLog:
    """Raw per-request log.

    Locust's own CSV history is bucketed into windows, which is too
    coarse to answer "when exactly did service resume after the fault
    ended" - the headline metric of this suite. Flushed per row so an
    interrupted run still leaves the log intact up to that moment.
    """

    def __init__(self, path: Path) -> None:
        self._file = path.open("w", newline="")
        self._writer = csv.writer(self._file)
        self._writer.writerow(["epoch", "task", "latency_ms", "ok", "detail"])

    def record(self, name: str, response_time: float, exception: object) -> None:
        self._writer.writerow(
            [
                f"{time.time():.3f}",
                name,
                f"{response_time:.1f}",
                0 if exception else 1,
                str(exception)[:200] if exception else "",
            ]
        )
        self._file.flush()

    def close(self) -> None:
        self._file.close()


_request_log: RequestLog | None = None


def _read_admin_password() -> str:
    path = Path("/test-artifacts/admin-password")
    if not path.is_file():
        raise RuntimeError(
            "/test-artifacts/admin-password missing - run "
            "scripts/deploy-sigul-infrastructure.sh first"
        )
    return path.read_text().strip()


def _run_sigul(
    argv: list[str], passwords: list[str], timeout: float
) -> tuple[bool, str]:
    """Run one sigul command, feeding NUL-separated passwords on stdin.

    Returns (succeeded, detail). A timeout is reported as a distinct
    error because it is the interesting one: it means the request never
    came back, which under Sigul's serial model implies the whole
    service was blocked, not just this caller.
    """
    stdin_payload = b"".join(p.encode() + b"\0" for p in passwords)
    try:
        proc = subprocess.run(
            ["sigul", "--batch", "-c", CONFIG, *argv],
            input=stdin_payload,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False, f"timeout after {timeout:.0f}s"

    if proc.returncode == 0:
        return True, ""

    detail = (proc.stderr or proc.stdout).decode("utf-8", errors="replace")
    return False, detail.strip().splitlines()[-1][:200] if detail.strip() else (
        f"exit {proc.returncode}"
    )


@events.init.add_listener
def _on_init(environment, **_kwargs) -> None:
    """Prepare payloads and make sure a signing key exists."""
    global _admin_password, _request_log

    _admin_password = _read_admin_password()
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Fixed, incompressible payloads. Random bytes so a bandwidth toxic
    # measures the link rather than the compressor.
    for name, size in (
        ("small.txt", 4096),
        ("blob1m.bin", 1 << 20),
        ("blob64m.bin", 64 << 20),
    ):
        path = WORK_DIR / name
        if not path.is_file() or path.stat().st_size != size:
            path.write_bytes(os.urandom(size))

    _request_log = RequestLog(OUTPUT_DIR / "requests.csv")

    ok, detail = _run_sigul(["list-keys"], [_admin_password], timeout=60)
    if ok and KEY_NAME in detail:
        return

    log.warning("creating signing key %s", KEY_NAME)
    created, detail = _run_sigul(
        [
            "new-key",
            "--key-admin",
            os.environ.get("SIGUL_ADMIN_USER", "admin"),
            "--gnupg-name-real",
            "Sigul Soak Key",
            "--gnupg-name-email",
            "soak@example.invalid",
            KEY_NAME,
        ],
        [_admin_password, KEY_PASSPHRASE],
        timeout=300,
    )
    if not created and "already exists" not in detail:
        raise RuntimeError(f"could not create soak signing key: {detail}")


@events.request.add_listener
def _on_request(name, response_time, exception, **_kwargs) -> None:
    if _request_log is not None:
        _request_log.record(name, response_time, exception)


@events.test_stop.add_listener
def _on_stop(**_kwargs) -> None:
    if _request_log is not None:
        _request_log.close()


class SigulUser(User):
    """One CI job's worth of signing traffic."""

    # A small think time keeps the generator from becoming a tight loop
    # against a serial service, which would measure queueing and
    # nothing else.
    wait_time = between(0.5, 2.0)

    #: Per-request ceiling. Generous, because the point is to record
    #: how slow things got, not to give up early - but finite, because
    #: an unbounded wait would hide a total stall as a missing sample.
    timeout = float(os.environ.get("SOAK_REQUEST_TIMEOUT", "180"))

    def _measure(self, name: str, argv: list[str], passwords: list[str]) -> None:
        started = time.perf_counter()
        ok, detail = _run_sigul(argv, passwords, self.timeout)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        self.environment.events.request.fire(
            request_type="sigul",
            name=name,
            response_time=elapsed_ms,
            response_length=0,
            exception=None if ok else RuntimeError(detail),
            context={},
        )

    @task(int(os.environ.get("SOAK_W_LIST_USERS", "4")))
    def list_users(self) -> None:
        self._measure("list_users", ["list-users"], [_admin_password])

    @task(int(os.environ.get("SOAK_W_LIST_KEYS", "4")))
    def list_keys(self) -> None:
        self._measure("list_keys", ["list-keys"], [_admin_password])

    @task(int(os.environ.get("SOAK_W_SIGN_TEXT", "6")))
    def sign_text(self) -> None:
        out = WORK_DIR / f"sig-{os.getpid()}-{id(self)}.txt"
        self._measure(
            "sign_text",
            ["sign-text", "-o", str(out), KEY_NAME, str(WORK_DIR / "small.txt")],
            [KEY_PASSPHRASE],
        )
        out.unlink(missing_ok=True)

    @task(int(os.environ.get("SOAK_W_SIGN_1MB", "3")))
    def sign_data_1mb(self) -> None:
        out = WORK_DIR / f"sig-{os.getpid()}-{id(self)}.1m.sig"
        self._measure(
            "sign_data_1mb",
            ["sign-data", "-o", str(out), KEY_NAME, str(WORK_DIR / "blob1m.bin")],
            [KEY_PASSPHRASE],
        )
        out.unlink(missing_ok=True)

    @task(int(os.environ.get("SOAK_W_SIGN_64MB", "1")))
    def sign_data_64mb(self) -> None:
        out = WORK_DIR / f"sig-{os.getpid()}-{id(self)}.64m.sig"
        self._measure(
            "sign_data_64mb",
            ["sign-data", "-o", str(out), KEY_NAME, str(WORK_DIR / "blob64m.bin")],
            [KEY_PASSPHRASE],
        )
        out.unlink(missing_ok=True)


class ProfileShape(LoadTestShape):
    """Concurrency over time, as the profile dictates.

    Ramp through the profile's steps, then hold `steady_users` for the
    rest of the run. The harness passes the shape in through the
    environment so the same locustfile serves every profile.
    """

    steps = tuple(
        int(s) for s in os.environ.get("SOAK_RAMP_STEPS", "1,2,4,8").split(",")
    )
    step_seconds = float(os.environ.get("SOAK_RAMP_STEP_SECONDS", "45"))
    steady = int(os.environ.get("SOAK_STEADY_USERS", "3"))
    total = float(os.environ.get("SOAK_TOTAL_SECONDS", "1800"))

    def tick(self):  # noqa: ANN201 - locust API
        elapsed = self.get_run_time()
        if elapsed > self.total:
            return None
        index = int(elapsed // self.step_seconds)
        if index < len(self.steps):
            return (self.steps[index], 100)
        return (self.steady, 100)
