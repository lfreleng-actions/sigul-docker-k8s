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
import shlex
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
#: The payload manifest last provisioned, so it can be replayed into a
#: replacement toolbox pod. See ensure_remote_payloads().
_payloads: tuple[str, tuple[tuple[str, int], ...]] | None = None


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

    Newest Running pod by creation time, not the first the selector
    happens to return: a Deployment's outgoing pod overlaps its
    replacement, so plain name order can cache the one on its way out
    and every retry would re-resolve the same doomed name.
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
                "--field-selector=status.phase=Running",
                "--sort-by=.metadata.creationTimestamp",
                "-o",
                "jsonpath={.items[-1:].metadata.name}",
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


def _argv(
    argv: list[str], timeout: float, remove_after: tuple[str, ...] = ()
) -> list[str]:
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
    bounded = ["timeout", "--signal=KILL", str(int(timeout)), *sigul]
    if not remove_after:
        command = bounded
    else:
        # Cleanup in the same exec rather than a second one: a round
        # trip per request would be charged to the measurement it
        # follows. `rc` preserves the exit status across the rm, which
        # matters because 137 is how a far-side timeout is recognised,
        # and the rm runs whatever happened - a request that timed out
        # is exactly the one most likely to have left a part-written
        # file behind.
        command = [
            "sh",
            "-c",
            "{}; rc=$?; rm -f {}; exit $rc".format(
                shlex.join(bounded),
                " ".join(shlex.quote(path) for path in remove_after),
            ),
        ]
    return [
        *_kubectl_base(),
        "exec",
        "-i",
        _toolbox_pod(),
        "-c",
        "toolbox",
        "--",
        *command,
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

    Remembered, because the toolbox's /tmp is an emptyDir and does not
    survive the pod. A replacement starts with none of these, and
    every signing task afterwards would fail on a missing input - so
    whoever picks up a new pod replays this against it.
    """
    global _payloads
    _payloads = (work_dir, payloads)
    if _VIA != "kubectl":
        return
    _write_payloads(work_dir, payloads)


def _replay_payloads() -> None:
    """Re-create the payloads in a toolbox pod that has just replaced one."""
    if _VIA != "kubectl" or _payloads is None:
        return
    _write_payloads(*_payloads)


def _write_payloads(work_dir: str, payloads: tuple[tuple[str, int], ...]) -> None:
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


def run_sigul(
    argv: list[str],
    passwords: list[str],
    timeout: float,
    remove_after: tuple[str, ...] = (),
) -> Outcome:
    """Run one sigul command, feeding NUL-separated passwords on stdin.

    `remove_after` names files the command writes that must not
    survive it. Cleaning up is the caller's business in principle, but
    not in practice: the files are written wherever `sigul` runs, and
    only this knows where that is. A signing task deleting its own
    output works under Compose and silently does nothing against a
    cluster, where the file is in the toolbox pod - and a 64 MiB
    signature left behind per request fills the pod's ephemeral
    storage over a nightly, which surfaces as an eviction that looks
    like a chart defect.
    """
    stdin_payload = b"".join(p.encode() + b"\0" for p in passwords)
    try:
        outcome = _attempt(argv, stdin_payload, timeout, remove_after)
        if not outcome.ok and _VIA == "kubectl" and _pod_is_gone(outcome.detail):
            # The toolbox pod is cached so that resolving it does not add an
            # API round trip to every measured latency. The cost is that a
            # replaced pod would otherwise fail every remaining request of
            # the run - one infrastructure event becoming a soak-long
            # outage that says nothing about Sigul. Re-resolve once and
            # retry, which is safe because the request never reached a
            # client.
            try:
                _toolbox_pod(refresh=True)
                # The new pod's /tmp is empty: its predecessor's
                # payloads went with it. Without this the retry, and
                # every signing task after it, fails on a missing
                # input - a pod replacement turning into a run-long
                # outage that says nothing about Sigul.
                _replay_payloads()
            except (RuntimeError, subprocess.SubprocessError):
                # Nothing to retry against yet. Report the original failure
                # rather than this one: the caller is retrying anyway, and
                # the request's own error is the more useful of the two.
                return outcome
            outcome = _attempt(argv, stdin_payload, timeout, remove_after)
        return outcome
    finally:
        # Locally the files are here, so the remote cleanup woven into
        # the command above does not apply and this does. In a finally
        # because a timed-out request is the likeliest to have left a
        # part-written file behind.
        if _VIA != "kubectl":
            for path in remove_after:
                with contextlib.suppress(OSError):
                    os.unlink(path)


def _pod_is_gone(detail: str) -> bool:
    lowered = detail.lower()
    return "not found" in lowered or "podinitializing" in lowered


def _attempt(
    argv: list[str],
    stdin_payload: bytes,
    timeout: float,
    remove_after: tuple[str, ...] = (),
) -> Outcome:
    try:
        command = _argv(argv, timeout, remove_after)
    except (RuntimeError, subprocess.SubprocessError) as exc:
        # Resolving the toolbox pod is part of issuing the request, so
        # failing to resolve it is a failed request, not a harness
        # crash. Raising here would abandon the run before the
        # reporting path ever sees it, which is how a cluster that was
        # never deployed produced a traceback instead of a report
        # saying the stack served nothing.
        return Outcome(False, str(exc))
    proc = subprocess.Popen(  # noqa: S603 - fixed argv
        command,
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
    if proc.returncode == 124 or (_VIA == "kubectl" and proc.returncode == 137):
        # coreutils timeout on the far side: the request overran, which
        # is the same event as the local timeout above and must be
        # recorded as one rather than as a failed request.
        #
        # Two statuses because _argv passes --signal=KILL. coreutils
        # reports 124 when its own signal ends the command and 128+9
        # when SIGKILL does, and kubectl propagates whichever it gets -
        # measured in the toolbox pod: `timeout --signal=KILL 1 sleep 5`
        # exits 137, plain `timeout 1 sleep 5` exits 124. Only through
        # kubectl, because nothing wraps the local client in `timeout`,
        # so a local 137 is a client killed by something else and is
        # not a timeout.
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
