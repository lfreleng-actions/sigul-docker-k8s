# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""The Kubernetes backend: a chart release, driven through kubectl.

Kept apart from target.py so that neither backend has to be read to
understand the other, and so the Docker path carries no import of a
tool it never uses. The kubectl plumbing underneath is in k8s_api.py:
this module is only about what a Sigul stack looks like through it.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass

# ProductDefect is the fault layer's vocabulary for "the product
# misbehaved", as opposed to "the harness broke". Imported rather than
# reinvented so that the Scheduler and the analyser classify a failed
# replacement the same way they classify a fault that catches the same
# class of problem directly.
from .faults.base import ProductDefect
from .k8s_api import Release
from .target import ProcessStats, Target

_log = logging.getLogger(__name__)


@dataclass(frozen=True)
class _Serving:
    """The socket state that has to exist for Ready to be true."""

    #: Reads as the tail of "... reported Ready while nothing was ...".
    description: str
    #: `ss` arguments, matching at least one socket when serving.
    ss_filter: str
    #: How long the socket may be absent before its absence is a
    #: finding. Per daemon, because they differ: see below.
    grace_seconds: float


#: What serving actually means, per daemon. Derived from what each one
#: does rather than copied from the chart's probe command: the bridge
#: accepts connections, so it must be listening; the server dials out
#: and holds a connection to the bridge, so it must be connected.
#: Checking the daemon's own behaviour rather than re-running the
#: probe is the point - a probe that stopped being evaluated at all
#: would still satisfy a copy of itself.
#:
#: The grace differs because the sockets do. The bridge's listener is
#: opened once and held for the daemon's life, so it is there the
#: instant Ready can legitimately be true and no allowance is
#: warranted: any at all would let a regressed probe mark the pod
#: Ready seconds before the listener appeared and still pass, which
#: is the precise window this check exists to catch.
#:
#: The server's connection is per-request. Sampling inside the pod at
#: 4 Hz during five signing requests caught two single-sample gaps -
#:
#:   1 1 1 1 1 1 1 1 1 1 1 1 1 1 0 1 1 1 1 1 1 0 1 1 1 1 1 ...
#:
#: - so a single reading landing in one would report a defect that is
#: not there, and this check fails the run. Polled rather than
#: loosened, because the defect being looked for is a daemon that
#: never connects at all: a gap of seconds is still that, a gap of a
#: quarter of a second is a handoff.
_SERVING = {
    "bridge": _Serving(
        description="listening on 44334",
        ss_filter="-Htln sport = :44334",
        grace_seconds=0.0,
    ),
    "server": _Serving(
        description="connected to the bridge on 44333",
        ss_filter="-Htn state established '( dport = :44333 )'",
        grace_seconds=5.0,
    ),
}


class KubernetesTarget(Target):
    """A stack deployed by the Helm chart, driven through kubectl.

    Everything happens from outside the cluster, which is what makes
    this worth having: the chart's probes and its StatefulSet are in
    play, and neither exists under Compose. Its NetworkPolicies are
    applied but not enforced by kind's default CNI, so they are
    rendered rather than tested (issue #26). Nothing is installed into
    the cluster to support the harness - no runner Deployment, no
    RBAC, no sidecar - so what is measured is the release as shipped
    rather than a variant of it arranged to be measurable.

    Units are named as the chart names them, and the component is the
    last word of the unit name: `sigul-bridge` is the bridge. That is
    what the chart labels its objects and names its containers with, so
    it is what everything here is addressed by.
    """

    #: None of them. There is no Toxiproxy in the cluster; the bridge's
    #: Service is ClusterIP and unreachable from outside it; the sigul
    #: CLI runs in the toolbox pod, where a signal from here cannot
    #: follow it; and freeze() is impossible (see its docstring). The
    #: Kubernetes profile therefore names only restart faults.
    CAPABILITIES = frozenset()

    #: stats() reads two cgroup files rather than running a tool, but
    #: goes through the same exec, so it gets its own bound.
    STATS_TIMEOUT_SECONDS = 20.0

    #: How long to wait for a deleted pod's replacement to be serving.
    REPLACEMENT_TIMEOUT_SECONDS = 60.0

    def __init__(
        self,
        namespace: str | None = None,
        context: str | None = None,
        release: str | None = None,
    ) -> None:
        self._release = Release(namespace=namespace, context=context, name=release)
        #: Times the chart said a unit was Ready while the socket it
        #: needs in order to serve was absent. Collected rather than
        #: logged, so the run can fail on them: a warning in a
        #: nightly's output is a warning nobody reads, and premature
        #: readiness is one of the defects this target exists to catch.
        self.probe_violations: list[str] = []

    def _component(self, unit: str) -> str:
        """The chart labels and names containers after the component."""
        return unit.rsplit("-", 1)[-1]

    def run_in(
        self, unit: str, argv: list[str], timeout: float = 30.0, check: bool = True
    ) -> str:
        return self._release.exec_in(
            self._component(unit), argv, timeout=timeout, check=check
        )

    def stats(self, unit: str) -> ProcessStats:
        # Read the cgroup rather than metrics-server, which a kind
        # cluster does not have and which samples on its own schedule
        # anyway. memory.current counts page cache, so take the anon
        # figure for parity with the Docker backend's usage-minus-cache.
        #
        # The command handles a missing cgroup file itself and always
        # exits zero, so check is left on: a non-zero exit is the exec
        # failing to run at all, and empty output would parse as zero
        # RSS and zero PIDs - a fabricated sample that counts towards
        # coverage and drags the leak trend down with it.
        out = self.run_in(
            unit,
            [
                "sh",
                "-c",
                "awk '/^anon /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null "
                "|| echo 0; cat /sys/fs/cgroup/pids.current 2>/dev/null || echo 0",
            ],
            timeout=self.STATS_TIMEOUT_SECONDS,
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
        controller creating a replacement, and the probes deciding when
        that replacement may be sent traffic.

        The pod deleted here is a *healthy* one. A server that is
        Running but never Ready - the state OrderedReady will not
        resolve on its own, and the one behind the production incident
        - needs a wedge this target cannot currently inject, and is
        deliberately out of scope (see issue #27). Nothing below should
        be read as covering it.

        Waiting is done against the container's start time rather than
        the pod's name or its Ready condition alone. Neither is enough
        on its own: a Deployment's replacement takes a new name while a
        StatefulSet's keeps the old one, and for a few seconds after the
        delete the *outgoing* pod is still present and still Ready, so
        a naive wait returns immediately having observed the pod it was
        supposed to be replacing.
        """
        component = self._component(unit)
        was_started = self.started_at(unit)
        pod = self._release.pod(component, refresh=True)
        self._release.run(
            ["delete", "pod", pod, "--now"],
            timeout=self._release.API_TIMEOUT_SECONDS,
        )
        self._release.forget_pod(component)

        deadline = time.monotonic() + self.REPLACEMENT_TIMEOUT_SECONDS
        last_error = ""
        while time.monotonic() < deadline:
            try:
                state = self._release.pod_state(component)
                if state.ready and state.started_at > was_started:
                    self._note_premature_readiness(unit, component)
                    return
            except RuntimeError as exc:
                # Either the controller has not created the replacement
                # yet, so there is no pod to resolve, or an exec into a
                # pod that is not accepting them. Expected for the first
                # second or two; anything else surfaces in the warning
                # below when the deadline runs out.
                last_error = str(exc)
                _log.debug("waiting for %s to be replaced: %s", unit, exc)
            self._release.forget_pod(component)
            time.sleep(1.0)
        # Raised, not warned. A replacement that never reports Ready
        # is invisible to everything else in the run: the server
        # serves over its own outbound connection to the bridge rather
        # than through a readiness-gated Service endpoint, so load
        # recovers, every other check passes, and a nightly stays
        # green with a broken probe and a rollout that will never
        # finish. ProductDefect rather than a bare exception because
        # that is what this is - the fault ran as intended and caught
        # the product misbehaving - and the Scheduler records it
        # against the fault without aborting the report.
        raise ProductDefect(
            f"{unit} did not report Ready within "
            f"{self.REPLACEMENT_TIMEOUT_SECONDS:.0f}s of being deleted"
            + (f" (last error: {last_error})" if last_error else "")
        )

    def _note_premature_readiness(self, unit: str, component: str) -> None:
        """Record a unit that reported Ready with no socket behind it.

        Ready is the chart's claim that the replacement can serve.
        Checked against the only thing that makes it true - the socket
        state the daemon needs in order to serve - at the one moment
        the two can disagree. A probe that passes early sends the next
        request into a refused connection, or pairs it with a server
        that is not there, and nothing else in the run would attribute
        that to the probe.

        Both daemons are checked, each against what serving means for
        it. The server's readiness is an established connection to the
        bridge, so a replacement marked Ready before it reconnects is
        the same defect wearing different clothes.

        serving() raises rather than answering False when it cannot
        ask, and that exception is left to the caller's retry loop: an
        exec that failed against a pod seconds old must not be recorded
        as the defect this exists to detect.
        """
        expected = _SERVING.get(component)
        if expected is None or self.serving(unit):
            return
        violation = f"{unit} reported Ready while nothing was {expected.description}"
        _log.warning("%s", violation)
        self.probe_violations.append(violation)

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
        component = self._component(unit)
        # The one call that tolerates failure: a container that has only
        # just started legitimately has no logs, and an empty string is
        # the right answer for the error-rate accounting downstream.
        return self._release.run(
            [
                "logs",
                self._release.pod(component),
                "-c",
                component,
                f"--since={int(seconds)}s",
                "--tail=2000",
            ],
            timeout=self._release.API_TIMEOUT_SECONDS,
            check=False,
        )

    def started_at(self, unit: str) -> float:
        """When the daemon container last started.

        The container's start time, not the pod's: a probe-driven
        restart replaces the container while the pod lives on, and that
        is exactly the event this target exists to catch.

        Read through pod_state so that a failed query raises instead of
        answering 0.0. The sampler writes this to every row and the
        analyser reads a change in it as a restart, so a fabricated
        zero on one reading fails the hard "no restart between baseline
        and cooldown" invariant over an API blip that restarted
        nothing. Raised, the sampler skips the reading instead.
        """
        return self._release.pod_state(self._component(unit)).started_at

    def restart_count(self, unit: str) -> int:
        """How many times the kubelet has restarted the daemon container.

        Has no Compose equivalent, and is much of the point of this
        target: a liveness probe firing during a long request shows up
        here and nowhere else.
        """
        out = self._release.container_field(self._component(unit), "restartCount")
        return int(out) if out.isdigit() else 0

    def ready(self, unit: str) -> bool:
        """Whether the chart's readiness probe currently passes.

        The same single reading as started_at, so the two can never
        describe different pods - see Release.pod_state.
        """
        return self._release.pod_state(self._component(unit)).ready

    def serving(self, unit: str) -> bool:
        """Whether the daemon holds the socket it needs in order to serve.

        Paired with ready() this answers the question a readiness probe
        exists to answer and which nothing else checks: does Ready mean
        reachable. The bridge must be listening for clients; the server
        must be connected to the bridge.

        Polled for the daemon's own grace rather than sampled once -
        zero for the bridge, whose listener is permanent, and five
        seconds for the server, whose connection is per-request. See
        _SERVING. Returns as soon as the socket appears, so the healthy
        case costs one exec either way.

        Errors are raised, not turned into False. False is a finding
        that fails the run, so it has to mean "asked, and the socket
        was not there" - never "could not ask".
        """
        expected = _SERVING.get(self._component(unit))
        if expected is None:
            return True
        deadline = time.monotonic() + expected.grace_seconds
        while True:
            out = self.run_in(
                unit,
                ["sh", "-c", f"ss {expected.ss_filter} | head -1"],
                timeout=self.READING_TIMEOUT_SECONDS,
            )
            if out.strip():
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.25)

    def sample_budget_seconds(self) -> float:
        """Arithmetic over this backend's own bounds; see Target.

        Everything here is a kubectl round trip, and a reading that
        meets a replaced pod pays for a second resolution and a second
        exec before it fails. One reading of one unit is therefore the
        cgroup read, the three exec readings, and started_at - one
        pod_state query.

        The result is minutes rather than seconds, and deliberately so:
        it is only ever waited out when the apiserver has stopped
        answering at the moment the run ends, and failing the run then
        would throw away half an hour of measurements that are already
        on disk.
        """
        return (
            self._release.exec_budget_seconds(self.STATS_TIMEOUT_SECONDS)
            + 3 * self._release.exec_budget_seconds(self.READING_TIMEOUT_SECONDS)
            + self._release.API_TIMEOUT_SECONDS
        )
