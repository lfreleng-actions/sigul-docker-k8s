# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Run the `sigul` CLI the way the harness needs it run.

The client forks a forwarding child that owns the connection to the
bridge. A plain `subprocess.run(timeout=...)` kills only the parent on
timeout, and the orphaned child then keeps the bridge's single slot
occupied - turning whatever the stack did into a stall the harness
itself created. Every invocation here runs in its own process group
and the whole group is killed and reaped on timeout.
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
from dataclasses import dataclass

CONFIG = os.environ.get("SIGUL_CONFIG", "/etc/sigul/client.conf")

#: Where the client runs. Under Compose the harness shares a network
#: with the bridge and runs `sigul` directly. Against a cluster it runs
#: outside, so requests go through the chart's admin toolbox - the pod
#: that already holds a provisioned client - and the harness stays a
#: thing that observes the release rather than part of it.
_VIA = os.environ.get("SOAK_SIGUL_VIA", "local").strip().lower()
_NAMESPACE = os.environ.get("SOAK_K8S_NAMESPACE", "sigul-soak")
_CONTEXT = os.environ.get("SOAK_K8S_CONTEXT", "")
_RELEASE = os.environ.get("SOAK_K8S_RELEASE", "sigul")
_TOOLBOX_SELECTOR = (
    f"app.kubernetes.io/instance={_RELEASE},app.kubernetes.io/component=admin-toolbox"
)
_toolbox: str | None = None


def _kubectl_base() -> list[str]:
    cmd = ["kubectl"]
    if _CONTEXT:
        cmd += ["--context", _CONTEXT]
    return cmd + ["-n", _NAMESPACE]


def _toolbox_pod(refresh: bool = False) -> str:
    """The admin toolbox pod, resolved once and cached.

    Resolving per request would add an API round trip to every measured
    latency. Cached, a replaced toolbox costs one failed request and is
    picked up on the retry.
    """
    global _toolbox
    if _toolbox is None or refresh:
        out = subprocess.run(  # noqa: S603 - fixed argv
            [
                *_kubectl_base(),
                "get",
                "pod",
                "-l",
                _TOOLBOX_SELECTOR,
                "-o",
                "jsonpath={.items[0].metadata.name}",
            ],
            capture_output=True,
            timeout=30,
            check=False,
        )
        name = out.stdout.decode().strip()
        if not name:
            raise RuntimeError(f"no admin toolbox pod in {_NAMESPACE}")
        _toolbox = name
    return _toolbox


def _argv(argv: list[str], timeout: float) -> list[str]:
    """The command to run, local or through the toolbox."""
    sigul = ["sigul", "--batch", "-c", CONFIG, *argv]
    if _VIA != "kubectl":
        return sigul
    # `timeout` on the far side as well as this side. Killing kubectl
    # closes the stream, which usually ends the remote process, but
    # "usually" is not good enough here: a surviving client holds the
    # bridge's only slot and turns the next measurement into a stall
    # the harness invented. KILL rather than TERM because the point is
    # to be certain, and the client has nothing to clean up that
    # outlives its connection.
    return [
        *_kubectl_base(),
        "exec",
        "-i",
        _toolbox_pod(),
        "-c",
        "toolbox",
        "--",
        "timeout",
        "--signal=KILL",
        str(int(timeout)),
        *sigul,
    ]


@dataclass(frozen=True)
class Outcome:
    ok: bool
    #: stdout on success, the last line of stderr on failure, or a
    #: description of the timeout.
    detail: str
    timed_out: bool = False


def ensure_remote_payloads(
    work_dir: str, payloads: tuple[tuple[str, int], ...]
) -> None:
    """Create the signing payloads wherever `sigul` will run.

    A no-op locally, where the load generator and the client share a
    filesystem. Against a cluster they do not: the client runs in the
    toolbox pod, and a path that exists here means nothing there.

    The files are generated in the pod rather than copied into it. A
    64 MiB payload through the apiserver's exec stream is slow enough
    to distort the start of a run, and nothing depends on both copies
    holding the same bytes - only on their being incompressible and
    the right size.
    """
    if _VIA != "kubectl":
        return
    script = [f"mkdir -p {work_dir}"]
    for name, size in payloads:
        path = f"{work_dir}/{name}"
        # Only write what is missing or the wrong size, so a rerun
        # against a surviving pod does not pay for it again.
        script.append(
            f'[ "$(stat -c %s {path} 2>/dev/null || echo 0)" = "{size}" ] || '
            f"head -c {size} /dev/urandom > {path}"
        )
    result = subprocess.run(  # noqa: S603 - fixed argv
        [
            *_kubectl_base(),
            "exec",
            _toolbox_pod(),
            "-c",
            "toolbox",
            "--",
            "sh",
            "-c",
            "; ".join(script),
        ],
        capture_output=True,
        timeout=300,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "could not create payloads in the toolbox pod: "
            + result.stderr.decode("utf-8", errors="replace").strip()[:200]
        )


def run_sigul(argv: list[str], passwords: list[str], timeout: float) -> Outcome:
    """Run one sigul command, feeding NUL-separated passwords on stdin."""
    stdin_payload = b"".join(p.encode() + b"\0" for p in passwords)
    proc = subprocess.Popen(  # noqa: S603 - fixed argv
        _argv(argv, timeout),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        # Through kubectl the far side bounds itself, so allow for the
        # round trip before giving up on this side; locally the two are
        # the same thing.
        stdout, stderr = proc.communicate(
            stdin_payload, timeout=timeout + (10 if _VIA == "kubectl" else 0)
        )
    except subprocess.TimeoutExpired:
        kill_group(proc)
        return Outcome(False, f"timeout after {timeout:.0f}s", timed_out=True)

    if proc.returncode == 0:
        return Outcome(True, stdout.decode("utf-8", errors="replace"))
    if proc.returncode == 124:
        # coreutils timeout on the far side: the request overran, which
        # is the same event as the local timeout above and must be
        # recorded as one rather than as a failed request.
        return Outcome(False, f"timeout after {timeout:.0f}s", timed_out=True)
    text = (stderr or stdout).decode("utf-8", errors="replace").strip()
    lines = [line for line in text.splitlines() if line.strip()]
    if _VIA == "kubectl":
        # kubectl appends its own epitaph to stderr, which is the last
        # line and says nothing: "command terminated with exit code 1".
        # The line before it is the client's actual complaint, and that
        # is what belongs in the report.
        lines = [
            line
            for line in lines
            if not line.startswith("command terminated with exit code")
        ]
    detail = lines[-1][:200] if lines else f"exit {proc.returncode}"
    return Outcome(False, detail)


def kill_group(proc: subprocess.Popen) -> None:
    """Kill a client and its forwarding child, and reap the parent."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGKILL)
    with contextlib.suppress(Exception):
        proc.communicate(timeout=10)
