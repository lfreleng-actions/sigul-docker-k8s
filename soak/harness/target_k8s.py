# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""The Kubernetes backend: a chart release, driven through kubectl.

Kept apart from target.py so that neither backend has to be read to
understand the other, and so the Docker path carries no import of a
tool it never uses.
"""

from __future__ import annotations

import logging
import os
import subprocess
import time
from datetime import datetime

from .target import ProcessStats, Target

_log = logging.getLogger(__name__)

#: The port each daemon must be holding open before Ready means
#: anything. The bridge's client port is the one a signing request
#: arrives on; the server dials out rather than listening, so it has
#: no equivalent and is not checked.
_LISTEN_PORTS = {"bridge": 44334}


class KubernetesTarget(Target):
    """A stack deployed by the Helm chart, driven through kubectl.

    Everything happens from outside the cluster, which is what makes
    this worth having: the chart's probes, its OrderedReady StatefulSet
    and its NetworkPolicies are all in play, and none of them exist
    under Compose. Nothing is installed into the cluster to support the
    harness - no runner Deployment, no RBAC, no sidecar - so what is
    measured is the release as shipped rather than a variant of it
    arranged to be measurable.

    Units are named as the chart names them. A Deployment's pod carries
    a generated suffix, so units are resolved by label rather than
    remembered: after a restart the old name is gone, and caching it
    would turn every later reading into an error.
    """

    #: Ceiling on any single kubectl call. Generous next to the Docker
    #: backend's, because each one is a round trip to the apiserver and
    #: on a cold cluster the first exec of a run can take seconds.
    API_TIMEOUT_SECONDS = 60

    def __init__(
        self,
        namespace: str | None = None,
        context: str | None = None,
        release: str | None = None,
    ) -> None:
        self._namespace = namespace or os.environ.get(
            "SOAK_K8S_NAMESPACE", "sigul-soak"
        )
        self._context = context or os.environ.get("SOAK_K8S_CONTEXT", "")
        self._release = release or os.environ.get("SOAK_K8S_RELEASE", "sigul")
        self._pods: dict[str, str] = {}

    def _kubectl(self, argv: list[str], timeout: float, check: bool = True) -> str:
        cmd = ["kubectl"]
        if self._context:
            cmd += ["--context", self._context]
        cmd += ["-n", self._namespace, *argv]
        try:
            proc = subprocess.run(  # noqa: S603 - fixed argv
                cmd, capture_output=True, timeout=timeout, check=False
            )
        except subprocess.TimeoutExpired as exc:
            raise TimeoutError(f"kubectl {argv[0]} exceeded {timeout:.0f}s") from exc
        out = proc.stdout.decode("utf-8", errors="replace")
        if check and proc.returncode != 0:
            err = proc.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(
                f"kubectl {argv[0]} exited {proc.returncode}: "
                f"{(err or out).strip()[:200]}"
            )
        return out

    def _component(self, unit: str) -> str:
        """The chart labels and names containers after the component."""
        return unit.rsplit("-", 1)[-1]

    def _selector(self, unit: str) -> str:
        return (
            f"app.kubernetes.io/instance={self._release},"
            f"app.kubernetes.io/component={self._component(unit)}"
        )

    def _pod(self, unit: str, refresh: bool = False) -> str:
        if refresh or unit not in self._pods:
            out = self._kubectl(
                [
                    "get",
                    "pod",
                    "-l",
                    self._selector(unit),
                    "-o",
                    "jsonpath={.items[0].metadata.name}",
                ],
                timeout=self.API_TIMEOUT_SECONDS,
            ).strip()
            if not out:
                raise RuntimeError(f"no pod for {unit} in {self._namespace}")
            self._pods[unit] = out
        return self._pods[unit]

    def run_in(
        self, unit: str, argv: list[str], timeout: float = 30.0, check: bool = True
    ) -> str:
        # Two bounds again, for the same reason as the Docker backend:
        # `timeout` inside the container bounds the command, and the
        # subprocess timeout bounds the round trip. A frozen pod answers
        # neither.
        last: Exception | None = None
        for attempt in (0, 1):
            pod = self._pod(unit, refresh=attempt == 1)
            try:
                return self._kubectl(
                    [
                        "exec",
                        pod,
                        "-c",
                        self._component(unit),
                        "--",
                        "timeout",
                        str(int(timeout)),
                        *argv,
                    ],
                    timeout=timeout + 15,
                    check=check,
                )
            except RuntimeError as exc:
                # A pod replaced since it was resolved gives "not
                # found". Re-resolve once before calling it a failure.
                last = exc
        raise RuntimeError(f"exec in {unit} failed: {last}")

    def stats(self, unit: str) -> ProcessStats:
        # Read the cgroup rather than metrics-server, which a kind
        # cluster does not have and which samples on its own schedule
        # anyway. memory.current counts page cache, so take the anon
        # figure for parity with the Docker backend's usage-minus-cache.
        out = self.run_in(
            unit,
            [
                "sh",
                "-c",
                "awk '/^anon /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null "
                "|| echo 0; cat /sys/fs/cgroup/pids.current 2>/dev/null || echo 0",
            ],
            timeout=20.0,
            check=False,
        )
        fields = [line.strip() for line in out.splitlines() if line.strip()]
        rss = int(fields[0]) if fields and fields[0].isdigit() else 0
        pids = int(fields[1]) if len(fields) > 1 and fields[1].isdigit() else 0
        # CPU is deliberately not reported: deriving a percentage needs
        # two cgroup reads a known interval apart, nothing judges it,
        # and a wrong number would be worse than an absent one.
        return ProcessStats(rss_bytes=rss, cpu_percent=0.0, pids=pids)

    def restart(self, unit: str) -> None:
        """Delete the pod and wait for a replacement to be serving.

        This is how a pod dies in production - evicted, OOM-killed,
        rescheduled - and it exercises what Compose cannot: the
        controller replacing it, the probes deciding when the
        replacement is ready, and OrderedReady declining to act on a
        pod that is Running but not Ready.

        Waiting is done against the container's start time rather than
        the pod's name or its Ready condition alone. Neither is enough
        on its own: a Deployment's replacement takes a new name while a
        StatefulSet's keeps the old one, and for a few seconds after the
        delete the *outgoing* pod is still present and still Ready, so
        a naive wait returns immediately having observed the pod it was
        supposed to be replacing.
        """
        was_started = self.started_at(unit)
        pod = self._pod(unit, refresh=True)
        self._kubectl(["delete", "pod", pod, "--now"], timeout=self.API_TIMEOUT_SECONDS)
        self._pods.pop(unit, None)

        deadline = time.monotonic() + self.API_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            try:
                if self.ready(unit) and self.started_at(unit) > was_started:
                    # Ready is the chart's claim that the replacement can
                    # serve. Check it against the only thing that makes
                    # it true - the daemon holding its port open - at the
                    # one moment the two can disagree. A probe that
                    # passes early sends the next request into a refused
                    # connection, and nothing else in the run would
                    # attribute that to the probe.
                    port = _LISTEN_PORTS.get(self._component(unit))
                    if port and not self.listening(unit, port):
                        _log.warning(
                            "%s reported Ready while nothing was listening on "
                            "%d: the readiness probe passes before the daemon "
                            "can serve",
                            unit,
                            port,
                        )
                    return
            except RuntimeError as exc:
                # The controller has not created the replacement yet, so
                # there is no pod to resolve. Expected for the first
                # second or two; anything else surfaces when the
                # deadline below runs out.
                _log.debug("waiting for %s to be replaced: %s", unit, exc)
            self._pods.pop(unit, None)
            time.sleep(1.0)
        # Not raising: a replacement that never becomes Ready is a
        # finding, not a harness error. The fault's recovery window and
        # the readiness invariants are what should report it, and they
        # cannot if this aborts the run first.
        _log.warning(
            "%s did not become Ready within %ds of being deleted",
            unit,
            self.API_TIMEOUT_SECONDS,
        )

    def freeze(self, unit: str) -> None:
        """Not available here, and deliberately not faked.

        Docker freezes a container through the freezer cgroup, and
        nothing outside the cluster can do the same to a pod. Both
        routes from inside are dead ends, and it is worth recording why
        so this is not attempted again:

        - SIGSTOP to the daemon does nothing. The daemon is PID 1 in
          its namespace - deliberately, since the orphan reaper in
          patch 08 depends on it - and the kernel discards signals with
          default actions sent to namespace init from inside that
          namespace. Measured: a non-PID-1 process goes S to T, PID 1
          stays Ss.
        - Writing /sys/fs/cgroup/cgroup.freeze freezes every process in
          the container, the exec'd shell included, and nothing outside
          that cgroup can write it back. The unit would stay frozen
          with no way in.

        Raising is the point. A freeze that silently did nothing would
        report an injected fault, produce a window in which the service
        was never actually disturbed, and record a clean recovery from
        an event that did not happen - a green result meaning nothing.
        The Compose target covers this fault; the Kubernetes profile
        leaves it out.
        """
        raise RuntimeError(
            f"cannot freeze {unit} under Kubernetes: the daemon is PID 1 in its "
            "namespace and ignores SIGSTOP from within it, and the freezer "
            "cgroup would trap the process doing the freezing. Use the Compose "
            "target for freeze faults."
        )

    def thaw(self, unit: str) -> None:
        """Nothing to undo: freeze() never happened. See its docstring."""

    def logs_since(self, unit: str, seconds: float) -> str:
        return self._kubectl(
            [
                "logs",
                self._pod(unit),
                "-c",
                self._component(unit),
                f"--since={int(seconds)}s",
                "--tail=2000",
            ],
            timeout=self.API_TIMEOUT_SECONDS,
            check=False,
        )

    def _container_field(self, unit: str, field: str) -> str:
        name = self._component(unit)
        return self._kubectl(
            [
                "get",
                "pod",
                self._pod(unit, refresh=True),
                "-o",
                "jsonpath={.status.containerStatuses[?(@.name=='"
                + name
                + "')]."
                + field
                + "}",
            ],
            timeout=self.API_TIMEOUT_SECONDS,
            check=False,
        ).strip()

    def started_at(self, unit: str) -> float:
        """When the daemon container last started.

        The container's start time, not the pod's: a probe-driven
        restart replaces the container while the pod lives on, and that
        is exactly the event this target exists to catch.
        """
        out = self._container_field(unit, "state.running.startedAt")
        if not out:
            return 0.0
        return datetime.fromisoformat(out.replace("Z", "+00:00")).timestamp()

    def restart_count(self, unit: str) -> int:
        """How many times the kubelet has restarted the daemon container.

        Has no Compose equivalent, and is much of the point of this
        target: a liveness probe firing during a long request shows up
        here and nowhere else.
        """
        out = self._container_field(unit, "restartCount")
        return int(out) if out.isdigit() else 0

    def ready(self, unit: str) -> bool:
        """Whether the chart's readiness probe currently passes."""
        out = self._kubectl(
            [
                "get",
                "pod",
                "-l",
                self._selector(unit),
                "-o",
                "jsonpath={.items[0].status.conditions[?(@.type=='Ready')].status}",
            ],
            timeout=self.API_TIMEOUT_SECONDS,
            check=False,
        ).strip()
        return out == "True"

    def listening(self, unit: str, port: int) -> bool:
        """Whether the daemon actually holds the port open.

        Paired with ready() this answers the question a readiness probe
        exists to answer and which nothing else checks: does Ready mean
        reachable. A probe passing before the listener exists sends
        traffic into a refused connection.
        """
        try:
            out = self.run_in(
                unit,
                ["sh", "-c", f"ss -Htln sport = :{port} | head -1"],
                timeout=15.0,
                check=False,
            )
        except (RuntimeError, TimeoutError):
            return False
        return bool(out.strip())
