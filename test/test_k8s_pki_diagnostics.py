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
# And for a run that passes (#159), where helm succeeds and the
# stand-ins answer every request the script makes:
#   - with PKI_TEST_LARGE_FILE_BYTES set, the run logs when the
#     server's /tmp first held the whole file and the time from then
#     to the signature, the server log's timestamps for the request,
#     memory.stat, memory.events and df for the runner and the node;
#     it creates the file over the limit with truncate; and it
#     collects the diagnostics although it passed
#   - with it unset, none of that happens: no such log line, the file
#     over the limit written from /dev/urandom, no diagnostics
#   - a sample whose exec returns after signing has ended gives no
#     silent interval, where it would have given a negative one
#   - a large-file signing that fails after its upload is reported as
#     failing: the time is to the failure, and no line says the file
#     was signed or that a signature returned; the server log's
#     'Request:' timestamp is still reported
#   - samples that fail while the upload ends widen the bounds the run
#     reports on the silent interval by the time they took, rather
#     than leave the time from a later sample as within one period
#   - a partial upload that, with directories and other files, already
#     brings /tmp's total over the file's size is not taken for the
#     whole file: the upload's end is the time its own file is whole
#
# Needs bash and coreutils only:
#   python3 test/test_k8s_pki_diagnostics.py

import os
import shutil
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
# The passing runs move no data, so the size only has to differ from
# the script's default. The file over the limit is 1 MiB and a byte
# larger than the file signed.
LARGE_BYTES = 8388608
DEFAULT_OVER_LIMIT = 4194304 + 1048576 + 1
REQUEST_STAMP = "2026-01-02 03:04:05,006 INFO:"
SIGNED_STAMP = "2026-01-02 03:04:09,010 INFO:"
# How long the late sample's exec outlasts the signing. The script
# counts whole seconds, so it must be well over one to tell.
LATE_SAMPLE_DELAY = 4
# With STUB_FAILED_SAMPLES, the samples that first find the file fail,
# each after this long, as an exec that times out does.
FAILED_SAMPLES = 2
FAILED_SAMPLE_DELAY = 3
# With STUB_PARTIAL_PAYLOAD, how long the upload stays a byte short,
# once the sampler has seen it so, before it completes.
PARTIAL_DELAY = 5

FAILURES: list[str] = []

KIND = """#!/bin/bash
case "$1" in
    get) echo "${PKI_TEST_CLUSTER}" ;;
    delete) echo "$*" >> "${STUB_RECORD}" ;;
esac
"""

HELM = f"""#!/bin/bash
[ -z "${{STUB_PASS:-}}" ] || exit 0
echo "Error: UPGRADE FAILED: context deadline exceeded" >&2
exit {HELM_STATUS}
"""

# make-bundle.sh and the jq that unpacks its --format action output,
# for the passing runs: the real one needs NSS's tools and a cluster.
# The credentials file is the passphrase alone, which is all the
# script checks in it.
MAKE_BUNDLE = """#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out="$2" ;;
        --key-passphrase-file) passphrase="$2" ;;
    esac
    shift
done
mkdir -p "${out}"
echo conf > "${out}/client.conf"
echo pki > "${out}/sigul-pki.asc"
base64 < "${passphrase}" > "${out}/sigul-credentials.b64"
"""

JQ = """#!/bin/bash
case "$2" in
    .password) cat "$3" ;;
    *) echo eA== ;;
esac
"""

# Pods: the server restarted five times and refuses an exec; the
# bridge has not restarted and its daemon log can be read.
#
# With STUB_PASS the server takes an exec and the toolbox answers as
# a working service would: a request naming another user (-u) is
# refused and logged as a CN mismatch, the file over the limit is
# refused and logged, a deleted user's bundle no longer
# authenticates, and key-expiry.sh reports the test key as never
# expiring. Signing the file under the limit writes the server
# log's two lines and, in a large-file run, holds the file in the
# server's /tmp until the script's sampler has seen it there. /tmp
# then holds the upload, as its own tmp* file, and 4096 bytes of
# directories and other files besides.
#
# With STUB_LATE_SAMPLE the exec that finds the whole file returns
# only after the signing has: the server ran du in time, and the exec
# stream delivered its answer late. With STUB_SIGN_FAILS the signing
# fails once the file is uploaded, as when the bridge's idle deadline
# drops the request, and the server logs no 'Signed data'. With
# STUB_FAILED_SAMPLES the first FAILED_SAMPLE_COUNT execs to find the
# whole file fail, each after FAILED_SAMPLE_DELAY s, before one
# answers. With STUB_PARTIAL_PAYLOAD the upload first stays a byte
# short of the file for PARTIAL_DELAY s after a sample sees it so,
# while /tmp's total is already over the file's size.
KUBECTL = (
    r"""#!/bin/bash
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --context | -n) shift 2 ;;
        --) args+=("$@"); break ;;
        *) args+=("$1"); shift ;;
    esac
done
set -- "${args[@]}"
case "$1" in
    create | apply | label | wait | rollout) exit 0 ;;
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
server_log="${STUB_STATE}/server.log"
tmp_bytes="${STUB_STATE}/tmp-bytes"
sampled="${STUB_STATE}/sampled"
# in_tmp BYTES: the server's /tmp holds an upload of BYTES so far.
in_tmp() {
    echo "$(($1 + 4096)) $1" > "${tmp_bytes}.new"
    mv "${tmp_bytes}.new" "${tmp_bytes}"
}
# toolbox timeout --signal=KILL SECONDS CMD...
toolbox() {
    shift 3
    echo "toolbox $*" >> "${STUB_RECORD}"
    case " $* " in
        " df "*)
            echo "/dev/node 72G 30G 42G 42% /workspace" ;;
        " bash /scripts/key-expiry.sh "*)
            fingerprint=0123456789ABCDEF0123456789ABCDEF01234567
            echo "OK key=pki-clients-test-key primary=${fingerprint} signing=${fingerprint}" \
                "expires=never days=never" ;;
        " sigul "*" -u "*)
            echo "ERROR: Cert CN and user differ" >> "${server_log}"
            echo "Error: Authentication failed"
            return 1 ;;
        " sigul "*" delete-user "*)
            touch "${STUB_STATE}/deleted" ;;
        " sigul "*" sign-data "*over-limit.bin*)
            echo "Invalid request: Payload too large" >> "${server_log}"
            # The refusal as patches/26 has the client print it. The
            # limit is the script's: 1 MiB over the file it signs.
            limit=$((${PKI_TEST_LARGE_FILE_BYTES:-4194304} + 1048576))
            echo "Error: The payload is larger than the server accepts:" \
                "payload of $((limit + 1)) bytes, limit ${limit} bytes"
            return 1 ;;
        " sigul "*" sign-data "*)
            echo "REQUEST_STAMP Request: op = sign-data" >> "${server_log}"
            if [ -n "${PKI_TEST_LARGE_FILE_BYTES:-}" ]; then
                if [ -n "${STUB_PARTIAL_PAYLOAD:-}" ]; then
                    in_tmp $((PKI_TEST_LARGE_FILE_BYTES - 1))
                    for _ in $(seq 150); do
                        [ ! -e "${sampled}.partial" ] || break
                        sleep 0.2
                    done
                    sleep PARTIAL_DELAY
                fi
                in_tmp "${PKI_TEST_LARGE_FILE_BYTES}"
                for _ in $(seq 150); do
                    [ ! -e "${sampled}" ] || break
                    sleep 0.2
                done
                rm -f "${tmp_bytes}"
            fi
            if [ -n "${STUB_SIGN_FAILS:-}" ]; then
                echo "Error: Unexpected EOF in NSPR"
                return 1
            fi
            echo "SIGNED_STAMP Signed data" >> "${server_log}" ;;
        " sigul "*"opensearch-canary/client.conf sign-text "*)
            if [ -e "${STUB_STATE}/deleted" ]; then
                echo "Error: Authentication failed"
                return 1
            fi ;;
    esac
}
# server CMD..., in the server container
server() {
    case "$*" in
        "cat /var/log/sigul_server.log")
            cat "${server_log}" 2>/dev/null ;;
        "grep "*) echo 1 ;;
        "sh -c "*"du -sb /tmp"*"find /tmp"*)
            if [ -e "${tmp_bytes}" ]; then
                read -r used payload < "${tmp_bytes}"
                if [ -n "${STUB_FAILED_SAMPLES:-}" ]; then
                    echo x >> "${STUB_STATE}/failed-samples"
                    if [ "$(wc -l < "${STUB_STATE}/failed-samples")" \
                            -le FAILED_SAMPLE_COUNT ]; then
                        sleep FAILED_SAMPLE_DELAY
                        return 1
                    fi
                fi
                if [ "${payload}" -lt "${PKI_TEST_LARGE_FILE_BYTES}" ]; then
                    touch "${sampled}.partial"
                else
                    touch "${sampled}"
                    [ -z "${STUB_LATE_SAMPLE:-}" ] || sleep LATE_SAMPLE_DELAY
                fi
                printf 'total %s\npayload %s\n' "${used}" "${payload}"
            else
                printf 'total 4096\npayload 0\n'
            fi ;;
        "cat /sys/fs/cgroup/memory.peak") echo 1073741824 ;;
        "cat /sys/fs/cgroup/memory.stat")
            printf 'anon 111\nfile 222\nkernel 333\n' ;;
        "cat /sys/fs/cgroup/memory.events")
            printf 'low 0\nhigh 0\nmax 3\noom 0\noom_kill 0\n' ;;
        "df -h /tmp") echo "/dev/node 72G 30G 42G 42% /tmp" ;;
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
            -l) pod_of "$4" ;;
            sigul-server-0) printf 'server 5\n' ;;
            sigul-bridge-abc) printf 'nss-init 0\nbridge 0\nhealth 0\n' ;;
            *) printf 'main 0\n' ;;
        esac ;;
    "get job" | "get deployment" | "get statefulset")
        echo "$2.apps/sigul-${4##*component=}" ;;
    "get secret") printf c2VjcmV0 ;;
    "get events") echo "Liveness probe failed" ;;
    "get statefulset,deployment,job") echo "kind: List" ;;
    "describe pods") echo "describe $4" ;;
    "logs -l") echo "current $3" ;;
    "logs "*) echo "previous $2 $4 $*" ;;
    "exec sigul-bridge-abc") echo "bridge daemon log" ;;
    "exec -i")
        shift 6
        toolbox "$@" ;;
    "exec sigul-server-0")
        if [ -z "${STUB_PASS:-}" ]; then
            echo "error: container server is not running" >&2
            exit 1
        fi
        shift 5
        server "$@" ;;
    "exec "*)
        echo "error: container server is not running" >&2
        exit 1 ;;
    *) exit 1 ;;
esac
""".replace("REQUEST_STAMP", REQUEST_STAMP)
    .replace("SIGNED_STAMP", SIGNED_STAMP)
    .replace("LATE_SAMPLE_DELAY", str(LATE_SAMPLE_DELAY))
    .replace("FAILED_SAMPLE_DELAY", str(FAILED_SAMPLE_DELAY))
    .replace("FAILED_SAMPLE_COUNT", str(FAILED_SAMPLES))
    .replace("PARTIAL_DELAY", str(PARTIAL_DELAY))
)


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def execute(
    work: Path, log_dir: Path, settings: dict[str, str], script: Path = SCRIPT
) -> tuple[int, str, str]:
    """Run the script with the stand-ins and these environment settings.

    Returns its status, what the stand-ins recorded and its output.
    """
    stubs = work / "bin"
    stubs.mkdir(exist_ok=True)
    for name, body in (
        ("kind", KIND),
        ("helm", HELM),
        ("kubectl", KUBECTL),
        ("jq", JQ),
    ):
        path = stubs / name
        _ = path.write_text(body)
        path.chmod(0o755)
    record = work / "record"
    _ = record.write_text("")
    env = {k: v for k, v in os.environ.items() if not k.startswith("PKI_TEST_")}
    env.update(
        PATH=f"{stubs}:{env['PATH']}",
        PKI_TEST_CLUSTER="pki-diag",
        PKI_TEST_LOG_DIR=str(log_dir),
        STUB_RECORD=str(record),
        STUB_STATE=tempfile.mkdtemp(dir=work),
    )
    env.update(settings)
    try:
        done = subprocess.run(
            ["bash", str(script)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=SCRIPT_DEADLINE,
        )
    except subprocess.TimeoutExpired as expired:
        output = expired.stdout or b""
        return -1, record.read_text(), output.decode(errors="replace")
    return done.returncode, record.read_text(), done.stdout + done.stderr


def run(
    work: Path,
    log_dir: Path,
    broken: bool = False,
    hang: bool = False,
    budget: int | None = None,
) -> tuple[int, str]:
    """Run the script with a failing helm; return its status and the kind deletes."""
    settings: dict[str, str] = {}
    if broken:
        settings["STUB_BROKEN"] = "1"
    if hang:
        settings["STUB_HANG"] = "1"
        settings["PKI_TEST_DIAG_TIMEOUT"] = "1"
    if budget is not None:
        settings["PKI_TEST_DIAG_TIMEOUT"] = str(BUDGET_TIMEOUT)
        settings["PKI_TEST_DIAG_BUDGET"] = str(budget)
    status, record, _ = execute(work, log_dir, settings)
    return status, record


def run_passing(
    work: Path,
    log_dir: Path,
    large: int | None = None,
    stub: str | None = None,
) -> tuple[int, str, str]:
    """Run the script with a working helm; return its status, the record and its output.

    The script finds make-bundle.sh beside itself, so it runs from a
    copy of this checkout's layout that holds the stand-in instead.
    STUB names a stand-in setting that changes how the signing goes.
    """
    tree = Path(tempfile.mkdtemp(dir=work))
    script = tree / "test" / SCRIPT.name
    make_bundle = tree / "K8S/charts/sigul/files/toolbox/make-bundle.sh"
    script.parent.mkdir()
    make_bundle.parent.mkdir(parents=True)
    _ = shutil.copy(SCRIPT, script)
    _ = make_bundle.write_text(MAKE_BUNDLE)
    settings = {"STUB_PASS": "1"}
    if large is not None:
        settings["PKI_TEST_LARGE_FILE_BYTES"] = str(large)
    if stub is not None:
        settings[stub] = "1"
    return execute(work, log_dir, settings, script)


def passed(status: int, output: str) -> str:
    """The detail for a run meant to pass: its output only when it did not."""
    return f"exited {status}" if status == 0 else f"exited {status}\n{output}"


def check_passing(work: Path) -> None:
    """A passing run, with PKI_TEST_LARGE_FILE_BYTES set and then unset."""
    logs = work / "large-logs"
    status, record, output = run_passing(work, logs, large=LARGE_BYTES)
    check("large-file run: passes", status == 0, passed(status, output))
    check(
        "large-file run: cluster deleted",
        "delete cluster --name pki-diag" in record,
        "kind delete recorded",
    )
    over_limit = LARGE_BYTES + 1048576 + 1
    for label, text in (
        ("when /tmp first held the file", "server /tmp first held the whole file"),
        ("time from then to the signature", "s from then to the signature returning"),
        ("what that time approximates", "approximates the silent interval"),
        ("Request: timestamp", f"'Request:' line stamped {REQUEST_STAMP}"),
        ("Signed data timestamp", f"'Signed data' line stamped {SIGNED_STAMP}"),
        ("memory.stat", "memory.stat after signing: anon 111 file 222"),
        ("memory.events", "low 0 high 0 max 3 oom 0 oom_kill 0"),
        ("df for the runner", "df on the runner: "),
        ("df for the node, server", "from the server's /tmp: /dev/node"),
        ("df for the node, toolbox", "from the toolbox's /workspace: /dev/node"),
        ("what the sparse file saves", f"saves {over_limit} bytes"),
    ):
        lines = [line for line in output.splitlines() if text in line]
        check(f"large-file run logs {label}", bool(lines), str(lines or text))
    check(
        "large-file run: kernel memory is not reported as anon or file",
        "kernel 333" not in output,
        "memory.stat lines other than anon and file left out",
    )
    check(
        "large-file run: the file over the limit is created sparse",
        f"truncate -s {over_limit} /workspace/over-limit.bin" in record
        and "/dev/urandom > /workspace/over-limit.bin" not in record,
        "truncate, and no write from /dev/urandom",
    )
    server = read(logs / "sigul-server-0.sigul_server.log")
    check(
        "large-file run: diagnostics collected on a pass",
        (logs / "resources.txt").is_file() and "Signed data" in server,
        server.strip(),
    )

    logs = work / "default-logs"
    status, record, output = run_passing(work, logs)
    check("default run: passes", status == 0, passed(status, output))
    check(
        "default run: no large-file log line",
        "large-file run" not in output,
        "nothing logged as a large-file run",
    )
    check(
        "default run: the file over the limit is written as before",
        f"head -c {DEFAULT_OVER_LIMIT} /dev/urandom > /workspace/over-limit.bin"
        in record
        and "truncate" not in record,
        "head -c from /dev/urandom, and no truncate",
    )
    check(
        "default run: no diagnostics on a pass",
        not logs.exists(),
        f"{logs.name} {'exists' if logs.exists() else 'absent'}",
    )


def check_late_sample(work: Path) -> None:
    """A sample whose exec returns after the signing gives no interval."""
    status, _, output = run_passing(
        work, work / "late-logs", large=LARGE_BYTES, stub="STUB_LATE_SAMPLE"
    )
    check("late sample: passes", status == 0, passed(status, output))
    late = [line for line in output.splitlines() if "later than the" in line]
    check(
        "late sample: the silent interval is unavailable",
        bool(late) and "so the silent interval is unavailable" in late[0],
        str(late or output),
    )
    check(
        "late sample: no interval reported, negative or otherwise",
        "s from then to" not in output and "first held the whole file" not in output,
        "no time from the upload's end",
    )
    check(
        "late sample: the signing's own time still reported",
        f"{LARGE_BYTES} bytes signed in " in output,
        "end-to-end time logged",
    )


def check_failed_signing(work: Path) -> None:
    """A signing that fails after its upload is not reported as signed."""
    logs = work / "failed-logs"
    status, _, output = run_passing(
        work, logs, large=LARGE_BYTES, stub="STUB_SIGN_FAILS"
    )
    check("failed signing: the run fails", status == 1, f"exited {status}")
    for label, text in (
        ("the signing as failing", f"signing {LARGE_BYTES} bytes failed after "),
        ("no time to a signature", "so the time to a signature is unavailable"),
        ("when /tmp first held the file", "server /tmp first held the whole file"),
        ("the time from then to the failure", "s from then to the failure"),
        ("no 'Signed data' line", "'Signed data' line stamped unavailable"),
        ("the 'Request:' timestamp", f"'Request:' line stamped {REQUEST_STAMP}"),
    ):
        lines = [line for line in output.splitlines() if text in line]
        check(f"failed signing logs {label}", bool(lines), str(lines or text))
    check(
        "failed signing: nothing reported as signed or as a signature returning",
        "bytes signed in" not in output and "signature returning" not in output,
        "no line claims a signature",
    )
    check(
        "failed signing: diagnostics collected",
        (logs / "resources.txt").is_file(),
        f"{logs.name}/resources.txt",
    )


def check_failed_samples(work: Path) -> None:
    """Samples that fail as the upload ends widen the reported bounds."""
    status, _, output = run_passing(
        work, work / "gap-logs", large=LARGE_BYTES, stub="STUB_FAILED_SAMPLES"
    )
    check("failed samples: passes", status == 0, passed(status, output))
    lines = [line for line in output.splitlines() if "which lies between" in line]
    bounds = lines[0].split("which lies between ")[1].split() if lines else []
    gap = int(bounds[2]) - int(bounds[0]) if len(bounds) > 2 else -1
    check(
        "failed samples: the bounds span the failed samples' time",
        gap >= FAILED_SAMPLES * FAILED_SAMPLE_DELAY,
        f"{gap} s between the bounds, {FAILED_SAMPLES} samples failed\n"
        + str(lines or output),
    )
    check(
        "failed samples: no claim of one sampling period",
        "one sampling period" not in output,
        "no fixed error bound claimed",
    )


def check_partial_payload(work: Path) -> None:
    """A /tmp total over the file's size does not end the upload early."""
    status, _, output = run_passing(
        work, work / "partial-logs", large=LARGE_BYTES, stub="STUB_PARTIAL_PAYLOAD"
    )
    check("partial upload: passes", status == 0, passed(status, output))
    lines = [line for line in output.splitlines() if "first held the whole" in line]
    words = lines[0].split("first held the whole file ")[1].split() if lines else []
    full = int(words[0]) if words else -1
    check(
        "partial upload: the whole file is seen only once the upload has it",
        full >= PARTIAL_DELAY,
        f"first held at {full} s, the upload a byte short for {PARTIAL_DELAY} s\n"
        + str(lines or output),
    )


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

        check_passing(work)
        check_late_sample(work)
        check_failed_signing(work)
        check_failed_samples(work)
        check_partial_payload(work)

    if FAILURES:
        print(f"\n{len(FAILURES)} FAILED")
        sys.exit(1)
    print("\nall checks passed")


if __name__ == "__main__":
    main()
