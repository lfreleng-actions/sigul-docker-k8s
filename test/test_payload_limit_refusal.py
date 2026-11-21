# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for the refusal of an over-limit payload (patch 26).
#
# The server reads a payload's size before the payload and refuses one
# over its limit without storing it. It used to say so only in its own
# log: it sent no reply and closed. The client meanwhile wrote the whole
# file to a connection nobody read, then met the end of its inner TLS
# session and reported
#
#     ERROR: I/O error: Unexpected EOF in NSPR
#
# which reads as a network fault, and for a file gigabytes over the
# limit it took as long as reading the file (#160). Which I/O error it
# is depends on timing: a write that fails before the upload ends is
# reported as `I/O error: BrokenPipeError(...)` or
# `I/O error: ConnectionResetError(...)` instead.
#
# The checks start the real bridge and server daemons on loopback
# ports, over a throwaway NSS database, and run the real client against
# them, once per case:
#
# - a file one byte over the limit, refused after the bridge has
#   forwarded all of it: the client exits non-zero with an error naming
#   the payload's size and the limit;
# - a file 2 GiB over it, refused mid-upload: the same error, promptly -
#   the client stops sending when the refusal arrives, however much is
#   left;
# - neither refusal writes to the server's temporary directory, whose
#   modification time would show a file made and removed; an accepted
#   payload does move it, so the probe is known to see one;
# - the server logs each refusal as it did before;
# - a file exactly at the limit is accepted, and the request after the
#   refusals gets an ordinary reply. That request is rejected for its
#   user name, which the server checks without GnuPG or a key;
# - a client that connects, announces a file over the limit and then
#   sends nothing: the bridge relays the refusal all the same, serves
#   the next client while that one is still connected, and the silent
#   client reports the limit once it looks;
# - the bridge's buffer, driven directly over loopback sockets: a
#   client that stops part-way through a frame holds up neither the
#   server's reply nor the bounded wait for it to close; a frame the
#   refused client announces is dropped as it arrives, not kept; and a
#   TLS record that arrives a byte at a time neither carries that wait
#   past its deadline nor, while a payload is copied, holds up the
#   server's reply, moves the idle deadline or escapes the throughput
#   floor;
# - the client's reading of a refusal: the reply is unauthenticated, so
#   nothing in its message reaches the terminal but printable ASCII;
# - the bridge's copy of a payload, driven directly: one the client
#   sends a byte to a frame reaches the server 4096 bytes at a time;
# - the client's wait on its pipe, driven directly: it takes a
#   descriptor numbered over 1023, which select() refuses;
# - the server's refusal, driven directly: the reason is in the log
#   even when the request alarm ends the wait that follows the reply;
# - the server's other limit, driven directly: a payload it would keep
#   in memory is refused by max-memory-payload-size, and one at that
#   limit is read. Only a request whose operation the server does not
#   know has such a payload, and the bridge turns one away itself
#   (`Unknown op value`), so no client can send one through it;
# - mixed versions, since a client outside these images may lag: the
#   same code with patch 26 taken out again serves as the older peer.
#   An older client refused by the patched bridge and server, and a
#   patched client refused by an older bridge and server, each still
#   fail with an I/O error, no later than an older client did against
#   older peers, and leave the bridge serving the next request.
#
# Which of the two paths patch 26 adds a refusal takes is a race
# between the bridge and the server, and for a silent client a matter
# of when it stops. So the daemons and the client run through this
# file's own launcher (`--component`), which imports the real module
# and puts one of its steps in order before calling its main():
#
# - the server holds a refusal until the bridge has forwarded the whole
#   payload, while the test asks for that: the after-the-upload path;
# - a client the test names waits before the first write of its
#   payload until the test releases it: the silent client.
#
# Nothing else is changed, and nothing is where patch 26 is absent.
#
# Without the patch the first two cases fail with an I/O error as above.
#
# Run inside the sigul server image, which has every component's code,
# python-nss, certutil and patch, with this repository's patches/
# beside test/ (or PAYLOAD_LIMIT_PATCH naming patch 26):
#   python3 test/test_payload_limit_refusal.py

# pyright: reportAny=false, reportUnknownMemberType=false
# pyright: reportUnknownVariableType=false, reportUnknownArgumentType=false
#
# The launcher wraps functions of upstream modules this repository only
# patches, which ship no type stubs.

import fcntl
import importlib
import logging
import os
import resource
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from io import StringIO
from types import ModuleType, SimpleNamespace
from typing import Protocol, cast

SIGUL_LIB = os.environ.get("SIGUL_LIB", "/usr/share/sigul")

# Patch 26 itself, which the mixed-version cases take out of a copy of
# the code under test to get an older peer.
PATCH = os.environ.get(
    "PAYLOAD_LIMIT_PATCH",
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        os.pardir,
        "patches",
        "26-fix-payload-limit-refusal.patch",
    ),
)

FAILURES: list[str] = []

# Under one 4096-byte write, so that a file one byte over still fits in
# one.
LIMIT = 1024
FAR_OVER = 2 * 1024 * 1024 * 1024
SILENT_OVER = 1024 * 1024

# The limit on a payload the server keeps in memory, in the request
# driven directly: under LIMIT, so that the limit a refusal names shows
# which of the two refused it.
MEMORY_LIMIT = 512

# How long the client may take over the far-over file. A refusal takes
# a fraction of a second whatever the size; reading 2 GiB to the end,
# as the unpatched client does, takes longer than this.
PROMPT_SECONDS = 10

# Bounds every wait, so a wedged daemon fails the run rather than
# hanging it.
START_SECONDS = 30
REQUEST_SECONDS = 120

# How long a line may take to reach a daemon's log. The bridge writes
# its line as it relays a refusal, which a silent client has yet to
# read.
LOG_SECONDS = 15

# How long the next client may wait for a bridge that has refused a
# silent one. The bridge gives the silent client 5 s to close; without
# that bound it waited out its idle deadline, 120 s.
SLOT_SECONDS = 20

# How long the launcher holds a step it has been asked to order, should
# what it waits for never come.
HOLD_SECONDS = 60

# The idle deadline of the buffers driven directly: long enough that a
# wait which ran to it stands out. Whole seconds: the buffer converts
# it with nss.io.seconds_to_interval.
IDLE_SECONDS = 6

# How often a byte of a TLS record sent a byte at a time arrives; an
# idle deadline short enough to pass while one is still arriving; and
# a throughput floor, in bytes a second over a window of seconds, that
# such a record is far below.
DRIP_SECONDS = 0.25
SHORT_IDLE_SECONDS = 2
FLOOR = 4096
FLOOR_SECONDS = 1

# A frame a refused client announces and sends while the bridge waits
# for it to close, and how far the test's peak memory may rise while
# the bridge's buffer drops it: far less than the frame.
ANNOUNCED_FRAME = 64 * 1024 * 1024
KEPT_LIMIT = 16 * 1024 * 1024

# A payload the client frames a byte at a time, and longer than the
# 4096 bytes the bridge sends the server at once.
SMALL_FRAMES = 5000

# The lowest descriptor number select() refuses: FD_SETSIZE.
HIGH_DESCRIPTOR = 1024

# How much longer than an older client against older peers a refusal
# may take with one side patched, before it counts as later: the two
# are timed one after the other on a shared runner. The patched side
# is in fact quicker, or adds nothing.
LATER_SECONDS = 10

# Names the directory, shared with the daemons, that holds the two
# files below; and, for one client, the file whose arrival releases it.
ORDER_DIR_ENV = "PAYLOAD_LIMIT_TEST_ORDER_DIR"
RELEASE_ENV = "PAYLOAD_LIMIT_TEST_RELEASE"
HOLD_REFUSAL = "hold-refusal"
FORWARDED = "forwarded"


class Buffer(Protocol):
    """The slice of double_tls.OuterBuffer these checks drive."""

    def read(self, buf_size: int) -> bytes: ...

    def read_unless(self, buf_size: int, other: object) -> bytes | None: ...

    def discard_input(self, deadline: float) -> None: ...


NICKNAME = "payload-limit-test"
CA_NICKNAME = "payload-limit-test-ca"

REFUSAL = "The payload is larger than the server accepts"
EARLY_REPLY = "The server replied before the request payload ended"
SERVER_REFUSAL = "Invalid request: Payload too large"
# What the client logs for every error of its transport: an EOF or a
# reset in NSPR, or an IOError of a write to its forwarding child.
IO_ERROR = "I/O error: "
ORDINARY_REPLY = "Error: Authentication failed"


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def _touch(path: str) -> None:
    os.close(os.open(path, os.O_CREAT | os.O_WRONLY, 0o600))


def _wait_for_file(path: str, seconds: float) -> bool:
    deadline = time.monotonic() + seconds
    while not os.path.exists(path):
        if time.monotonic() > deadline:
            return False
        time.sleep(0.01)
    return True


def _order_bridge(module: object, order_dir: str) -> None:
    """Have the bridge say when it has forwarded a whole payload."""
    name = "copy_request_payload"
    copy = cast("Callable[[object], None] | None", getattr(module, name, None))
    if copy is None:
        return

    def copy_and_tell(conn: object) -> None:
        copy(conn)
        if os.path.exists(os.path.join(order_dir, HOLD_REFUSAL)):
            _touch(os.path.join(order_dir, FORWARDED))

    setattr(module, name, copy_and_tell)


def _order_server(module: object, order_dir: str) -> None:
    """Have the server refuse only once the bridge has said so."""
    connection = cast(type, vars(module)["ServersConnection"])
    name = "_ServersConnection__refuse_payload"
    refuse = cast(
        "Callable[[object, int, int], None] | None",
        getattr(connection, name, None),
    )
    if refuse is None:
        return

    def refuse_in_turn(self: object, payload_size: int, limit: int) -> None:
        if os.path.exists(os.path.join(order_dir, HOLD_REFUSAL)):
            _ = _wait_for_file(os.path.join(order_dir, FORWARDED), HOLD_SECONDS)
        refuse(self, payload_size, limit)

    setattr(connection, name, refuse_in_turn)


def _order_client(module: object, release: str) -> None:
    """Have the client wait for release before it first sends payload.

    The client looks for a reply before each write of its payload, the
    first included, so waiting inside that look leaves it connected,
    with its payload announced and none of it sent.
    """
    transport = cast(type, vars(vars(module)["double_tls"])["DoubleTLSClient"])
    name = "outer_input_pending"
    pending = cast("Callable[[object], bool] | None", getattr(transport, name, None))
    if pending is None:
        return
    waited: list[bool] = []

    def pending_once_released(self: object) -> bool:
        if not waited:
            waited.append(_wait_for_file(release, HOLD_SECONDS))
        return pending(self)

    setattr(transport, name, pending_once_released)


def run_component(name: str, arguments: list[str]) -> None:
    """Run a Sigul component's main(), with the ordering it was asked for."""
    sys.path.insert(0, SIGUL_LIB)
    sys.argv = [os.path.join(SIGUL_LIB, f"{name}.py"), *arguments]
    module = importlib.import_module(name)
    order_dir = os.environ.get(ORDER_DIR_ENV)
    release = os.environ.get(RELEASE_ENV)
    if name == "bridge" and order_dir:
        _order_bridge(module, order_dir)
    elif name == "server" and order_dir:
        _order_server(module, order_dir)
    elif name == "client" and release:
        _order_client(module, release)
    cast("Callable[[], None]", vars(module)["main"])()


def _free_ports() -> tuple[int, int]:
    """Two loopback ports, free and different.

    Both are bound before either is released: a port released first
    could be handed out again for the second.
    """
    with socket.socket() as first, socket.socket() as second:
        first.bind(("127.0.0.1", 0))
        second.bind(("127.0.0.1", 0))
        ports = [
            cast(tuple[str, int], probe.getsockname())[1] for probe in (first, second)
        ]
    return ports[0], ports[1]


def _make_nss_db(directory: str) -> None:
    """A CA and one leaf certificate, which every component presents.

    The bridge, the server and the client each need a certificate the
    others trust, and nothing here depends on their being different.
    """
    noise = os.path.join(directory, "noise")
    with open(noise, "wb") as f:
        _ = f.write(os.urandom(2048))
    db = f"sql:{directory}"
    _ = subprocess.run(["certutil", "-N", "-d", db, "--empty-password"], check=True)
    _ = subprocess.run(
        [
            "certutil", "-S", "-d", db, "-n", CA_NICKNAME,
            "-s", "CN=Payload Limit Test CA", "-x", "-t", "CT,C,C", "-m", "1",
            "-v", "1", "-g", "2048", "-z", noise,
            "--keyUsage", "certSigning,crlSigning", "-2",
        ],
        input=b"y\n-1\ny\n",
        check=True,
        capture_output=True,
    )  # fmt: skip
    _ = subprocess.run(
        [
            "certutil", "-S", "-d", db, "-n", NICKNAME,
            "-s", "CN=localhost", "-c", CA_NICKNAME, "-t", "u,u,u", "-m", "2",
            "-v", "1", "-g", "2048", "-z", noise,
            "--keyUsage", "digitalSignature,keyEncipherment",
            "--extKeyUsage", "serverAuth,clientAuth",
            "-8", "localhost",
        ],
        check=True,
        capture_output=True,
    )  # fmt: skip


class Stack:
    """A bridge and a server, running, and the means to run a client.

    lib is the Sigul code the bridge and the server run, and a client
    too unless it is given another.
    """

    def __init__(self, lib: str = SIGUL_LIB) -> None:
        self.lib: str = lib
        self.work: str = tempfile.mkdtemp(prefix="sigul-payload-limit-")
        self.server_tmp: str = self._dir("tmp")
        self.order_dir: str = self._dir("order")
        self.daemons: list[subprocess.Popen[bytes]] = []
        with open(self.path("passphrase"), "wb") as f:
            _ = f.write(b"passphrase\0")
        nss_dir = self._dir("nss")
        _make_nss_db(nss_dir)
        client_port, server_port = _free_ports()
        nss = ["[nss]", f"nss-dir: {nss_dir}", "nss-password:"]
        daemon = ["[daemon]", "unix-user:", "unix-group:"]
        self._write(
            "bridge.conf",
            [
                "[bridge]",
                f"bridge-cert-nickname: {NICKNAME}",
                f"client-listen-port: {client_port}",
                f"server-listen-port: {server_port}",
                "required-fas-group:",
                *daemon,
                *nss,
            ],
        )
        # The user name check is strict, as the chart's per-client
        # certificates require, so that a request claiming another user
        # is answered without the server needing a key or GnuPG.
        self._write(
            "server.conf",
            [
                "[server]",
                "bridge-hostname: localhost",
                f"bridge-port: {server_port}",
                f"server-cert-nickname: {NICKNAME}",
                f"max-file-payload-size: {LIMIT}",
                "lenient-username-check: no",
                "[database]",
                f"database-path: {self.path('server.sqlite')}",
                "[gnupg]",
                f"gnupg-home: {self.path('gnupg')}",
                "[keys]",
                f"keys-storage: {self._dir('keys')}",
                *daemon,
                *nss,
            ],
        )
        self._write(
            "client.conf",
            [
                "[client]",
                "bridge-hostname: localhost",
                f"bridge-port: {client_port}",
                "server-hostname: localhost",
                f"client-cert-nickname: {NICKNAME}",
                "user-name: not-the-certificate-name",
                *nss,
            ],
        )

    def path(self, name: str) -> str:
        return os.path.join(self.work, name)

    def _dir(self, name: str) -> str:
        os.mkdir(self.path(name))
        return self.path(name)

    def _write(self, name: str, lines: list[str]) -> None:
        with open(self.path(name), "w", encoding="utf-8") as f:
            _ = f.write("\n".join(lines) + "\n")

    def _component(self, name: str, config: str) -> list[str]:
        return [sys.executable, os.path.join(self.lib, name), "-c", self.path(config)]

    def _launched(self, component: str) -> list[str]:
        """The command for a component run through this file's launcher."""
        config = self.path(f"{component}.conf")
        return [sys.executable, __file__, "--component", component, "-c", config]

    def _start(self, component: str, env: dict[str, str]) -> None:
        """Start a daemon, and wait for the heartbeat it writes once up."""
        options = [
            "-v",
            "--internal-log-dir",
            self.work,
            "--internal-pid-dir",
            self.work,
        ]
        daemon = subprocess.Popen(
            self._launched(component) + options,
            env=dict(env, SIGUL_LIB=self.lib, **{ORDER_DIR_ENV: self.order_dir}),
        )
        self.daemons.append(daemon)
        deadline = time.monotonic() + START_SECONDS
        while not os.path.exists(self.path(f"sigul_{component}.heartbeat")):
            if time.monotonic() > deadline or daemon.poll() is not None:
                raise RuntimeError(
                    f"the {component} did not start: {self.log(component)}"
                )
            time.sleep(0.1)

    def start(self) -> None:
        """Start the bridge, then the server once the bridge listens."""
        _ = subprocess.run(
            self._component("server_create_db.py", "server.conf"), check=True
        )
        # The bridge writes its heartbeat once both ports are listening.
        self._start("bridge", dict(os.environ))
        self._start("server", dict(os.environ, TMPDIR=self.server_tmp))

    def stop(self) -> None:
        for daemon in self.daemons:
            daemon.terminate()
        for daemon in self.daemons:
            try:
                _ = daemon.wait(10)
            except subprocess.TimeoutExpired:
                daemon.kill()

    def log(self, component: str) -> str:
        try:
            with open(self.path(f"sigul_{component}.log"), encoding="utf-8") as f:
                return f.read()
        except OSError as e:
            return f"(no log: {e})"

    def wait_for_log(self, component: str, text: str, count: int) -> int:
        """How often text is in a daemon's log, once that is count or more.

        Gives up, and returns the count there is, after LOG_SECONDS.
        """
        deadline = time.monotonic() + LOG_SECONDS
        while True:
            found = self.log(component).count(text)
            if found >= count or time.monotonic() > deadline:
                return found
            time.sleep(0.1)

    def start_client(
        self, size: int, release: str | None = None, lib: str | None = None
    ) -> tuple[subprocess.Popen[bytes], float]:
        """Start a request for a signature of a file of size bytes.

        Return the client, and when it started. The file is sparse, so
        its size costs no disk. If release is not None the client waits
        for that file before it first sends any of its payload. The
        client runs the code in lib, or the stack's own.
        """
        for daemon in self.daemons:
            if daemon.poll() is not None:
                raise RuntimeError(f"a daemon exited with status {daemon.returncode}")
        payload = self.path(f"payload-{size}.bin")
        with open(payload, "wb") as f:
            _ = f.truncate(size)
        env = dict(os.environ, SIGUL_LIB=lib or self.lib)
        if release is not None:
            env[RELEASE_ENV] = release
        with open(self.path("passphrase"), "rb") as passphrase:
            client = subprocess.Popen(
                self._launched("client")
                + ["--batch", "sign-data", "-o", self.path("payload.sig")]
                + ["no-such-key", payload],
                stdin=passphrase,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
            )
        return client, time.monotonic()

    def finish_client(
        self,
        started: tuple[subprocess.Popen[bytes], float],
        seconds: float = REQUEST_SECONDS,
    ) -> tuple[int, str, float]:
        """Wait for a client from start_client().

        Return its exit status, what it printed, and how long it took.
        A client still running after seconds is killed, and reported
        with the status 124 a timeout would give it.
        """
        client, since = started
        try:
            out, err = client.communicate(timeout=seconds)
        except subprocess.TimeoutExpired:
            client.kill()
            out, err = client.communicate()
            return 124, f"(killed after {seconds} s)", time.monotonic() - since
        elapsed = time.monotonic() - since
        printed = (out + err).decode("utf-8", "replace").strip()
        return client.returncode, printed, elapsed

    def sign_data(
        self, size: int, seconds: float = REQUEST_SECONDS, lib: str | None = None
    ) -> tuple[int, str, float]:
        """Ask for a signature of a file of size bytes, and wait for it."""
        return self.finish_client(self.start_client(size, lib=lib), seconds)

    def server_tmp_state(self) -> tuple[int, list[str]]:
        """What shows whether the server's temporary directory was used."""
        return os.stat(self.server_tmp).st_mtime_ns, os.listdir(self.server_tmp)


def _names_the_limit(status: int, printed: str, size: int) -> bool:
    return (
        status not in (0, 124, 137)
        and REFUSAL in printed
        and f"payload of {size} bytes, limit {LIMIT} bytes" in printed
    )


def test_refused_after_upload(stack: Stack) -> None:
    size = LIMIT + 1
    relayed_before = stack.log("bridge").count(EARLY_REPLY)
    hold = os.path.join(stack.order_dir, HOLD_REFUSAL)
    forwarded = os.path.join(stack.order_dir, FORWARDED)
    _touch(hold)
    try:
        status, printed, elapsed = stack.sign_data(size)
    finally:
        os.unlink(hold)
    check(
        "a file one byte over the limit: the client names the size and the limit",
        _names_the_limit(status, printed, size),
        f"exit {status} after {elapsed:.1f}s: {printed!r}",
    )
    # The bridge logs an early reply before it relays one, so a count
    # read after the client has reported cannot miss it.
    early = stack.log("bridge").count(EARLY_REPLY) - relayed_before
    check(
        "... refused after the bridge had forwarded all of it",
        os.path.exists(forwarded) and early == 0,
        f"the bridge {'forwarded' if os.path.exists(forwarded) else 'did not forward'}"
        + f" the payload first, and logged {early} early replies",
    )
    if os.path.exists(forwarded):
        os.unlink(forwarded)


def test_far_over(stack: Stack) -> None:
    size = LIMIT + FAR_OVER
    relayed_before = stack.log("bridge").count(EARLY_REPLY)
    status, printed, elapsed = stack.sign_data(size)
    check(
        "a file 2 GiB over the limit: the client names the size and the limit",
        _names_the_limit(status, printed, size),
        f"exit {status}: {printed!r}",
    )
    check(
        "... and stops sending when it is refused",
        elapsed < PROMPT_SECONDS,
        f"after {elapsed:.1f}s, bound {PROMPT_SECONDS}s",
    )
    relayed = stack.log("bridge").count(EARLY_REPLY) - relayed_before
    check(
        "... because the bridge relayed the refusal during the upload",
        relayed == 1,
        f"the bridge logged {relayed} early replies",
    )


def test_refusals_leave_tmp_alone(stack: Stack, before: tuple[int, list[str]]) -> None:
    refusals = stack.wait_for_log("server", SERVER_REFUSAL, 2)
    check(
        "the server logged each refusal as before",
        refusals == 2,
        f"{refusals} lines of {SERVER_REFUSAL!r}",
    )
    after = stack.server_tmp_state()
    check(
        "no refused payload was written to the server's temporary directory",
        after == before and after[1] == [],
        f"modified {before[0]} -> {after[0]}, holding {after[1]}",
    )


def test_at_the_limit(stack: Stack, before: tuple[int, list[str]]) -> None:
    status, printed, elapsed = stack.sign_data(LIMIT)
    check(
        "a file at the limit is accepted, and answered in the ordinary way",
        status == 1 and printed == "Error: Authentication failed",
        f"exit {status} after {elapsed:.1f}s: {printed!r}",
    )
    after = stack.server_tmp_state()
    check(
        "... and its payload did go through the server's temporary directory",
        after[0] != before[0],
        f"modified {before[0]} -> {after[0]}",
    )


def test_silent_client(stack: Stack) -> None:
    size = LIMIT + SILENT_OVER
    relayed_before = stack.log("bridge").count(EARLY_REPLY)
    release = stack.path("release")
    silent = stack.start_client(size, release)
    try:
        relayed = stack.wait_for_log("bridge", EARLY_REPLY, relayed_before + 1)
        check(
            "a client that sends none of its payload: the bridge relays the refusal",
            relayed == relayed_before + 1 and silent[0].poll() is None,
            f"the bridge logged {relayed - relayed_before} early replies"
            + f" within {LOG_SECONDS}s, with the client still connected",
        )
        if relayed == relayed_before + 1:
            status, printed, elapsed = stack.sign_data(LIMIT, 2 * SLOT_SECONDS)
            check(
                "... and serves the next client while that one stays silent",
                status == 1
                and printed == "Error: Authentication failed"
                and elapsed < SLOT_SECONDS
                and silent[0].poll() is None,
                f"exit {status} after {elapsed:.1f}s, bound {SLOT_SECONDS}s: {printed!r}",
            )
    finally:
        _touch(release)
    status, printed, _ = stack.finish_client(silent)
    check(
        "... which names the size and the limit once it looks",
        _names_the_limit(status, printed, size),
        f"exit {status}: {printed!r}",
    )


def _nspr_pair(io: ModuleType) -> tuple[socket.socket, object]:
    """A loopback connection: a plain socket, and the NSPR socket it reached."""
    listener = io.Socket(io.PR_AF_INET)
    listener.set_socket_option(io.PR_SockOpt_Reuseaddr, True)
    listener.bind(io.NetworkAddress(io.PR_IpAddrLoopback, 0))
    listener.listen(1)
    peer = socket.create_connection(("127.0.0.1", listener.get_sock_name().port))
    accepted = cast(object, listener.accept()[0])
    listener.close()
    return peer, accepted


def test_part_of_a_frame() -> None:
    """The bridge's buffer, over loopback sockets, with a frame cut short.

    The silent client above stops between frames. One that stops inside
    a frame must not hold the bridge either.
    """
    sys.path.insert(0, SIGUL_LIB)
    io = importlib.import_module("nss.io")
    outer_buffer = vars(importlib.import_module("double_tls"))["OuterBuffer"]
    if not hasattr(outer_buffer, "read_unless"):
        check("part of a frame does not hold up the refusal", False, "no patch 26")
        return
    client_peer, client_sock = _nspr_pair(io)
    server_peer, server_sock = _nspr_pair(io)
    client_buf = cast(Buffer, outer_buffer(client_sock, idle_timeout=IDLE_SECONDS))
    server_buf = cast(Buffer, outer_buffer(server_sock, idle_timeout=IDLE_SECONDS))
    frame = bytes(range(100))
    header = len(frame).to_bytes(4, "big")
    try:
        client_peer.sendall(header + frame[:40])
        reply = threading.Timer(0.5, server_peer.sendall, [b"\0\0\0\1r"])
        reply.start()
        started = time.monotonic()
        data = client_buf.read_unless(4096, server_buf)
        elapsed = time.monotonic() - started
        reply.join()
        check(
            "part of a frame from the client does not hold up the server's reply",
            data is None and elapsed < IDLE_SECONDS / 2,
            f"read_unless() returned {data!r} after {elapsed:.1f}s,"
            + f" idle deadline {IDLE_SECONDS}s",
        )
        more = threading.Timer(0.3, client_peer.sendall, [frame[40:50]])
        more.start()
        started = time.monotonic()
        client_buf.discard_input(started + 1)
        elapsed = time.monotonic() - started
        more.join()
        check(
            "... nor, with a little more of it, the bounded wait for it to close",
            0.9 < elapsed < IDLE_SECONDS / 2,
            f"discard_input() returned after {elapsed:.1f}s of the 1s allowed",
        )
    finally:
        client_peer.close()
        server_peer.close()


def test_announced_frame() -> None:
    """A frame the refused client announces and sends is dropped, not kept.

    A frame may announce up to 2 GiB. A bridge that kept one until it
    was whole, to drop it then, would hold all of it in memory.
    """
    sys.path.insert(0, SIGUL_LIB)
    io = importlib.import_module("nss.io")
    outer_buffer = vars(importlib.import_module("double_tls"))["OuterBuffer"]
    label = "a frame the refused client announces is dropped as it arrives"
    if not hasattr(outer_buffer, "discard_input"):
        check(label, False, "no patch 26")
        return
    peer, accepted = _nspr_pair(io)
    peer.settimeout(START_SECONDS)
    buf = cast(Buffer, outer_buffer(accepted, idle_timeout=IDLE_SECONDS))
    sent: list[int] = []

    def send() -> None:
        piece = bytes(65536)
        try:
            peer.sendall(ANNOUNCED_FRAME.to_bytes(4, "big"))
            for _ in range(ANNOUNCED_FRAME // len(piece)):
                peer.sendall(piece)
                sent.append(len(piece))
            peer.shutdown(socket.SHUT_WR)
        except OSError:
            # Reported below, as a frame that was not all sent.
            pass

    sender = threading.Thread(target=send)
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    started = time.monotonic()
    sender.start()
    try:
        buf.discard_input(started + START_SECONDS)
        elapsed = time.monotonic() - started
    finally:
        try:
            peer.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sender.join()
        peer.close()
    # ru_maxrss is in kibibytes on Linux.
    grown = (resource.getrusage(resource.RUSAGE_SELF).ru_maxrss - peak) * 1024
    check(
        label,
        sum(sent) == ANNOUNCED_FRAME
        and grown < KEPT_LIMIT
        and elapsed < START_SECONDS / 2,
        f"{sum(sent)} of {ANNOUNCED_FRAME} bytes sent and dropped in {elapsed:.1f}s,"
        + f" peak memory up {grown} bytes, limit {KEPT_LIMIT}",
    )


def _fresh_tls_record(
    port: int, accept: Callable[[], object]
) -> tuple[socket.socket, object, bytes]:
    """A TLS connection to the listener on port, and a record yet unsent.

    accept() returns the listener's socket for it, handshake done.
    Return the peer's plain socket, that socket, and one encrypted
    record of the peer's. The peer is Python's own TLS, over a memory
    buffer, so that the test decides how the record is cut up on its
    way.
    """
    peer = socket.create_connection(("127.0.0.1", port))
    peer.settimeout(START_SECONDS)
    # The peer checks no certificate: it is this test's own listener,
    # on loopback, and what is under test is the listener's side.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    tls = context.wrap_bio(incoming, outgoing)

    def handshake() -> None:
        try:
            while True:
                try:
                    tls.do_handshake()
                except ssl.SSLWantReadError:
                    peer.sendall(outgoing.read())
                    _ = incoming.write(peer.recv(65536))
                else:
                    peer.sendall(outgoing.read())
                    return
        except OSError:
            # Let the listener's side fail too, rather than wait.
            peer.close()
            raise

    greeting = threading.Thread(target=handshake)
    greeting.start()
    accepted = accept()
    greeting.join()
    _ = tls.write(bytes(1000))
    return peer, accepted, outgoing.read()


def _drip(peer: socket.socket, record: bytes, count: int) -> threading.Thread:
    """Start sending count bytes of record, one every DRIP_SECONDS."""

    def drip() -> None:
        try:
            for at in range(count):
                peer.sendall(record[at : at + 1])
                time.sleep(DRIP_SECONDS)
        except OSError:
            # The check that was waiting on these bytes has reported.
            pass

    slow = threading.Thread(target=drip)
    slow.start()
    return slow


def _timed(
    read: Callable[[], bytes | None], errors: tuple[type[Exception], ...]
) -> tuple[str, float]:
    """What read() did, by returning or by raising, and how long it took."""
    started = time.monotonic()
    try:
        said = f"returned {read()!r}"
    except errors as e:
        said = f"raised {type(e).__name__}"
    return said, time.monotonic() - started


def test_dripped_record(nss_dir: str) -> None:
    """The bridge's two new waits, over TLS, with a slow record.

    A receive with a timeout takes the whole timeout again for every
    read of a TLS record, so a wait that received that way would follow
    a record sent a byte at a time well past its deadline, deaf to the
    other peer meanwhile. Each wait gets a connection of its own, whose
    client sends the start of one record a byte at a time:

    - the bounded wait for a refused client to close ends on time;
    - the copy of a payload returns for the server's reply at once;
    - it gives up at the idle deadline, which the bytes do not move;
    - and it holds the client to the throughput floor meanwhile.
    """
    sys.path.insert(0, SIGUL_LIB)
    io = importlib.import_module("nss.io")
    nss = importlib.import_module("nss.nss")
    nss_ssl = importlib.import_module("nss.ssl")
    double_tls = vars(importlib.import_module("double_tls"))
    outer_buffer = double_tls["OuterBuffer"]
    # Before anything else: the check of the server's memory limit,
    # which follows, needs NSS for its digests, patch 26 or none.
    nss.nss_init(f"sql:{nss_dir}")
    nss_ssl.set_domestic_policy()
    label = "a TLS record sent a byte at a time does not outlast the bounded wait"
    if not hasattr(outer_buffer, "discard_input"):
        check(label, False, "no patch 26")
        return
    # What a wait that fails may raise: the buffer's own errors are
    # IOErrors, and a receive that waited raises NSPR's.
    errors = (
        OSError,
        cast(type[Exception], vars(importlib.import_module("nss.error"))["NSPRError"]),
    )
    listener = nss_ssl.SSLSocket(io.PR_AF_INET)
    cert = nss.find_cert_from_nickname(NICKNAME)
    listener.config_secure_server(
        cert, nss.find_key_by_any_cert(cert), cert.find_kea_type()
    )
    listener.bind(io.NetworkAddress(io.PR_IpAddrLoopback, 0))
    listener.listen(1)
    server_peer, server_sock = _nspr_pair(io)
    server_buf = cast(Buffer, outer_buffer(server_sock, idle_timeout=IDLE_SECONDS))
    peers = [server_peer]
    every = f"with a byte of the record arriving every {DRIP_SECONDS}s"
    port = cast(int, listener.get_sock_name().port)

    def accept() -> object:
        accepted = listener.accept()[0]
        accepted.force_handshake()
        return cast(object, accepted)

    def dripping(count: int, **options: int) -> tuple[Buffer, threading.Thread]:
        peer, accepted, record = _fresh_tls_record(port, accept)
        peers.append(peer)
        buf = cast(Buffer, outer_buffer(accepted, **options))
        return buf, _drip(peer, record, count)

    try:
        buf, slow = dripping(12, idle_timeout=IDLE_SECONDS)
        started = time.monotonic()
        buf.discard_input(started + 1)
        elapsed = time.monotonic() - started
        slow.join()
        check(
            label,
            0.9 < elapsed < 2,
            f"discard_input() returned after {elapsed:.1f}s of the 1s allowed,"
            + f" {every} for 3s",
        )

        buf, slow = dripping(12, idle_timeout=IDLE_SECONDS)
        reply = threading.Timer(0.5, server_peer.sendall, [b"\0\0\0\1r"])
        reply.start()
        said, elapsed = _timed(lambda: buf.read_unless(4096, server_buf), errors)
        reply.join()
        slow.join()
        check(
            "... nor hold up the server's reply",
            said == "returned None" and elapsed < IDLE_SECONDS / 2,
            f"read_unless() {said} after {elapsed:.1f}s, the reply sent at 0.5s,"
            + f" {every} for 3s",
        )
        # The reply is still unread, so a silent server needs its own.
        quiet_peer, quiet_sock = _nspr_pair(io)
        peers.append(quiet_peer)
        quiet_buf = cast(Buffer, outer_buffer(quiet_sock, idle_timeout=IDLE_SECONDS))

        buf, slow = dripping(16, idle_timeout=SHORT_IDLE_SECONDS)
        said, elapsed = _timed(lambda: buf.read_unless(4096, quiet_buf), errors)
        slow.join()
        check(
            "... nor move the idle deadline",
            said == "raised IdleTimeoutError"
            and SHORT_IDLE_SECONDS - 0.1 < elapsed < SHORT_IDLE_SECONDS + 1.5,
            f"read_unless() {said} after {elapsed:.1f}s, idle deadline"
            + f" {SHORT_IDLE_SECONDS}s, {every} for 4s",
        )

        buf, slow = dripping(
            12, idle_timeout=IDLE_SECONDS, min_rate=FLOOR, rate_grace=FLOOR_SECONDS
        )
        said, elapsed = _timed(lambda: buf.read_unless(4096, quiet_buf), errors)
        slow.join()
        check(
            "... nor escape the throughput floor",
            said == "raised SlowPeerError"
            and FLOOR_SECONDS < elapsed < IDLE_SECONDS / 2,
            f"read_unless() {said} after {elapsed:.1f}s, floor {FLOOR} B/s over"
            + f" {FLOOR_SECONDS}s, idle deadline {IDLE_SECONDS}s, {every} for 3s",
        )
    finally:
        for peer in peers:
            peer.close()
        listener.close()


def test_untrusted_message() -> None:
    """What the client prints of a refusal's message.

    The refusal is unauthenticated, so whoever holds the bridge can
    write it. The client's reading of it is driven directly, with a
    message carrying a line break, a terminal escape, a C1 control, a
    right-to-left override and a backslash.
    """
    sys.path.insert(0, SIGUL_LIB)
    client = vars(importlib.import_module("client"))
    connection_type = cast(type, client["ClientsConnection"])
    client_error = cast(type[Exception], client["ClientError"])
    label = "a refusal's message reaches the terminal as printable ASCII alone"
    read_refusal = cast(
        "Callable[[object], None] | None",
        getattr(connection_type, "_ClientsConnection__raise_early_reply", None),
    )
    if read_refusal is None:
        check(label, False, "no patch 26")
        return
    hostile = b"limit\n\x1b[2J\x9b\xe2\x80\xae\\ end"
    key = b"message"
    # PAYLOAD_TOO_LARGE, one field, and an authenticator of zeroes.
    unread = [
        (17).to_bytes(4, "big")
        + bytes([1, len(key)])
        + key
        + bytes([len(hostile)])
        + hostile
        + bytes(64)
    ]

    def outer_read(size: int) -> bytes:
        data, unread[0] = unread[0][:size], unread[0][size:]
        return data

    # The one method of DoubleTLSClient a refusal is read with.
    transport = "_ClientsConnection__client"
    connection = cast(object, object.__new__(connection_type))
    setattr(connection, transport, SimpleNamespace(outer_read=outer_read))
    try:
        read_refusal(connection)
        said = "(no error raised)"
    except client_error as e:
        said = str(e)
    wanted = f"Error: {REFUSAL}: " + r"limit\x0a\x1b[2J\x9b\xe2\x80\xae\x5c end"
    check(label, said == wanted, f"{said!r}")


def test_small_frames() -> None:
    """The bridge's copy of a payload the client sends a byte to a frame.

    The bridge receives a frame at a time, to stay ready for the
    server's reply. Passing each on as it came would cost a write to
    the server for every frame, however small the client made them.
    """
    sys.path.insert(0, SIGUL_LIB)
    io = importlib.import_module("nss.io")
    outer_buffer = vars(importlib.import_module("double_tls"))["OuterBuffer"]
    copy = cast(
        "Callable[[object], None] | None",
        getattr(importlib.import_module("bridge"), "copy_request_payload", None),
    )
    label = "a payload sent a byte to a frame reaches the server 4096 bytes at a time"
    if copy is None:
        check(label, False, "no patch 26")
        return
    client_peer, client_sock = _nspr_pair(io)
    server_peer, server_sock = _nspr_pair(io)
    server_peer.settimeout(START_SECONDS)
    conn = SimpleNamespace(
        request_payload_size=SMALL_FRAMES,
        client_buf=outer_buffer(client_sock, idle_timeout=IDLE_SECONDS),
        server_buf=outer_buffer(server_sock, idle_timeout=IDLE_SECONDS),
    )
    payload = bytes(at % 251 for at in range(SMALL_FRAMES))
    wanted = b"".join(
        len(payload[at : at + 4096]).to_bytes(4, "big") + payload[at : at + 4096]
        for at in range(0, SMALL_FRAMES, 4096)
    )
    got = b""
    try:
        client_peer.sendall(
            b"".join(b"\0\0\0\1" + payload[at : at + 1] for at in range(SMALL_FRAMES))
        )
        copy(conn)
        # Framed as it came, the payload would be five times this long.
        while len(got) < len(wanted):
            piece = server_peer.recv(len(wanted) - len(got))
            if not piece:
                break
            got += piece
        said = f"{SMALL_FRAMES} frames of one byte"
    except OSError as e:
        said = str(e)
    finally:
        client_peer.close()
        server_peer.close()
    check(
        label,
        got == wanted,
        f"{said}: the server was sent frames of "
        + f"{int.from_bytes(got[:4], 'big')} bytes, {len(got)} bytes read",
    )


def test_high_descriptor() -> None:
    """The client's look for a reply, on a descriptor numbered over 1023.

    select() refuses such a descriptor, so a client started with that
    many open would fail on the first write of any payload. The two
    methods that wait on the client's pipe are driven directly, over a
    socket pair moved to a high number.
    """
    sys.path.insert(0, SIGUL_LIB)
    transport = cast(
        type, vars(importlib.import_module("double_tls"))["DoubleTLSClient"]
    )
    pending = cast(
        "Callable[[object], bool] | None",
        getattr(transport, "outer_input_pending", None),
    )
    finish = cast(
        "Callable[[object], None] | None", getattr(transport, "outer_finish", None)
    )
    label = "the client's wait for a reply takes a descriptor numbered over 1023"
    if pending is None or finish is None:
        check(label, False, "no patch 26")
        return
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft != resource.RLIM_INFINITY and soft <= HIGH_DESCRIPTOR:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (HIGH_DESCRIPTOR + 1, hard))
        except (ValueError, OSError) as e:
            check(label, False, f"descriptor limit {soft}, and no more to be had: {e}")
            return
    ours, theirs = socket.socketpair()
    try:
        pipe = socket.socket(
            fileno=fcntl.fcntl(ours.fileno(), fcntl.F_DUPFD, HIGH_DESCRIPTOR)
        )
    finally:
        ours.close()
    client = cast(object, object.__new__(transport))
    # The one attribute of DoubleTLSClient the two methods use.
    outer_pipe = "_DoubleTLSClient__outer_pipe"
    setattr(client, outer_pipe, pipe)
    started = time.monotonic()
    try:
        quiet = not pending(client)
        theirs.sendall(b"reply")
        answered = pending(client)
        theirs.close()
        finish(client)
        elapsed = time.monotonic() - started
        ok = quiet and answered and elapsed < START_SECONDS / 2
        said = (
            f"descriptor {pipe.fileno()}: {'nothing' if quiet else 'something'}"
            + f" pending before the reply, {'something' if answered else 'nothing'}"
            + f" after it, and finished in {elapsed:.1f}s"
        )
    except ValueError as e:
        ok = False
        said = f"descriptor {pipe.fileno()}: {e}"
    finally:
        pipe.close()
        theirs.close()
    check(label, ok, said)


def _request_alarm() -> None:
    """What the server's request alarm does to whatever it interrupts."""
    raise SystemExit(3)


def test_interrupted_refusal() -> None:
    """The server's record of a refusal that its request alarm cuts short.

    After its reply the server reads what a refused client still sends,
    until the bridge closes. A request-timeout shorter than that wait
    ends the request there, so the reason must be in the log by then:
    the server's refusal is driven directly, with the alarm going off
    in that wait.
    """
    sys.path.insert(0, SIGUL_LIB)
    server = vars(importlib.import_module("server"))
    connection_type = cast(type, server["ServersConnection"])
    invalid_request = cast(type[Exception], server["InvalidRequestError"])
    label = "a refusal cut short by the request alarm is in the server's log"
    refuse = cast(
        "Callable[[object, int, int], None] | None",
        getattr(connection_type, "_ServersConnection__refuse_payload", None),
    )
    if refuse is None:
        check(label, False, "no patch 26")
        return
    sent: list[bytes] = []
    transport = SimpleNamespace(
        inner_close=lambda: None, outer_write=sent.append, outer_finish=_request_alarm
    )
    connection = cast(object, object.__new__(connection_type))
    # The three methods of DoubleTLSClient a refusal is made with.
    client = "_ServersConnection__client"
    setattr(connection, client, transport)
    log = StringIO()
    records = logging.StreamHandler(log)
    logging.getLogger().addHandler(records)
    try:
        refuse(connection, LIMIT + 1, LIMIT)
        ended = "by returning"
    except invalid_request as e:
        ended = f"with {e!r}"
    except SystemExit:
        ended = "with the alarm"
    finally:
        logging.getLogger().removeHandler(records)
    logged = log.getvalue().count(SERVER_REFUSAL)
    check(
        label,
        ended == "with the alarm" and len(sent) == 1 and logged == 1,
        f"the refusal ended {ended}, after {len(sent)} replies and"
        + f" {logged} lines of {SERVER_REFUSAL!r}",
    )


class _PayloadWanted(Exception):
    """The server went on to read the payload of a request driven directly."""


def _read_memory_request(size: int) -> tuple[str, list[bytes], int]:
    """Have the server read a request whose payload it keeps in memory.

    The request announces a payload of size bytes and carries none of
    it. Return how the reading ended, the replies sent, and how often
    the refusal was logged.
    """
    server = vars(importlib.import_module("server"))
    utils = vars(importlib.import_module("utils"))
    connection_type = cast(type, server["ServersConnection"])
    invalid_request = cast(type[Exception], server["InvalidRequestError"])
    pack = cast("Callable[[int], bytes]", utils["u32_pack"])
    pack_size = cast("Callable[[int], bytes]", utils["u64_pack"])
    fields = cast("Callable[[dict[str, str]], bytes]", utils["format_fields"])
    request = bytearray(
        pack(cast(int, utils["protocol_version"]))
        + fields({"op": "no-such-operation", "user": "nobody"})
        + pack_size(size)
    )

    def outer_read(count: int) -> bytes:
        if len(request) < count:
            raise _PayloadWanted
        data = bytes(request[:count])
        del request[:count]
        return data

    sent: list[bytes] = []
    connection = cast(object, object.__new__(connection_type))
    transport = SimpleNamespace(
        outer_read=outer_read,
        inner_close=lambda: None,
        outer_write=sent.append,
        outer_finish=lambda: None,
    )
    # The file limit is the other one, and the request alarm, which the
    # server sets as a request arrives, is off: this is the test's own
    # process.
    config = SimpleNamespace(
        max_memory_payload_size=MEMORY_LIMIT,
        max_file_payload_size=LIMIT,
        request_timeout=0,
    )
    vars(connection).update({"_ServersConnection__client": transport, "config": config})
    read_request = cast(
        "Callable[[object], object]", vars(connection_type)["read_request"]
    )
    log = StringIO()
    records = logging.StreamHandler(log)
    logging.getLogger().addHandler(records)
    try:
        _ = read_request(connection)
        ended = "by returning"
    except _PayloadWanted:
        ended = "reading the payload"
    except invalid_request as e:
        ended = f"with {e!r}"
    except Exception as e:
        ended = f"unexpectedly, with {e!r}"
    finally:
        logging.getLogger().removeHandler(records)
    return ended, sent, log.getvalue().count(SERVER_REFUSAL)


def test_memory_limit() -> None:
    """The limit a refusal names for a payload the server keeps in memory.

    The server keeps one kind of payload in memory, that of a request
    whose operation it does not know, and holds it to
    max-memory-payload-size. The bridge knows the same operations and
    turns any other away before the server sees it, so the daemon cases
    cannot reach this limit: the server's reading of a request is
    driven directly, over what a bridge that knew one more operation
    would forward.
    """
    sys.path.insert(0, SIGUL_LIB)
    errors = vars(importlib.import_module("errors"))
    utils = vars(importlib.import_module("utils"))
    size = MEMORY_LIMIT + 1
    ended, sent, logged = _read_memory_request(size)
    code = None
    message = None
    if len(sent) == 1:
        reply = bytearray(sent[0])

        def take(count: int) -> bytes:
            data = bytes(reply[:count])
            del reply[:count]
            return data

        code = cast("Callable[[bytes], int]", utils["u32_unpack"])(take(4))
        read_fields = cast(
            "Callable[[Callable[[int], bytes]], dict[str, bytes]]",
            utils["read_fields"],
        )
        message = read_fields(take).get("message")
    wanted = f"payload of {size} bytes, limit {MEMORY_LIMIT} bytes".encode()
    check(
        "a payload over the memory limit, under the file limit: the refusal"
        + " names the memory limit",
        ended == "with RefusedPayloadError('Payload too large')"
        and code is not None
        and code == errors.get("PAYLOAD_TOO_LARGE")
        and message == wanted
        and logged == 1,
        f"the request ended {ended}, after {len(sent)} replies, code {code},"
        + f" message {message!r} and {logged} lines of {SERVER_REFUSAL!r}",
    )
    ended, sent, logged = _read_memory_request(MEMORY_LIMIT)
    check(
        "... and a payload at the memory limit is read, not refused",
        ended == "reading the payload" and not sent and logged == 0,
        f"the request ended {ended}, after {len(sent)} replies and"
        + f" {logged} lines of {SERVER_REFUSAL!r}",
    )


def _older_lib() -> str | None:
    """A copy of the code under test with patch 26 taken out again.

    That is the code an older peer runs. None, with a failed check, if
    the patch does not come out.
    """
    older = os.path.join(tempfile.mkdtemp(prefix="sigul-payload-limit-"), "older")
    os.mkdir(older)
    for name in os.listdir(SIGUL_LIB):
        if name.endswith(".py"):
            _ = shutil.copy(os.path.join(SIGUL_LIB, name), older)
    # --force: never ask, and never take the patch for one to apply
    # forwards, which is what code without it would otherwise get.
    command = [
        "patch", "--reverse", "--force", "--strip=2", "--silent",
        "--no-backup-if-mismatch", f"--directory={older}",
        f"--input={os.path.abspath(PATCH)}",
    ]  # fmt: skip
    try:
        done = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
        )
        problem = "" if done.returncode == 0 else f"{done.stdout}{done.stderr}".strip()
    except OSError as e:
        problem = str(e)
    check(
        "patch 26 comes out of a copy of the code, which stands for an older peer",
        not problem,
        problem or older,
    )
    return None if problem else older


def _served(stack: Stack) -> None:
    status, printed, elapsed = stack.sign_data(LIMIT, 2 * SLOT_SECONDS)
    check(
        "... and the bridge serves the next request",
        status == 1 and printed == ORDINARY_REPLY and elapsed < SLOT_SECONDS,
        f"exit {status} after {elapsed:.1f}s, bound {SLOT_SECONDS}s: {printed!r}",
    )


def _fails_as_before(status: int, printed: str) -> bool:
    """Whether a client failed with an I/O error, as an older one does.

    Which one is a matter of timing, so any is taken: `Unexpected EOF
    in NSPR` where the upload ran to its end, `BrokenPipeError` or
    `ConnectionResetError` where a write failed first.
    """
    return status == 1 and IO_ERROR in printed and REFUSAL not in printed


def test_older_client(stack: Stack, older: str) -> float:
    """An older client, refused by the patched bridge and server.

    Return how long the refusal of the file 2 GiB over the limit took.
    """
    status, printed, elapsed = stack.sign_data(LIMIT + 1, lib=older)
    check(
        "an older client, one byte over, refused by a patched bridge and server:"
        + " fails as before",
        _fails_as_before(status, printed) and elapsed < PROMPT_SECONDS,
        f"exit {status} after {elapsed:.1f}s: {printed!r}",
    )
    status, printed, elapsed = stack.sign_data(LIMIT + FAR_OVER, lib=older)
    check(
        "an older client, 2 GiB over, refused by a patched bridge and server:"
        + " fails as before",
        _fails_as_before(status, printed),
        f"exit {status} after {elapsed:.1f}s: {printed!r}",
    )
    _served(stack)
    return elapsed


def test_older_peers(older: str, lagging_client: float | None) -> None:
    """An older bridge and server, with an older client and a patched one.

    The older client against them is the refusal as it was, and times
    it: neither mixed pairing may take longer. lagging_client is how
    long the older client took against the patched bridge and server.
    """
    stack = Stack(older)
    try:
        stack.start()
        status, printed, before = stack.sign_data(LIMIT + FAR_OVER)
        check(
            "an older client, bridge and server: the refusal as it was",
            _fails_as_before(status, printed),
            f"exit {status} after {before:.1f}s: {printed!r}",
        )
        if lagging_client is not None:
            check(
                "an older client was refused no later by the patched bridge and server",
                lagging_client < before + LATER_SECONDS,
                f"{lagging_client:.1f}s, and {before:.1f}s by older ones",
            )
        status, printed, elapsed = stack.sign_data(LIMIT + 1, lib=SIGUL_LIB)
        check(
            "a patched client, one byte over, refused by an older bridge and server:"
            + " fails as before",
            _fails_as_before(status, printed) and elapsed < PROMPT_SECONDS,
            f"exit {status} after {elapsed:.1f}s: {printed!r}",
        )
        status, printed, elapsed = stack.sign_data(LIMIT + FAR_OVER, lib=SIGUL_LIB)
        check(
            "a patched client, 2 GiB over, refused by an older bridge and server:"
            + " fails as before, and no later than the older client",
            _fails_as_before(status, printed) and elapsed < before + LATER_SECONDS,
            f"exit {status} after {elapsed:.1f}s, and {before:.1f}s for the older"
            + f" client: {printed!r}",
        )
        _served(stack)
    except (RuntimeError, subprocess.SubprocessError):
        _print_logs(stack)
        raise
    finally:
        stack.stop()


def _print_logs(stack: Stack) -> None:
    for component in ("bridge", "server"):
        print(f"--- sigul_{component}.log")
        print(stack.log(component))


def main() -> int:
    print("Payload limit refusal regression tests")
    with open(os.path.join(SIGUL_LIB, "errors.py"), encoding="utf-8") as f:
        patched = "PAYLOAD_TOO_LARGE" in f.read()
    print(f"sigul: {'PATCHED' if patched else 'UNPATCHED'}")
    print()
    stack = Stack()
    test_part_of_a_frame()
    test_announced_frame()
    test_dripped_record(stack.path("nss"))
    test_untrusted_message()
    test_small_frames()
    test_high_descriptor()
    test_interrupted_refusal()
    test_memory_limit()
    older = None
    lagging_client = None
    try:
        stack.start()
        untouched = stack.server_tmp_state()
        test_refused_after_upload(stack)
        test_far_over(stack)
        test_refusals_leave_tmp_alone(stack, untouched)
        test_at_the_limit(stack, untouched)
        test_silent_client(stack)
        older = _older_lib()
        if older is not None:
            lagging_client = test_older_client(stack, older)
    except (RuntimeError, subprocess.SubprocessError):
        _print_logs(stack)
        raise
    finally:
        stack.stop()
    if older is not None:
        test_older_peers(older, lagging_client)
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        _print_logs(stack)
        return 1
    print("an over-limit payload is refused by name, promptly, and unstored")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--component":
        run_component(sys.argv[2], sys.argv[3:])
    else:
        sys.exit(main())
