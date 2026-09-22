# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Talking to one Helm release through kubectl.

Split from target_k8s.py so that the two questions stay apart: this
one is how to ask the apiserver something and what its answers are
worth, and that one is what a Sigul stack looks like through those
answers. Everything that bounds a call, decides whether an empty reply
is a reading or a failure, or finds a pod, lives here.

Nothing in here knows about bridges, servers or faults.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True)
class PodState:
    """One pod, as a single reading: who it is, Ready, and since when."""

    name: str
    ready: bool
    #: Epoch seconds the named container started, 0.0 if not running.
    started_at: float


class Release:
    """A chart release, addressed by label rather than by name.

    Never builds a name from the release: the chart's fullname helper
    appends the chart name to any release whose own name does not
    contain it, so a release called "test" installs as
    "test-sigul-bridge". Labels are the chart's own answer to what
    belongs to it, and they are the same under either name.
    """

    #: Ceiling on any single kubectl call. Generous next to the Docker
    #: backend's, because each one is a round trip to the apiserver and
    #: on a cold cluster the first exec of a run can take seconds.
    API_TIMEOUT_SECONDS = 60

    #: Allowance for the exec round trip on top of the bound the
    #: in-container `timeout` enforces.
    EXEC_GRACE_SECONDS = 15

    #: exec_in re-resolves the pod once before giving up, so a reading
    #: can cost two resolutions and two execs.
    EXEC_ATTEMPTS = 2

    def __init__(
        self,
        namespace: str | None = None,
        context: str | None = None,
        name: str | None = None,
    ) -> None:
        self.namespace = namespace or os.environ.get("SOAK_K8S_NAMESPACE", "sigul-soak")
        self.context = context or os.environ.get("SOAK_K8S_CONTEXT", "")
        self.name = name or os.environ.get("SOAK_K8S_RELEASE", "sigul")
        self._pods: dict[str, str] = {}

    def run(self, argv: list[str], timeout: float, check: bool = True) -> str:
        """One kubectl call against this release's namespace.

        Raises rather than returning a partial answer. A truncated
        reading is worse than a missing one: the callers that measure
        something would record it as zero, and a zero is a finding.
        """
        cmd = ["kubectl"]
        if self.context:
            cmd += ["--context", self.context]
        cmd += ["-n", self.namespace, *argv]
        try:
            proc = subprocess.run(  # noqa: S603 - fixed argv
                cmd, capture_output=True, timeout=timeout, check=False
            )
        except subprocess.TimeoutExpired as exc:
            raise TimeoutError(f"kubectl {argv[0]} exceeded {timeout:.0f}s") from exc
        out = proc.stdout.decode("utf-8", errors="replace")
        # 124 is the in-container `timeout` giving up, and it means the
        # command never finished - so whatever partial output it left
        # is not a reading. Raised even when check is off, because the
        # callers that pass check=False do so to tolerate a *failed*
        # command, not to accept a truncated one as an answer.
        #
        # check=False survives on exactly one call, logs_since(), where
        # "nothing" is a legitimate answer: a container that has only
        # just started has no logs. Everywhere else the flag is left
        # on, because empty output there is not an answer but a reading
        # that did not happen, and it would be recorded as zero RSS, as
        # an absent listener, or as a container lifetime beginning at
        # the epoch.
        if proc.returncode == 124:
            raise TimeoutError(f"kubectl {argv[0]} timed out inside the container")
        if check and proc.returncode != 0:
            err = proc.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(
                f"kubectl {argv[0]} exited {proc.returncode}: "
                f"{(err or out).strip()[:200]}"
            )
        return out

    def selector(self, component: str) -> str:
        return (
            f"app.kubernetes.io/instance={self.name},"
            f"app.kubernetes.io/component={component}"
        )

    def pod(self, component: str, refresh: bool = False) -> str:
        """The component's pod name, cached.

        Resolving per call would add a round trip to every reading. A
        Deployment's pod is renamed when it is replaced, so the cache
        is invalidated by whoever notices the miss rather than being
        trusted indefinitely.

        Newest by creation time, for the same reason pod_state() is:
        during a replacement the outgoing pod is still present, and
        name order decides which of the two a plain selector returns.
        A reading taken inside the pod being replaced is worse than no
        reading - it is the wrong pod's answer, attributed to the new
        one.
        """
        if refresh or component not in self._pods:
            out = self.run(
                [
                    "get",
                    "pod",
                    "-l",
                    self.selector(component),
                    "--sort-by=.metadata.creationTimestamp",
                    "-o",
                    "jsonpath={.items[-1:].metadata.name}",
                ],
                timeout=self.API_TIMEOUT_SECONDS,
            ).strip()
            if not out:
                raise RuntimeError(f"no {component} pod in {self.namespace}")
            self._pods[component] = out
        return self._pods[component]

    def forget_pod(self, component: str) -> None:
        self._pods.pop(component, None)

    def pod_state(self, component: str) -> PodState:
        """Name, Ready condition and container start time, in one query.

        One query and one object, because the two facts are only
        meaningful together. Asked separately they can describe
        different pods: during a replacement the outgoing pod is still
        present and still Ready, so a Ready read against it and a start
        time read a moment later against its replacement combine into a
        pod that never existed - one that is both Ready and newly
        started. A caller waiting for a replacement would return on
        that, and send load to a Service with no Ready endpoint.

        The newest pod by creation time, which is the replacement under
        either controller: a Deployment's is renamed, a StatefulSet's
        keeps the old name but is a new object.
        """
        out = self.run(
            [
                "get",
                "pod",
                "-l",
                self.selector(component),
                "--sort-by=.metadata.creationTimestamp",
                "-o",
                "jsonpath={range .items[-1:]}"
                '{.metadata.name}{"\\t"}'
                "{.status.conditions[?(@.type=='Ready')].status}"
                '{"\\t"}'
                "{.status.containerStatuses[?(@.name=='"
                + component
                + "')].state.running.startedAt}"
                "{end}",
            ],
            timeout=self.API_TIMEOUT_SECONDS,
        )
        name, _, rest = out.partition("\t")
        ready, _, started = rest.partition("\t")
        if not name.strip():
            raise RuntimeError(f"no {component} pod in {self.namespace}")
        return PodState(
            name=name.strip(),
            ready=ready.strip() == "True",
            started_at=_epoch(started.strip()),
        )

    def container_field(self, component: str, field: str) -> str:
        """One field of the component's container status.

        check left on: an empty result then means the query succeeded
        and the field is not set - a container that is not running -
        rather than a query that never ran. The difference matters,
        because a caller would read a failed call as zero.
        """
        return self.run(
            [
                "get",
                "pod",
                self.pod(component, refresh=True),
                "-o",
                "jsonpath={.status.containerStatuses[?(@.name=='"
                + component
                + "')]."
                + field
                + "}",
            ],
            timeout=self.API_TIMEOUT_SECONDS,
        ).strip()

    def exec_in(
        self,
        component: str,
        argv: list[str],
        timeout: float = 30.0,
        check: bool = True,
    ) -> str:
        """Run a command in the component's container.

        Two bounds, for the same reason as the Docker backend:
        `timeout` inside the container bounds the command, and the
        subprocess timeout bounds the round trip. A wedged pod answers
        neither.
        """
        last: Exception | None = None
        for attempt in range(self.EXEC_ATTEMPTS):
            pod = self.pod(component, refresh=attempt > 0)
            try:
                return self.run(
                    [
                        "exec",
                        pod,
                        "-c",
                        component,
                        "--",
                        "timeout",
                        str(int(timeout)),
                        *argv,
                    ],
                    timeout=timeout + self.EXEC_GRACE_SECONDS,
                    check=check,
                )
            except RuntimeError as exc:
                # A pod replaced since it was resolved gives "not
                # found". Re-resolve once before calling it a failure.
                last = exc
        raise RuntimeError(f"exec in {component} failed: {last}")

    def exec_budget_seconds(self, timeout: float) -> float:
        """Worst case for one exec_in call, retry included."""
        return self.EXEC_ATTEMPTS * (
            self.API_TIMEOUT_SECONDS + timeout + self.EXEC_GRACE_SECONDS
        )


def _epoch(stamp: str) -> float:
    """RFC 3339 as epoch seconds; 0.0 for the empty string.

    Empty is a real answer here - a container that is not running has
    no start time - and only reachable because run() raises on a query
    that did not succeed.
    """
    if not stamp:
        return 0.0
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
