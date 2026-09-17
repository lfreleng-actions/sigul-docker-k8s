# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Process-level faults: the daemons themselves misbehave or vanish.

Restarts are what a crash loop, an OOM kill or a chart rollout look
like from the other side of the connection. Freezes are subtler and
more dangerous: every socket stays open, nothing is refused, and the
peer has no signal at all that anything is wrong. That is the shape
of the production wedge, and it is why the liveness probe now checks
for an established connection rather than a live process.
"""

from __future__ import annotations

import os
import time

from ..target import Target
from .base import Fault

BRIDGE = os.environ.get("SOAK_BRIDGE_CONTAINER", "sigul-bridge")
SERVER = os.environ.get("SOAK_SERVER_CONTAINER", "sigul-server")

#: How long a server child may take to abandon a teardown against a
#: peer that never closes: patch 06's five-second linger, its ten-second
#: reap fallback, and slack for a loaded runner.
TEARDOWN_BOUND_SECONDS = 25.0


class _ProcessFault(Fault):
    unit: str = ""

    def __init__(self, target: Target) -> None:
        self._target = target


class RestartBridge(_ProcessFault):
    name = "proc_restart_bridge"
    description = "Restart the bridge container while requests are in flight."
    implication = (
        "The server must notice the bridge is gone and reconnect; clients "
        "in flight fail, but the next ones must succeed without help."
    )
    unit = BRIDGE

    def start(self) -> None:
        self._target.restart(self.unit)

    def stop(self) -> None:
        # Nothing to undo: the restart is the fault, and recovery is
        # measured from here.
        pass


class RestartServer(_ProcessFault):
    name = "proc_restart_server"
    description = "Restart the server container while requests are in flight."
    implication = (
        "The bridge must discard the dead server connection rather than "
        "pair the next client with it (patches/07)."
    )
    unit = SERVER

    def start(self) -> None:
        self._target.restart(self.unit)

    def stop(self) -> None:
        pass


class FreezeBridge(_ProcessFault):
    name = "proc_freeze_bridge"
    service_possible_during = False
    description = "SIGSTOP the whole bridge container: sockets open, nothing answered."
    implication = (
        "Server teardowns that begin during the freeze wait on a close the "
        "bridge cannot send; without a bound they never complete (patches/06)."
    )
    unit = BRIDGE

    def start(self) -> None:
        self._target.freeze(self.unit)

    def stop(self) -> None:
        self._target.thaw(self.unit)


class FreezeServer(_ProcessFault):
    name = "proc_freeze_server"
    service_possible_during = False
    description = "SIGSTOP the whole server container: sockets open, nothing answered."
    implication = (
        "The bridge pairs a client with a server that will never respond; "
        "the client and the bridge's slot are held for the duration."
    )
    unit = SERVER

    def start(self) -> None:
        self._target.freeze(self.unit)

    def stop(self) -> None:
        self._target.thaw(self.unit)


class ServerTeardownAgainstSilentPeer(_ProcessFault):
    """The production deadlock, reproduced.

    server.py arms signal.alarm(3600) in every forked child at fork
    time, request or no request. When it fires, the idle child tears
    its connection down through outer_close() and waits for its TCP
    peer to close the other half. Make the peer unable to: freeze the
    process that owns the server's connection, so the kernel keeps
    ACKing but nothing is ever read or closed - the CLOSE-WAIT state
    the production bridge sat in for six hours - then fire the alarm
    early. Before patch 06 the child waited forever, the daemon's main
    loop waited on the child, and every request until the pod was
    restarted failed with "Unexpected EOF in NSPR". With it, the child
    logs "Peer did not close its half" after the linger and exits, and
    the main loop forks a replacement.

    Under Compose the server's peer is Toxiproxy, so that is what gets
    frozen. A blackhole toxic does not reproduce this: the proxy still
    closes on the server's FIN and the teardown completes normally.
    """

    name = "server_teardown_vs_silent_peer"
    service_possible_during = False
    description = (
        "Freeze the server's TCP peer, then fire the idle server child's hourly "
        "alarm so it tears down against a connection that will never close."
    )
    implication = (
        "The server child never finishes its teardown, the main loop never "
        "forks a replacement, and the service is down until restarted "
        "(patches/06)."
    )
    unit = os.environ.get("SOAK_SERVER_PEER_CONTAINER", "sigul-toxiproxy")

    def start(self) -> None:
        parent = self._target.run_in(
            SERVER, ["pgrep", "-o", "-f", r"serve[r]\.py"], timeout=15, check=False
        ).strip()
        # The request child is the parent's live python child. Where
        # the server is PID 1 its children also include every orphaned
        # gpg zombie, so filter on command and state rather than taking
        # the first entry.
        listing = self._target.run_in(
            SERVER,
            ["sh", "-c", f"ps -o pid=,stat=,comm= --ppid {parent} 2>/dev/null || true"],
            timeout=15,
        )
        child = next(
            (
                fields[0]
                for fields in (line.split() for line in listing.splitlines())
                if len(fields) >= 3
                and not fields[1].startswith("Z")
                and "python" in fields[2]
            ),
            "",
        )
        if not parent or not child:
            raise RuntimeError(f"no idle server child found (parent={parent!r})")
        self._target.freeze(self.unit)
        self._target.run_in(SERVER, ["kill", "-ALRM", child], timeout=15)

        # The fault verifies its own outcome. With the peer still frozen
        # the child can only exit by giving up on it, which is exactly
        # what patch 06 bounds. A child still there after the linger,
        # the reap timeout and some slack is the deadlock, and is
        # reported here as a harness-level failure so it cannot be
        # rescued by whatever happens once the peer thaws.
        deadline = time.monotonic() + TEARDOWN_BOUND_SECONDS
        while time.monotonic() < deadline:
            alive = self._target.run_in(
                SERVER,
                ["sh", "-c", f"kill -0 {child} 2>/dev/null && echo yes || echo no"],
                timeout=15,
            ).strip()
            if alive == "no":
                return
            time.sleep(0.5)
        raise RuntimeError(
            f"server child {child} still blocked in teardown "
            f"{TEARDOWN_BOUND_SECONDS:.0f}s after its alarm - the patch 06 deadlock"
        )

    def stop(self) -> None:
        self._target.thaw(self.unit)


PROCESS_FAULTS: tuple[type[_ProcessFault], ...] = (
    RestartBridge,
    RestartServer,
    FreezeBridge,
    FreezeServer,
    ServerTeardownAgainstSilentPeer,
)
