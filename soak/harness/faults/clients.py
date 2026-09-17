# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Clients that behave the way real ones sometimes do.

Two families:

Raw-socket clients need no certificate. They exercise everything the
bridge does *before* it knows who it is talking to - accept, handshake,
and the decision to give up on a peer that is not cooperating. That is
where a hostile or merely broken network peer lands, and it is where
one connection can hold the bridge's single slot hostage.

Real-client faults run the genuine `sigul` CLI and then do to it what
happens to real CI jobs: the runner is killed mid-request, the VM is
suspended, the process is frozen by a debugger. These need no
protocol knowledge and reproduce authenticated, mid-request failure
exactly, which no synthetic client could.
"""

from __future__ import annotations

import contextlib
import os
import random
import signal
import socket
import struct
import subprocess
import threading
import time
from pathlib import Path

from .base import Fault

BRIDGE_HOST = os.environ.get("SOAK_BRIDGE_HOST", "sigul-bridge.example.org")
BRIDGE_CLIENT_PORT = int(os.environ.get("SOAK_BRIDGE_CLIENT_PORT", "44334"))
CONFIG = os.environ.get("SIGUL_CONFIG", "/etc/sigul/client.conf")
_FAULT_PAYLOAD_BYTES = 384 << 20

# A plausible-looking TLS 1.2 ClientHello prefix. The bridge's NSS
# handshake will consume it and wait for the rest, which is the point:
# it looks like a client that is trying, not a port scan it can
# dismiss.
_TLS_HELLO_PREFIX = bytes.fromhex(
    "160303"  # handshake record, TLS 1.2
    "0100"  # length placeholder (256)
    "010000fc"  # ClientHello, length 252
    "0303"  # client version
) + os.urandom(32)  # random


def _connect(timeout: float = 10.0) -> socket.socket:
    sock = socket.create_connection((BRIDGE_HOST, BRIDGE_CLIENT_PORT), timeout=timeout)
    sock.settimeout(None)
    return sock


class _RawClientFault(Fault):
    """Base for faults that run N misbehaving socket clients in threads.

    Each thread loops `_misbehave()` until stopped, so the fault keeps
    pressure on for its whole window rather than firing once and
    hoping the timing lines up with the bridge's accept cycle.
    """

    #: Concurrent bad clients.
    clients: int = 1

    def __init__(self) -> None:
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._failures: list[BaseException] = []

    def start(self) -> None:
        self._stop.clear()
        self._failures.clear()
        for index in range(self.clients):
            thread = threading.Thread(
                target=self._loop, name=f"{self.name}-{index}", daemon=True
            )
            thread.start()
            self._threads.append(thread)

    def stop(self) -> None:
        self._stop.set()
        for thread in self._threads:
            thread.join(timeout=15)
        self._threads.clear()
        # A worker that died of anything but a socket error was not
        # misbehaving at the bridge for the rest of the window. Say so,
        # so the window is not recorded as a clean injection.
        if self._failures:
            raise RuntimeError(f"{self.name} worker failed: {self._failures[0]!r}")

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                self._misbehave()
            except OSError:
                # Refused, reset, timed out - all legitimate outcomes
                # when the peer is defending itself. Back off briefly
                # and try again.
                self._stop.wait(1.0)
            except Exception as exc:  # noqa: BLE001 - recorded, raised by stop()
                self._failures.append(exc)
                return

    def _misbehave(self) -> None:
        raise NotImplementedError

    def _hold(self, sock: socket.socket, seconds: float) -> None:
        """Keep a socket open and silent until the fault ends or time is up."""
        deadline = time.monotonic() + seconds
        while not self._stop.is_set() and time.monotonic() < deadline:
            self._stop.wait(0.5)
        sock.close()


class ConnectAndHang(_RawClientFault):
    name = "client_connect_and_hang"
    description = (
        "TCP connect to the client port, never send a byte, hold the connection."
    )
    implication = (
        "The bridge accepts and blocks in force_handshake() with no read "
        "timeout; one silent peer stops every other client being served."
    )
    clients = 2

    def _misbehave(self) -> None:
        sock = _connect()
        self._hold(sock, 3600)


class SlowLoris(_RawClientFault):
    name = "client_slow_loris"
    description = "Feed the TLS handshake one byte per second, forever."
    implication = (
        "No per-read deadline on the handshake: a trickle keeps the bridge "
        "committed to a client that will never finish."
    )
    clients = 1

    def _misbehave(self) -> None:
        sock = _connect()
        payload = _TLS_HELLO_PREFIX + os.urandom(220)
        for byte in payload:
            if self._stop.is_set():
                break
            sock.sendall(bytes([byte]))
            self._stop.wait(1.0)
        sock.close()


class AbruptReset(_RawClientFault):
    name = "client_abrupt_reset"
    description = "Send half a ClientHello, then RST the connection (SO_LINGER 0)."
    implication = (
        "Handshake error path leaks state - sockets, forked children or "
        "buffered data - on a connection reset instead of a clean close."
    )
    clients = 2

    def _misbehave(self) -> None:
        sock = _connect()
        sock.sendall(_TLS_HELLO_PREFIX)
        time.sleep(random.uniform(0.05, 0.5))  # noqa: S311 - jitter only
        # Linger 0 turns close() into an immediate RST.
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        sock.close()
        self._stop.wait(0.5)


class HalfCloseHang(_RawClientFault):
    name = "client_half_close_hang"
    description = (
        "Send a ClientHello prefix, shutdown(SHUT_WR), then wait for a reply forever."
    )
    implication = (
        "The bridge does not treat a half-closed client as gone and keeps "
        "its slot allocated to a peer that can no longer send."
    )
    clients = 1

    def _misbehave(self) -> None:
        sock = _connect()
        sock.sendall(_TLS_HELLO_PREFIX)
        sock.shutdown(socket.SHUT_WR)
        self._hold(sock, 3600)


class GarbageHandshake(_RawClientFault):
    name = "client_garbage_handshake"
    description = "Connect and send random bytes where a TLS ClientHello should be."
    implication = (
        "Rejected clients leak a socket or process each; a scanner can "
        "exhaust the bridge without ever authenticating."
    )
    clients = 3

    def _misbehave(self) -> None:
        sock = _connect()
        sock.sendall(os.urandom(random.randint(1, 512)))  # noqa: S311
        # The bridge may reset us, answer, or - if the bytes happened to
        # look like a partial record - wait for more. Any of those is a
        # valid outcome for garbage; what matters is that this socket
        # is closed and retried rather than left open into the next
        # window.
        sock.settimeout(3.0)
        with contextlib.suppress(OSError):
            sock.recv(1024)
        sock.close()
        self._stop.wait(0.2)


class BacklogFlood(_RawClientFault):
    name = "client_backlog_flood"
    description = "Open 20 simultaneous connections to the client port and hold them."
    implication = (
        "The listen backlog is 5 and the bridge accepts clients only "
        "between server pairings, so honest clients beyond the backlog "
        "are SYN-dropped and the sigul CLI does not retry."
    )
    clients = 20

    def _misbehave(self) -> None:
        sock = _connect(timeout=5.0)
        self._hold(sock, 3600)


class _RealClientFault(Fault):
    """Run the genuine sigul CLI on a slow request, then abuse the process."""

    #: Signal to deliver once the request is under way.
    interrupt: int = signal.SIGKILL
    #: Whether to send SIGCONT at stop(), for freeze-style faults.
    resume_on_stop: bool = False
    #: Seconds to let the request run before interrupting it. The
    #: payload is sized so that this lands during the upload: a client
    #: frozen while the bridge is still reading from it is the case
    #: that holds the slot, whereas one frozen after the upload merely
    #: delays a small reply that fits in the socket buffer.
    settle: float = 1.5

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
            self._stop.wait(self.settle)
            if proc.poll() is not None:
                raise RuntimeError(
                    f"client exited with status {proc.returncode} before it could "
                    "be interrupted; the fault was not injected"
                )
            if proc.poll() is None:
                # Exited between poll() and here: already the outcome we
                # wanted, nothing more to do.
                with contextlib.suppress(ProcessLookupError):
                    proc.send_signal(self.interrupt)
            # One interrupted request per window, held until stop().
            self._stop.wait(3600)

    def stop(self) -> None:
        """End the fault. Returns as soon as the fault is lifted.

        For a resumed client the fault ends at SIGCONT; whatever the
        resumed request then costs the service is part of the measured
        recovery, so reaping is left to a background thread rather than
        done here where it would hide that time from the clock.
        """
        self._stop.set()
        failure, self._failure = self._failure, None
        procs, self._procs = self._procs, []
        for proc in procs:
            with contextlib.suppress(ProcessLookupError):
                if self.resume_on_stop:
                    proc.send_signal(signal.SIGCONT)
                else:
                    proc.kill()
        threading.Thread(target=_reap, args=(procs,), daemon=True).start()
        if self._thread is not None:
            self._thread.join(timeout=15)
            self._thread = None
        if failure is not None:
            raise RuntimeError(f"{self.name}: {failure}")


def _reap(procs: list[subprocess.Popen]) -> None:
    for proc in procs:
        try:
            proc.wait(timeout=300)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
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


CLIENT_FAULTS: tuple[type[Fault], ...] = (
    ConnectAndHang,
    SlowLoris,
    AbruptReset,
    HalfCloseHang,
    GarbageHandshake,
    BacklogFlood,
    KillMidSign,
    HandshakeThenHang,
    StopMidSign,
)
