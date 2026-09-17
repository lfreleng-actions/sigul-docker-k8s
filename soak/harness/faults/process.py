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

from ..target import Target
from .base import Fault

BRIDGE = os.environ.get("SOAK_BRIDGE_CONTAINER", "sigul-bridge")
SERVER = os.environ.get("SOAK_SERVER_CONTAINER", "sigul-server")


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


class ServerTeardownAgainstFrozenBridge(_ProcessFault):
    """The production deadlock, reproduced.

    server.py arms signal.alarm(3600) in every forked child at fork
    time, request or no request. When it fires, the idle child tears
    its connection down through outer_close() and waits for the bridge
    to close its half. Freeze the bridge so it cannot, fire the alarm
    early, and then thaw the bridge. Before patches 06 and 07 the child
    waited forever, the daemon's main loop waited on the child, and
    every request until the pod was restarted failed with
    "Unexpected EOF in NSPR".
    """

    name = "proc_server_teardown_vs_frozen_bridge"
    service_possible_during = False
    description = (
        "Freeze the bridge, fire the idle server child's hourly alarm so it "
        "tears down against a peer that cannot answer, then thaw the bridge."
    )
    implication = (
        "The server child never finishes its teardown, the main loop never "
        "forks a replacement, and the service is down until restarted "
        "(patches/06 and 07)."
    )
    unit = BRIDGE

    def start(self) -> None:
        parent = self._target.run_in(
            SERVER, ["pgrep", "-o", "-f", r"serve[r]\.py"], timeout=15
        ).strip()
        child = self._target.run_in(SERVER, ["pgrep", "-P", parent], timeout=15).split()
        if not parent or not child:
            raise RuntimeError(f"no idle server child found (parent={parent!r})")
        self._target.freeze(self.unit)
        self._target.run_in(SERVER, ["kill", "-ALRM", child[0]], timeout=15)

    def stop(self) -> None:
        self._target.thaw(self.unit)


PROCESS_FAULTS: tuple[type[_ProcessFault], ...] = (
    RestartBridge,
    RestartServer,
    FreezeBridge,
    FreezeServer,
    ServerTeardownAgainstFrozenBridge,
)
