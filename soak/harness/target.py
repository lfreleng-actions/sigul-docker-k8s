# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Where the stack under test lives, and how to disturb it.

Everything the harness does to the stack goes through this interface:
read a container's memory, list its sockets, freeze it, restart it.
Compose is the implementation used in CI because it starts in about a
minute; the same harness can drive a Kubernetes deployment by adding a
second implementation here, without touching the faults, the load
generator or the analysis.
"""

from __future__ import annotations

import threading
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from typing import Any


@dataclass(frozen=True)
class ProcessStats:
    """A point-in-time reading for one container."""

    rss_bytes: int
    cpu_percent: float
    pids: int


@dataclass(frozen=True)
class SocketCounts:
    """TCP states for one container, as `ss` reports them.

    `close_wait` is the one that matters most: it means the peer sent a
    FIN we never read, which is how the bridge used to leak a socket
    per failed handshake and how it kept a dying server's teardown
    waiting forever.
    """

    established: int
    close_wait: int
    fin_wait_2: int
    time_wait: int
    syn_recv: int
    listen: int


def _dig(mapping: dict, *keys: str) -> int:
    """Read a nested integer from the Docker stats document, 0 if absent.

    The stats payload omits whole sections while a container is
    starting or paused; a missing figure is a legitimate zero reading
    for one tick, not an error.
    """
    node: object = mapping
    for key in keys:
        if not isinstance(node, dict) or key not in node:
            return 0
        node = node[key]
    return int(node) if isinstance(node, (int, float)) else 0


class Target(ABC):
    """A running Sigul stack that the harness can measure and disturb."""

    @abstractmethod
    def run_in(
        self, unit: str, argv: list[str], timeout: float = 30.0, check: bool = True
    ) -> str:
        """Run a command inside a unit and return its output.

        Raises TimeoutError if it overruns and, when `check` is set,
        RuntimeError on a non-zero exit. A failed reading must not pass
        as a zero one, and a failed fault injection must not pass as a
        clean window.
        """

    @abstractmethod
    def stats(self, unit: str) -> ProcessStats:
        """Read memory, CPU and process count for a unit."""

    @abstractmethod
    def restart(self, unit: str) -> None:
        """Stop and start a unit, as a crash-loop or rollout would."""

    @abstractmethod
    def freeze(self, unit: str) -> None:
        """Suspend every process in a unit without closing its sockets.

        This is the shape of the production wedge: the peer is still
        there, its connections are still open, and it answers nothing.
        """

    @abstractmethod
    def thaw(self, unit: str) -> None:
        """Resume a frozen unit."""

    @abstractmethod
    def logs_since(self, unit: str, seconds: float) -> str:
        """Recent log output, for error-rate accounting."""

    @abstractmethod
    def started_at(self, unit: str) -> float:
        """Epoch seconds at which the unit's current lifetime began.

        A change in this value between two samples is a restart. The
        analyser uses it to make sure leak comparisons never straddle
        one, and to notice a restart nobody asked for.
        """

    def sockets(self, unit: str) -> SocketCounts:
        """Count TCP states inside a unit.

        Implemented here rather than per-backend because it only needs
        `run_in`: `ss` runs in the container's own network namespace, so
        the same command works under Compose and Kubernetes alike.
        """
        out = self.run_in(unit, ["ss", "-Htan"], timeout=15.0)
        counts = {
            "ESTAB": 0,
            "CLOSE-WAIT": 0,
            "FIN-WAIT-2": 0,
            "TIME-WAIT": 0,
            "SYN-RECV": 0,
            "LISTEN": 0,
        }
        for line in out.splitlines():
            state = line.split()[0] if line.split() else ""
            if state in counts:
                counts[state] += 1
        return SocketCounts(
            established=counts["ESTAB"],
            close_wait=counts["CLOSE-WAIT"],
            fin_wait_2=counts["FIN-WAIT-2"],
            time_wait=counts["TIME-WAIT"],
            syn_recv=counts["SYN-RECV"],
            listen=counts["LISTEN"],
        )

    def open_fds(self, unit: str) -> int:
        """Count open file descriptors across a unit's processes.

        A steadily climbing count is the clearest leak signal there is,
        and unlike RSS it does not need a trend fit to interpret.
        """
        out = self.run_in(
            unit,
            [
                "sh",
                "-c",
                "find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 2>/dev/null | wc -l",
            ],
            timeout=15.0,
        )
        try:
            return int(out.strip() or 0)
        except ValueError:
            return 0

    def zombies(self, unit: str) -> int:
        """Count unreaped children.

        `outer_close()` reaps the forwarding child; if that ever stops
        working the corpses pile up here before anything else notices.
        """
        out = self.run_in(
            unit,
            ["sh", "-c", "ps -eo stat= 2>/dev/null | grep -c '^Z' || true"],
            timeout=15.0,
        )
        try:
            return int(out.strip() or 0)
        except ValueError:
            return 0


class DockerTarget(Target):
    """A stack running under Docker Compose on the local daemon."""

    #: Ceiling on any single Docker API call other than exec (see
    #: run_in). Long enough for a `restart` - stop grace of 10s plus
    #: start - short enough that an unresponsive daemon costs the
    #: sampler one reading rather than the rest of the run.
    API_TIMEOUT_SECONDS = 30

    def __init__(self) -> None:
        import docker

        self._client = docker.from_env(timeout=self.API_TIMEOUT_SECONDS)
        self._containers: dict[str, Any] = {}

    def _container(self, unit: str) -> Any:  # docker SDK Container
        if unit not in self._containers:
            self._containers[unit] = self._client.containers.get(unit)
        container = self._containers[unit]
        container.reload()
        return container

    def run_in(
        self, unit: str, argv: list[str], timeout: float = 30.0, check: bool = True
    ) -> str:
        # Two bounds, because neither alone is enough. The Docker SDK
        # reads exec output straight from the socket, so the HTTP
        # timeout does not apply to a command that produces nothing;
        # and a frozen container may not run `timeout` at all. So: the
        # command is wrapped in coreutils `timeout` inside the
        # container, and the call itself runs on a daemon thread that
        # is abandoned if it overruns. An abandoned thread costs a few
        # KB until the exec ends; a blocked sampler would cost the run.
        container = self._container(unit)
        result: list[Any] = []
        failure: list[BaseException] = []

        def call() -> None:
            try:
                result.append(
                    container.exec_run(
                        ["timeout", str(int(timeout)), *argv], demux=False
                    )
                )
            except Exception as exc:  # noqa: BLE001 - re-raised on the caller's thread
                failure.append(exc)

        worker = threading.Thread(target=call, daemon=True)
        worker.start()
        worker.join(timeout + 5)
        if failure:
            # A refused exec (container not running, say) is an answer,
            # not a hang; report it straight away.
            raise RuntimeError(f"exec in {unit} failed: {failure[0]}") from failure[0]
        if worker.is_alive() or not result:
            raise TimeoutError(f"exec in {unit} exceeded {timeout:.0f}s")
        code = result[0].exit_code
        output = result[0].output
        text = (
            output.decode("utf-8", errors="replace")
            if isinstance(output, bytes)
            else str(output or "")
        )
        if code == 124:
            raise TimeoutError(f"{argv[0]} in {unit} exceeded {timeout:.0f}s")
        if check and code != 0:
            raise RuntimeError(
                f"{' '.join(argv)} in {unit} exited {code}: {text.strip()[:200]}"
            )
        return text

    def stats(self, unit: str) -> ProcessStats:
        raw = self._container(unit).stats(stream=False)  # type: ignore[attr-defined]
        # Docker's usage figure includes page cache, which drifts with
        # file I/O and would masquerade as a leak. Subtract it.
        usage = _dig(raw, "memory_stats", "usage")
        cache = _dig(raw, "memory_stats", "stats", "file")
        rss = max(usage - cache, 0)

        cpu_delta = _dig(raw, "cpu_stats", "cpu_usage", "total_usage") - _dig(
            raw, "precpu_stats", "cpu_usage", "total_usage"
        )
        sys_delta = _dig(raw, "cpu_stats", "system_cpu_usage") - _dig(
            raw, "precpu_stats", "system_cpu_usage"
        )
        online = _dig(raw, "cpu_stats", "online_cpus") or 1
        cpu_percent = (cpu_delta / sys_delta) * online * 100.0 if sys_delta > 0 else 0.0

        return ProcessStats(
            rss_bytes=rss,
            cpu_percent=round(cpu_percent, 2),
            pids=_dig(raw, "pids_stats", "current"),
        )

    def restart(self, unit: str) -> None:
        self._container(unit).restart(timeout=10)  # type: ignore[attr-defined]

    def freeze(self, unit: str) -> None:
        self._container(unit).pause()  # type: ignore[attr-defined]

    def thaw(self, unit: str) -> None:
        container = self._container(unit)
        if container.status == "paused":  # type: ignore[attr-defined]
            container.unpause()  # type: ignore[attr-defined]

    def logs_since(self, unit: str, seconds: float) -> str:
        return (
            self._container(unit)
            .logs(  # type: ignore[attr-defined]
                since=int(seconds), tail=2000
            )
            .decode("utf-8", errors="replace")
        )

    def started_at(self, unit: str) -> float:
        stamp: str = self._container(unit).attrs["State"]["StartedAt"]
        # Docker gives nanosecond precision and a Z suffix; fromisoformat
        # wants microseconds at most and an explicit offset.
        head, _, tail = stamp.partition(".")
        micros = (tail.rstrip("Z") + "000000")[:6]
        return datetime.fromisoformat(f"{head}.{micros}+00:00").timestamp()
