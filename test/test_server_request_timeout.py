# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Test for the server's request-timeout option (patch 25).
#
# A request child may spend CHILD_TIMEOUT_SECS, an hour, on a request,
# timed from its arrival (patch 20). That was a constant, so a file
# taking longer to upload, hash and sign could not be signed at all.
# The [server] request-timeout option now sets the bound, in seconds,
# and defaults to the hour.
#
# The configuration checks read real server.conf files through
# ServerConfiguration, and start the server's main() on the refused
# ones. The timing checks run the real request_handling_child() and
# read_request() in a forked child over a fake bridge connection, as
# test_server_request_alarm.py does, with the bounds scaled to seconds.
#
# Run inside the sigul server image:
#   python3 test/test_server_request_timeout.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# server is upstream code this repository only patches, and ships no
# type stubs, so its members are untyped by nature.

import logging
import os
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

SIGUL_LIB = os.environ.get("SIGUL_LIB", "/usr/share/sigul")
sys.path.insert(0, SIGUL_LIB)

import server  # noqa: E402
import utils  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(server, "_request_timeout_secs")

HOUR = 60 * 60
# The scaled bounds. A request gets SHORT or LONG seconds; the other of
# the two is then the idle bound, so each check tells them apart.
SHORT = 2
LONG = 8
# What the server refuses: nothing, zero, a negative number, a
# fraction, a word, and one more than signal.alarm() can arm.
REFUSED = ["", "0", "-5", "1.5", "an hour", "2147483648"]


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def _write_conf(directory: str, option: str | None) -> str:
    """Write a server.conf holding only what the server cannot default
    - with the empty database file it insists on - and a
    request-timeout line when option is not None."""
    path = os.path.join(directory, "server.conf")
    database = os.path.join(directory, "server.sqlite")
    with open(database, "w"):
        pass
    lines = ["[server]", "bridge-hostname: bridge"]
    if option is not None:
        lines.append(f"request-timeout: {option}")
    lines += ["[database]", f"database-path: {database}"]
    lines += ["[daemon]", "unix-user:", "unix-group:"]
    lines += ["[nss]", f"nss-dir: {directory}", "nss-password: unused"]
    with open(path, "w") as f:
        _ = f.write("\n".join(lines) + "\n")
    return path


def _configured(option: str | None) -> tuple[int | None, str]:
    """Read a server.conf; return its request timeout, or the error."""
    with tempfile.TemporaryDirectory() as directory:
        try:
            config = server.ServerConfiguration(_write_conf(directory, option))
        except utils.ConfigurationError as e:
            return None, f"{e}"
        return getattr(config, "request_timeout", None), ""


def test_default_is_the_hour() -> None:
    timeout, error = _configured(None)
    check(
        "a server.conf without request-timeout bounds a request at the hour",
        timeout == HOUR and server.CHILD_TIMEOUT_SECS == HOUR,
        f"request timeout {timeout}, CHILD_TIMEOUT_SECS "
        + f"{server.CHILD_TIMEOUT_SECS} {error}",
    )


def test_option_is_read() -> None:
    for option in ("21600", "1", "2147483647"):
        timeout, error = _configured(option)
        check(
            f"request-timeout: {option} is read",
            timeout == int(option),
            f"request timeout {timeout} {error}",
        )


def test_bad_value_is_refused() -> None:
    for option in REFUSED:
        timeout, error = _configured(option)
        check(
            f"request-timeout: {option!r} is refused, by name",
            timeout is None and "request-timeout must be" in error,
            f"request timeout {timeout}, error {error!r}",
        )


def test_bad_value_stops_the_server() -> None:
    # main() itself: the server exits as it reads its configuration,
    # before it forks a child or dials the bridge, and says why.
    program = (
        "import sys; sys.path.insert(0, sys.argv.pop(1)); import server; server.main()"
    )
    for option in ("0", "an hour"):
        with tempfile.TemporaryDirectory() as directory:
            command = [sys.executable, "-c", program, SIGUL_LIB]
            command += ["-c", _write_conf(directory, option)]
            command += ["--internal-log-dir", directory]
            command += ["--internal-pid-dir", directory]
            try:
                result = subprocess.run(
                    command, capture_output=True, text=True, timeout=60
                )
                status, said = result.returncode, result.stderr.strip()
            except subprocess.TimeoutExpired:
                status, said = -1, "still running after 60 s"
        check(
            f"request-timeout: {option!r} stops the server at start",
            status == 1 and "request-timeout must be" in said,
            f"exit {status}, stderr {said[-120:]!r}",
        )


class FakeBridge:
    """The request child's bridge connection, with scripted timing.

    The child's first read waits `idle` seconds for a request, as a child
    waits for the bridge to hand it a client; with request=False no
    request ever comes. The next read is the request itself: it takes
    `work` seconds, notes that it got that far, then ends the request.
    """

    def __init__(self, idle: float, work: float, request: bool, done: str) -> None:
        self.idle: float = idle
        self.work: float = work
        self.request: bool = request
        self.done: str = done
        self.reads: int = 0

    def outer_read(self, _size: int) -> bytes:
        self.reads += 1
        if self.reads == 1:
            time.sleep(self.idle if self.request else HOUR)
            return utils.u32_pack(utils.protocol_version)
        time.sleep(self.work)
        with open(self.done, "w") as f:
            _ = f.write("done")
        raise EOFError()

    def outer_close(self) -> None:
        pass


def _no_op(_config: object) -> None:
    return None


def _run(
    request_timeout: int,
    idle_bound: int,
    idle: float,
    work: float,
    request: bool = True,
) -> tuple[int, float, bool, str]:
    """Fork a request child; return its exit status, run time, whether
    its request got to the end, and what it logged."""
    directory = tempfile.mkdtemp()
    done = os.path.join(directory, "done")
    log = os.path.join(directory, "log")
    started = time.monotonic()
    pid = os.fork()
    if pid == 0:
        status = 2
        try:
            logging.basicConfig(filename=log, level=logging.INFO, force=True)
            server.CHILD_TIMEOUT_SECS = idle_bound
            server.utils.nss_init = _no_op
            server.server_common.db_open = _no_op

            def bridge(*_args: object) -> FakeBridge:
                return FakeBridge(idle, work, request, done)

            server.double_tls.DoubleTLSClient = bridge
            config = SimpleNamespace(
                daemon_uid=None,
                daemon_gid=None,
                bridge_hostname="bridge",
                bridge_port=0,
                server_cert_nickname="server",
                request_timeout=request_timeout,
            )
            status = server._run_request_child(config)
            logging.shutdown()
        finally:
            os._exit(status)
    _, wait_status = os.waitpid(pid, 0)
    elapsed = time.monotonic() - started
    with open(log) as f:
        logged = f.read()
    return os.waitstatus_to_exitcode(wait_status), elapsed, os.path.exists(done), logged


def test_overrun_is_killed_on_the_option() -> None:
    # The idle bound is LONG and the request would outlast it too: only
    # request-timeout can be what ends it at SHORT.
    status, elapsed, done, logged = _run(SHORT, LONG, idle=0.1, work=LONG * 2)
    check(
        "a request overrunning request-timeout is killed on time",
        not done and SHORT <= elapsed < SHORT * 2,
        f"after {elapsed:.1f}s, request-timeout {SHORT}s, idle bound {LONG}s",
    )
    check(
        "... and reported as a timeout",
        status == server._CHILD_TIMEOUT and "timed out" in logged,
        f"exit {status} (timeout is {server._CHILD_TIMEOUT}), "
        + f"log: {logged.strip()[-80:]!r}",
    )


def test_request_within_the_option_finishes() -> None:
    # Longer than the idle bound, which was every request's bound
    # before the option, and shorter than request-timeout.
    status, elapsed, done, _ = _run(LONG, SHORT, idle=0.1, work=SHORT * 2)
    outcome = "finished" if done else "cut off"
    check(
        "a request within a raised request-timeout finishes",
        done and status == 0,
        f"{outcome} after {elapsed:.1f}s, request-timeout {LONG}s, "
        + f"idle bound {SHORT}s, exit {status}",
    )


def test_idle_child_keeps_its_own_bound() -> None:
    # No request comes. The child is replaced on the idle bound, not on
    # a request-timeout four times longer, and quietly.
    status, elapsed, _, logged = _run(LONG, SHORT, idle=0, work=0, request=False)
    check(
        "an idle child is replaced on its idle bound, not request-timeout",
        status == 0 and elapsed < SHORT * 2 and "timed out" not in logged,
        f"exit {status} after {elapsed:.1f}s, idle bound {SHORT}s, "
        + f"request-timeout {LONG}s",
    )
    # A request arriving after longer than request-timeout: the wait
    # for it is not charged to the option either.
    status, elapsed, done, _ = _run(SHORT, LONG, idle=SHORT * 1.5, work=0.2)
    outcome = "finished" if done else "cut off"
    check(
        "a child may wait for its request longer than request-timeout",
        done and status == 0,
        f"{outcome} after {elapsed:.1f}s, request-timeout {SHORT}s, "
        + f"idle bound {LONG}s, exit {status}",
    )


def main() -> int:
    print("Server request-timeout tests")
    print(f"server: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    if not PATCHED:
        # Without patch 25 the option is ignored: nothing reads it.
        check("the server has the request-timeout option", False, "patch 25 missing")
    test_default_is_the_hour()
    test_option_is_read()
    test_bad_value_is_refused()
    test_bad_value_stops_the_server()
    test_overrun_is_killed_on_the_option()
    test_request_within_the_option_finishes()
    test_idle_child_keeps_its_own_bound()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("request-timeout bounds a request from its arrival")
    return 0


if __name__ == "__main__":
    sys.exit(main())
