# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Freezing a pod's daemon from the kind node it runs on.

A daemon cannot be frozen from inside its own pod. It is PID 1 there -
deliberately, since patch 08's orphan reaper depends on it - and the
kernel discards default-action signals sent to namespace init from
inside that namespace: a non-PID-1 process goes S to T under SIGSTOP,
PID 1 stays Ss. The freezer cgroup is no better, since it would also
suspend the shell doing the freezing, leaving no way back in.

On kind there is another way. Each node is a Docker container whose
PID namespace is an ancestor of every pod's, and a signal from an
ancestor namespace is not subject to that rule. Measured there: the
server daemon, PID 1 in its pod and 2231 on the node, goes S to T under
SIGSTOP and back under SIGCONT.

That keeps the harness outside the cluster: it drives the node
container through Docker, installs nothing and changes no RBAC. It
does mean this is kind-specific. On any other cluster available() is
false, and freezing refuses rather than pretending.
"""

from __future__ import annotations

import subprocess

from .k8s_api import Release

#: Node providerID prefix kind gives its nodes; the rest names the node
#: container, as kind://docker/<cluster>/<node-container>.
_KIND_PROVIDER = "kind://docker/"


class NodeFreezer:
    """Suspends and resumes a container's daemon from its kind node."""

    #: Ceiling on one docker call. Each is a local exec into the node
    #: container, so seconds are plenty; the bound exists for a Docker
    #: daemon that stops answering.
    DOCKER_TIMEOUT_SECONDS = 30

    def __init__(self, release: Release) -> None:
        self._release = release
        self._available: bool | None = None
        #: What freeze() stopped, so thaw() resumes exactly that and no
        #: more: component -> (node container, PIDs on the node).
        self._frozen: dict[str, tuple[str, list[int]]] = {}

    def available(self) -> bool:
        """Whether every node is a kind node reachable through Docker.

        Asked once and remembered: the answer cannot change during a
        run, and the harness asks it for every fault it vets.
        """
        if self._available is None:
            self._available = self._probe()
        return self._available

    def _probe(self) -> bool:
        try:
            ids = self._release.run(
                ["get", "nodes", "-o", "jsonpath={.items[*].spec.providerID}"],
                timeout=self._release.API_TIMEOUT_SECONDS,
            ).split()
            if not ids or not all(i.startswith(_KIND_PROVIDER) for i in ids):
                return False
            self._docker(["inspect", "--format", "{{.State.Running}}", _node(ids[0])])
        except (RuntimeError, TimeoutError, OSError):
            return False
        return True

    def freeze(self, component: str) -> None:
        """SIGSTOP the component's daemon and everything it started.

        The daemon's own process tree, not the whole PID namespace: a
        `kubectl exec` the sampler happens to have running in the same
        container at that instant would otherwise be frozen too, and
        hang until its own timeout. Exec'd processes are parented from
        outside the namespace, so walking down from the container's init
        process reaches the daemon and its children and nothing else.

        Checked afterwards rather than assumed: a freeze that did not
        take would report an injected fault that never happened.
        """
        if not self.available():
            raise RuntimeError(
                "freezing needs a kind cluster: the daemon is PID 1 in its pod, "
                "where SIGSTOP from within is ignored, and only a kind node gives "
                "the harness an ancestor PID namespace to signal it from"
            )
        pod = self._release.pod(component, refresh=True)
        node = _node(
            self._release.run(
                [
                    "get",
                    "node",
                    self._release.run(
                        ["get", "pod", pod, "-o", "jsonpath={.spec.nodeName}"],
                        timeout=self._release.API_TIMEOUT_SECONDS,
                    ).strip(),
                    "-o",
                    "jsonpath={.spec.providerID}",
                ],
                timeout=self._release.API_TIMEOUT_SECONDS,
            ).strip()
        )
        cid = self._crictl(
            node,
            [
                "ps",
                "-q",
                "--label",
                f"io.kubernetes.pod.name={pod}",
                "--name",
                f"^{component}$",
            ],
        ).split()
        if not cid:
            raise RuntimeError(f"no running {component} container in {pod} on {node}")
        init = int(
            self._crictl(
                node,
                [
                    "inspect",
                    "--output",
                    "go-template",
                    "--template",
                    "{{.info.pid}}",
                    cid[0],
                ],
            ).strip()
        )
        pids = self._tree(node, init)
        self._docker(["exec", node, "kill", "-STOP", *map(str, pids)])
        self._frozen[component] = (node, pids)
        state = self._docker(
            ["exec", node, "awk", "/^State/{print $2}", f"/proc/{init}/status"]
        ).strip()
        if state != "T":
            raise RuntimeError(f"{component} daemon did not stop: state {state!r}")

    def thaw(self, component: str) -> None:
        """SIGCONT whatever freeze() stopped. Idempotent.

        Processes that are gone - replaced by the kubelet while frozen,
        which is the outcome a wedge fault hopes for - are skipped
        rather than treated as an error.
        """
        entry = self._frozen.pop(component, None)
        if entry is None:
            return
        node, pids = entry
        self._docker(
            [
                "exec",
                node,
                "sh",
                "-c",
                f"kill -CONT {' '.join(map(str, pids))} 2>/dev/null; true",
            ]
        )

    def _tree(self, node: str, init: int) -> list[int]:
        """The init process and its descendants, as PIDs on the node."""
        listing = self._docker(
            [
                "exec",
                node,
                "sh",
                "-c",
                f"ns=$(readlink /proc/{init}/ns/pid); for p in /proc/[0-9]*; do "
                f'[ "$(readlink $p/ns/pid 2>/dev/null)" = "$ns" ] && '
                "echo ${p#/proc/} $(awk '/^PPid/{print $2}' $p/status 2>/dev/null); "
                "done; true",
            ]
        )
        parent = {}
        for line in listing.splitlines():
            fields = line.split()
            if len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit():
                parent[int(fields[0])] = int(fields[1])
        tree = {init}
        grew = True
        while grew:
            children = {p for p, pp in parent.items() if pp in tree} - tree
            grew = bool(children)
            tree |= children
        return sorted(tree)

    def _crictl(self, node: str, argv: list[str]) -> str:
        return self._docker(["exec", node, "crictl", *argv])

    def _docker(self, argv: list[str]) -> str:
        try:
            proc = subprocess.run(  # noqa: S603 - fixed argv
                ["docker", *argv],
                capture_output=True,
                timeout=self.DOCKER_TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise TimeoutError(
                f"docker {argv[0]} exceeded {self.DOCKER_TIMEOUT_SECONDS}s"
            ) from exc
        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(
                f"docker {' '.join(argv[:3])} exited {proc.returncode}: {err[:200]}"
            )
        return proc.stdout.decode("utf-8", errors="replace")


def _node(provider_id: str) -> str:
    """The node container named in a kind providerID."""
    if not provider_id.startswith(_KIND_PROVIDER):
        raise RuntimeError(f"not a kind node: providerID {provider_id!r}")
    return provider_id.rsplit("/", 1)[-1]
