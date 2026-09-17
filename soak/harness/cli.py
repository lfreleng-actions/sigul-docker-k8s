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


@dataclass(frozen=True)
class Outcome:
    ok: bool
    #: stdout on success, the last line of stderr on failure, or a
    #: description of the timeout.
    detail: str
    timed_out: bool = False


def run_sigul(argv: list[str], passwords: list[str], timeout: float) -> Outcome:
    """Run one sigul command, feeding NUL-separated passwords on stdin."""
    stdin_payload = b"".join(p.encode() + b"\0" for p in passwords)
    proc = subprocess.Popen(  # noqa: S603 - fixed argv
        ["sigul", "--batch", "-c", CONFIG, *argv],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(stdin_payload, timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_group(proc)
        return Outcome(False, f"timeout after {timeout:.0f}s", timed_out=True)

    if proc.returncode == 0:
        return Outcome(True, stdout.decode("utf-8", errors="replace"))
    text = (stderr or stdout).decode("utf-8", errors="replace").strip()
    detail = text.splitlines()[-1][:200] if text else f"exit {proc.returncode}"
    return Outcome(False, detail)


def kill_group(proc: subprocess.Popen) -> None:
    """Kill a client and its forwarding child, and reap the parent."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(proc.pid, signal.SIGKILL)
    with contextlib.suppress(Exception):
        proc.communicate(timeout=10)
