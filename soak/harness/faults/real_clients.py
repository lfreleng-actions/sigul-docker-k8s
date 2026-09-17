# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Real `sigul` clients, abused the way real CI jobs are.

These run the genuine CLI on a large signing request and then do to it
what happens to real jobs: the runner is killed mid-request, the VM is
suspended, the process is frozen. They need no protocol knowledge and
reproduce authenticated, mid-request failure exactly, which no
synthetic client could.
"""

from __future__ import annotations

import contextlib
import os
import re
import signal
import subprocess
import threading
import time
from pathlib import Path

from .base import Fault
from .clients import BRIDGE_CLIENT_PORT, CONFIG

_FAULT_PAYLOAD_BYTES = 384 << 20


class _RealClientFault(Fault):
    """Run the genuine sigul CLI on a slow request, then abuse the process."""

    #: Signal to deliver once the request is under way.
    interrupt: int = signal.SIGKILL
    #: Whether to send SIGCONT at stop(), for freeze-style faults.
    resume_on_stop: bool = False
    #: Bytes the client must have sent on its bridge connection before
    #: it is interrupted. Liveness alone is not evidence of an upload in
    #: progress - under load the client may still be queued in the
    #: backlog or handshaking, and a client frozen there exercises the
    #: unauthenticated defects instead of the authenticated mid-request
    #: one this fault is for. A few MiB on the wire is unambiguous.
    upload_evidence_bytes: int = 4 << 20
    #: How long to wait for that evidence before declaring the fault
    #: uninjected. Under contention the client may queue for a while.
    upload_wait: float = 30.0

    def __init__(self) -> None:
        self._procs: list[subprocess.Popen] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._failure: BaseException | None = None
        self._payload = Path("/tmp/soak-work/blob-fault.bin")
        self._passphrase = os.environ.get("SOAK_KEY_PASSPHRASE", "soak-key-passphrase")
        self._key = os.environ.get("SOAK_KEY_NAME", "soak-test-key")

    def start(self) -> None:
        if not self._payload.is_file():
            # Large enough that the upload is still in progress when
            # `settle` elapses, even over loopback.
            self._payload.parent.mkdir(parents=True, exist_ok=True)
            self._payload.write_bytes(os.urandom(_FAULT_PAYLOAD_BYTES))
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name=self.name, daemon=True)
        self._thread.start()

    def _launch(self) -> subprocess.Popen:
        out = f"/tmp/soak-work/fault-{os.getpid()}-{time.time_ns()}.sig"
        proc = subprocess.Popen(  # noqa: S603 - fixed argv
            [
                "sigul",
                "--batch",
                "-c",
                CONFIG,
                "sign-data",
                "-o",
                out,
                self._key,
                str(self._payload),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            # Its own process group: the sigul client forks a forwarding
            # child that owns the bridge socket, and a real CI kill takes
            # the whole tree. Signals go to the group.
            start_new_session=True,
        )
        assert proc.stdin is not None
        proc.stdin.write(self._passphrase.encode() + b"\0")
        proc.stdin.flush()
        return proc

    def _loop(self) -> None:
        try:
            self._run_once()
        except Exception as exc:  # noqa: BLE001 - recorded, raised by stop()
            self._failure = exc

    def _run_once(self) -> None:
        while not self._stop.is_set():
            proc = self._launch()
            self._procs.append(proc)
            self._wait_for_upload(proc)
            if proc.poll() is None:
                # Exited between poll() and here: already the outcome we
                # wanted, nothing more to do.
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, self.interrupt)
            # One interrupted request per window, held until stop().
            self._stop.wait(3600)

    def _wait_for_upload(self, proc: subprocess.Popen) -> None:
        """Block until this client has demonstrably started its upload."""
        deadline = time.monotonic() + self.upload_wait
        while time.monotonic() < deadline and not self._stop.is_set():
            if proc.poll() is not None:
                raise RuntimeError(
                    f"client exited with status {proc.returncode} before it could "
                    "be interrupted; the fault was not injected"
                )
            if _bytes_sent_to_bridge(proc.pid) >= self.upload_evidence_bytes:
                return
            time.sleep(0.2)
        if self._stop.is_set():
            return
        raise RuntimeError(
            f"client {proc.pid} sent under {self.upload_evidence_bytes} bytes in "
            f"{self.upload_wait:.0f}s; no upload to interrupt, fault not injected"
        )

    def stop(self) -> None:
        """End the fault. Returns as soon as the fault is lifted.

        For a resumed client the fault ends at SIGCONT; whatever the
        resumed request then costs the service is part of the measured
        recovery, so reaping is left to a background thread rather than
        done here where it would hide that time from the clock.
        """
        self._stop.set()
        procs, self._procs = self._procs, []
        for proc in procs:
            with contextlib.suppress(ProcessLookupError):
                if self.resume_on_stop:
                    os.killpg(proc.pid, signal.SIGCONT)
                else:
                    os.killpg(proc.pid, signal.SIGKILL)
        threading.Thread(target=_reap, args=(procs,), daemon=True).start()
        if self._thread is not None:
            self._thread.join(timeout=15)
            self._thread = None
        # Read the worker's verdict only once it has stopped, so a
        # failure it notices while waking up is attributed to this
        # window and not the next.
        failure, self._failure = self._failure, None
        if failure is not None:
            raise RuntimeError(f"{self.name}: {failure}")


def _bytes_sent_to_bridge(pid: int) -> int:
    """Bytes this client has sent on its connection to the bridge port.

    The socket belongs to the client's forwarding child, not the
    process we started, so the search covers the client's whole process
    group. Reads `ss -tnpi`, whose per-socket detail line carries
    bytes_sent.
    """
    listing = subprocess.run(  # noqa: S603
        ["ps", "-eo", "pid=,pgid="], capture_output=True, text=True, check=False
    ).stdout
    group = [
        fields[0]
        for fields in (line.split() for line in listing.splitlines())
        if len(fields) == 2 and fields[1] == str(pid)
    ]
    if not group:
        return 0
    out = subprocess.run(  # noqa: S603
        ["ss", "-Htnpi", "state", "established", f"( dport = :{BRIDGE_CLIENT_PORT} )"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    lines = out.splitlines()
    for index, line in enumerate(lines):
        if any(f"pid={member}," in line for member in group) and index + 1 < len(lines):
            match = re.search(r"bytes_sent:(\d+)", lines[index + 1])
            if match:
                return int(match.group(1))
    return 0


def _reap(procs: list[subprocess.Popen]) -> None:
    for proc in procs:
        try:
            proc.wait(timeout=300)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()


class KillMidSign(_RealClientFault):
    name = "client_kill_mid_sign"
    description = "Start a real 384 MiB sign-data, SIGKILL the client mid-upload."
    implication = (
        "A CI runner killed mid-request leaves the bridge or server child "
        "holding a half-transferred payload and the service stalls."
    )
    interrupt = signal.SIGKILL


class HandshakeThenHang(_RealClientFault):
    name = "client_handshake_then_hang"
    description = (
        "Start a real 384 MiB sign-data, SIGSTOP the client mid-upload, "
        "then kill it when the window ends."
    )
    implication = (
        "An authenticated client that stops responding holds the bridge's "
        "only slot for as long as it likes; the service is down for everyone."
    )
    interrupt = signal.SIGSTOP
    resume_on_stop = False


class StopMidSign(_RealClientFault):
    name = "client_stop_mid_sign"
    description = (
        "Start a real 384 MiB sign-data, SIGSTOP the client mid-upload, "
        "SIGCONT it when the window ends."
    )
    implication = (
        "A suspended-and-resumed client (laptop sleep, VM migration) does "
        "not complete cleanly, or the service does not survive the pause."
    )
    interrupt = signal.SIGSTOP
    resume_on_stop = True


REAL_CLIENT_FAULTS: tuple[type[Fault], ...] = (
    KillMidSign,
    HandshakeThenHang,
    StopMidSign,
)
