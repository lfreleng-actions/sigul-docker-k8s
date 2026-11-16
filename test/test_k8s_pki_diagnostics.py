#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Tests for the diagnostics test/k8s_pki_clients.sh collects when it
# fails (#120).
#
# Runs the script against stand-in kind, helm and kubectl commands.
# The helm upgrade fails, so the cleanup trap collects diagnostics and
# deletes the cluster. Checks:
#   - the script exits with helm's status and deletes the cluster,
#     whether kubectl answers, fails every call, hangs on every
#     diagnostics query, or the log directory cannot be created
#   - when every query hangs, the whole collection stops at its budget
#     rather than running each call to its own deadline in turn, and
#     the queries it skipped say so
#   - a container that restarted has its previous logs collected, and
#     one that did not has none
#   - the bridge's daemon log is read from its container, and the
#     server's, whose container refuses the exec, is recorded as
#     unavailable with kubectl's error
#   - the pods' describe output and the workloads' YAML are collected
#
# Needs bash and coreutils only:
#   python3 test/test_k8s_pki_diagnostics.py

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "k8s_pki_clients.sh"
HELM_STATUS = 7
# Well past what a hanging run needs with a 1 s diagnostics timeout,
# well short of the stub's 600 s stall.
SCRIPT_DEADLINE = 120
# With every query hanging, the collection makes some 25 calls, so a
# 2 s per-call deadline alone would take about 50 s; a 4 s budget must
# end it well inside BUDGET_BOUND.
BUDGET_TIMEOUT = 2
BUDGET = 4
BUDGET_BOUND = 20

FAILURES: list[str] = []

KIND = """#!/bin/bash
case "$1" in
    get) echo "${PKI_TEST_CLUSTER}" ;;
    delete) echo "$*" >> "${STUB_RECORD}" ;;
esac
"""

HELM = f"""#!/bin/bash
echo "Error: UPGRADE FAILED: context deadline exceeded" >&2
exit {HELM_STATUS}
"""

# Pods: the server restarted five times and refuses an exec; the
# bridge has not restarted and its daemon log can be read.
KUBECTL = r"""#!/bin/bash
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --context | -n) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"
case "$1" in
    create | apply | label) exit 0 ;;
esac
if [ -n "${STUB_BROKEN:-}" ]; then
    echo "error: the server is unreachable" >&2
    exit 1
fi
pod_of() {
    case "$1" in
        *component=bridge) echo sigul-bridge-abc ;;
        *component=server) echo sigul-server-0 ;;
        *component=admin-toolbox) echo sigul-admin-toolbox-xyz ;;
        *component=pki-bootstrap) echo sigul-pki-bootstrap-r2-q ;;
    esac
}
# STUB_HANG: every query but the pod list stalls, as against an API
# server that stops answering; exec so timeout's signal reaches sleep.
if [ -n "${STUB_HANG:-}" ] && [ "$1 $2 $3" != "get pods -l" ]; then
    exec sleep 600
fi
case "$1 $2" in
    "get pods")
        if [ "$3" = -l ]; then pod_of "$4"; else echo "NAME READY STATUS"; fi ;;
    "get pod")
        case "$3" in
            sigul-server-0) printf 'server 5\n' ;;
            sigul-bridge-abc) printf 'nss-init 0\nbridge 0\nhealth 0\n' ;;
            *) printf 'main 0\n' ;;
        esac ;;
    "get events") echo "Liveness probe failed" ;;
    "get statefulset,deployment,job") echo "kind: List" ;;
    "describe pods") echo "describe $4" ;;
    "logs -l") echo "current $3" ;;
    "logs "*) echo "previous $2 $4 $*" ;;
    "exec sigul-bridge-abc") echo "bridge daemon log" ;;
    "exec "*)
        echo "error: container server is not running" >&2
        exit 1 ;;
    *) exit 1 ;;
esac
"""


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def run(
    work: Path,
    log_dir: Path,
    broken: bool = False,
    hang: bool = False,
    budget: int | None = None,
) -> tuple[int, str]:
    """Run the script with the stand-ins; return its status and the kind deletes."""
    stubs = work / "bin"
    stubs.mkdir(exist_ok=True)
    for name, body in (("kind", KIND), ("helm", HELM), ("kubectl", KUBECTL)):
        path = stubs / name
        _ = path.write_text(body)
        path.chmod(0o755)
    record = work / "record"
    _ = record.write_text("")
    env = dict(os.environ)
    env.update(
        PATH=f"{stubs}:{env['PATH']}",
        PKI_TEST_CLUSTER="pki-diag",
        PKI_TEST_LOG_DIR=str(log_dir),
        STUB_RECORD=str(record),
    )
    if broken:
        env["STUB_BROKEN"] = "1"
    if hang:
        env["STUB_HANG"] = "1"
        env["PKI_TEST_DIAG_TIMEOUT"] = "1"
    if budget is not None:
        env["PKI_TEST_DIAG_TIMEOUT"] = str(BUDGET_TIMEOUT)
        env["PKI_TEST_DIAG_BUDGET"] = str(budget)
    try:
        done = subprocess.run(
            ["bash", str(SCRIPT)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=SCRIPT_DEADLINE,
        )
    except subprocess.TimeoutExpired:
        return -1, record.read_text()
    return done.returncode, record.read_text()


def check_exit(label: str, status: int, deletes: str) -> None:
    check(
        f"{label}: exit status",
        status == HELM_STATUS,
        f"script exited {status}, helm {HELM_STATUS}",
    )
    check(
        f"{label}: cluster deleted",
        "delete cluster --name pki-diag" in deletes,
        repr(deletes.strip()),
    )


def read(path: Path) -> str:
    return path.read_text() if path.is_file() else "<missing>"


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)

        logs = work / "logs"
        status, deletes = run(work, logs)
        check_exit("kubectl answers", status, deletes)

        previous = read(logs / "sigul-server-0.server.previous.log")
        check(
            "restarted server container: previous logs",
            "--previous" in previous and "--timestamps" in previous,
            previous.strip(),
        )
        stray = sorted(
            p.name
            for p in logs.glob("*.previous.log")
            if "sigul-server-0" not in p.name
        )
        check(
            "containers that did not restart: no previous logs", not stray, str(stray)
        )

        bridge = read(logs / "sigul-bridge-abc.sigul_bridge.log")
        check("bridge daemon log read", bridge == "bridge daemon log\n", bridge.strip())
        server = read(logs / "sigul-server-0.sigul_server.log")
        check(
            "server daemon log recorded as unavailable",
            server.startswith("UNAVAILABLE:") and "is not running" in server,
            server.strip(),
        )

        for component in ("bridge", "server", "admin-toolbox", "pki-bootstrap"):
            described = read(logs / f"{component}.describe.txt")
            check(
                f"{component}: describe collected",
                f"component={component}" in described,
                described.strip(),
            )
            current = read(logs / f"{component}.log")
            check(
                f"{component}: current logs collected",
                "current" in current,
                current.strip(),
            )
        workloads = read(logs / "workloads.yaml")
        check("workloads YAML collected", "kind: List" in workloads, workloads.strip())

        status, deletes = run(work, work / "broken-logs", broken=True)
        check_exit("every kubectl call fails", status, deletes)

        status, deletes = run(work, work / "hang-logs", hang=True)
        check_exit("every diagnostics query hangs", status, deletes)

        budget_logs = work / "budget-logs"
        started = time.monotonic()
        status, deletes = run(work, budget_logs, hang=True, budget=BUDGET)
        elapsed = time.monotonic() - started
        check_exit("diagnostics budget spent", status, deletes)
        check(
            "diagnostics budget bounds the whole collection",
            elapsed < BUDGET_BOUND,
            f"{elapsed:.1f} s with a {BUDGET} s budget, bound {BUDGET_BOUND} s",
        )
        skipped = read(budget_logs / "pki-bootstrap.log")
        check(
            "query after the budget recorded as skipped",
            skipped.startswith("SKIPPED:"),
            skipped.strip(),
        )

        blocker = work / "not-a-directory"
        _ = blocker.write_text("")
        status, deletes = run(work, blocker / "logs")
        check_exit("log directory cannot be created", status, deletes)

    if FAILURES:
        print(f"\n{len(FAILURES)} FAILED")
        sys.exit(1)
    print("\nall checks passed")


if __name__ == "__main__":
    main()
