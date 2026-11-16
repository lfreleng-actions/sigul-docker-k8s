#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for a server reply lost in the bridge (patch 24).
#
# The bridge relays the inner TLS stream between client and server with
# two _InnerBridgingBuffer instances, one per direction. Each one parses
# the framed stream it reads, forwards the inner chunks, and defers any
# outer chunks it meets for the OuterBuffer that owns that peer to hand
# out afterwards. A server that rejects a request as soon as it has
# read the inner fields - a certificate/user mismatch under strict user
# checking - sends its reply within a millisecond of its inner EOF, so
# the two arrive in the same read.
#
# Upstream bridge_inner_stream handed each direction's deferred outer
# data to the wrong OuterBuffer: the server's reply landed in the
# client's buffer. The bridge then read the server's socket, met its
# EOF, and dropped both peers, and the client saw an I/O error in place
# of `Authentication failed` (#123). The same code also consumed the
# server's outer EOF when it arrived in that read, so a buffer that
# should have reported end of stream blocked instead.
#
# The checks pre-load each peer's socket before the relay runs, so the
# bytes are already queued and come back in one read; nothing depends
# on timing. They cover:
#
# - the server's reply arriving with its inner EOF is read from the
#   server's buffer, and the client's buffer stays clean;
# - the server's outer EOF arriving with its reply is still reported;
# - the mirror case, the client's outer data arriving with its inner
#   EOF, lands in the client's buffer;
# - a reply arriving after the inner phase is read as before.
#
# Without the patch the first three fail; with it all pass.
#
# Run inside the sigul bridge image:
#   python3 test/test_bridge_fast_reply.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# double_tls and utils are upstream code this repository only patches,
# and ship no type stubs, so their members are untyped by nature.

import inspect
import os
import socket
import sys
import time
from collections.abc import Callable
from typing import Protocol, cast

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import double_tls  # noqa: E402
import nss.error  # noqa: E402
import nss.io  # noqa: E402
import utils  # noqa: E402

FAILURES: list[str] = []

PATCHED = "eof" in inspect.signature(double_tls.OuterBuffer.add_outer_data).parameters

# Bounds every socket read the checks make, so an unpatched tree fails
# with a timeout rather than hanging. The relay itself needs no bound:
# every peer's inner EOF is queued before it starts. Whole seconds: the
# buffer converts it with nss.io.seconds_to_interval.
READ_TIMEOUT = 2


class Buffer(Protocol):
    """The slice of double_tls.OuterBuffer these checks drive."""

    def read(self, buf_size: int) -> bytes: ...


class Relay:
    """Two loopback connections and the bridge's buffers around them."""

    client_peer: socket.socket
    server_peer: socket.socket
    client_buf: object
    server_buf: object

    def __init__(self) -> None:
        self.client_peer, client_sock = _nspr_pair()
        self.server_peer, server_sock = _nspr_pair()
        self.client_buf = double_tls.OuterBuffer(client_sock, idle_timeout=READ_TIMEOUT)
        self.server_buf = double_tls.OuterBuffer(server_sock, idle_timeout=READ_TIMEOUT)

    def run(self) -> None:
        double_tls.bridge_inner_stream(self.client_buf, self.server_buf)

    def close(self) -> None:
        for peer in (self.client_peer, self.server_peer):
            peer.close()


def _nspr_pair() -> tuple[socket.socket, object]:
    """A loopback connection: a plain socket, and the NSPR socket it reached."""
    listener = nss.io.Socket(nss.io.PR_AF_INET)
    listener.set_socket_option(nss.io.PR_SockOpt_Reuseaddr, True)
    listener.bind(nss.io.NetworkAddress(nss.io.PR_IpAddrLoopback, 0))
    listener.listen(1)
    peer = socket.create_connection(("127.0.0.1", listener.get_sock_name().port))
    accepted = listener.accept()[0]
    _ = listener.close()
    return peer, accepted


def _inner(data: bytes) -> bytes:
    """data as one inner-stream chunk; b"" is the inner stream's end."""
    header = cast(bytes, utils.u32_pack(double_tls._chunk_inner_mask | len(data)))
    return header + data


def _outer(data: bytes) -> bytes:
    """data as one outer-stream chunk; b"" is the outer stream's end."""
    header = cast(bytes, utils.u32_pack(len(data)))
    return header + data


def _deferred(buf: object) -> bytes:
    """The outer data an OuterBuffer holds for its next read."""
    return cast(bytes, getattr(buf, "_OuterBuffer__outer_data", b""))


def _read(buf: object, size: int) -> tuple[bytes | None, str]:
    """buf.read(size), or None and how it failed."""
    try:
        return cast(Buffer, buf).read(size), "read"
    except EOFError as e:
        return None, f"EOFError: {e}"
    except nss.error.NSPRError as e:
        return None, f"NSPRError: {e}"


def _timed(operation: Callable[[], object]) -> tuple[str, float]:
    """How operation() ended and how long it took."""
    started = time.monotonic()
    try:
        _ = operation()
        ended = "returned"
    except EOFError as e:
        ended = f"EOFError: {e}"
    except nss.error.NSPRError as e:
        ended = f"NSPRError: {e}"
    return ended, time.monotonic() - started


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def test_fast_reply_reaches_server_buffer() -> None:
    # The production failure: the server's inner EOF and its reply are
    # queued together, so the relay's one read of the server takes both.
    # Its outer EOF follows later, as it did in the failing run, where
    # the bridge met it on the socket while looking for the reply.
    reply = b"server rejects: authentication failed"
    relay = Relay()
    try:
        relay.client_peer.sendall(_inner(b"client hello") + _inner(b""))
        relay.server_peer.sendall(_inner(b"") + _outer(reply))
        relay.run()
        relay.server_peer.sendall(_outer(b""))
        got, how = _read(relay.server_buf, len(reply))
        leaked = _deferred(relay.client_buf)
        check(
            "a reply arriving with the server's inner EOF is read from the server",
            got == reply,
            f"{how}: {got!r}",
        )
        check(
            "the server's reply is not handed to the client's buffer",
            leaked == b"",
            f"{len(leaked)} bytes deferred on the client's buffer",
        )
        ended, _ = _timed(lambda: cast(Buffer, relay.server_buf).read(1))
        check(
            "the server's stream carries on after its deferred reply",
            ended.startswith("EOFError"),
            ended,
        )
    finally:
        relay.close()


def test_outer_eof_with_reply_is_kept() -> None:
    # The whole of the server's tail - inner EOF, reply, outer EOF - in
    # one read. The reply must be read, and the read after it must
    # report end of stream at once, not wait for the socket.
    reply = b"server rejects: authentication failed"
    relay = Relay()
    try:
        relay.client_peer.sendall(_inner(b"client hello") + _inner(b""))
        relay.server_peer.sendall(_inner(b"") + _outer(reply) + _outer(b""))
        relay.run()
        got, how = _read(relay.server_buf, len(reply))
        check(
            "a reply arriving with the server's outer EOF is read",
            got == reply,
            f"{how}: {got!r}",
        )
        ended, elapsed = _timed(lambda: cast(Buffer, relay.server_buf).read(1))
        check(
            "an outer EOF arriving with the reply is still reported",
            ended.startswith("EOFError") and elapsed < READ_TIMEOUT / 2,
            f"after {elapsed:.2f}s: {ended}",
        )
    finally:
        relay.close()


def test_client_outer_data_reaches_client_buffer() -> None:
    # The mirror case. Nothing in the protocol sends it today, but the
    # swap was symmetric and the fix must be too.
    data = b"client outer data"
    relay = Relay()
    try:
        relay.client_peer.sendall(_inner(b"") + _outer(data))
        relay.server_peer.sendall(_inner(b"server hello") + _inner(b""))
        relay.run()
        got, how = _read(relay.client_buf, len(data))
        leaked = _deferred(relay.server_buf)
        check(
            "outer data arriving with the client's inner EOF is read from the client",
            got == data and leaked == b"",
            f"{how}: {got!r}; {len(leaked)} bytes deferred on the server's buffer",
        )
    finally:
        relay.close()


def test_late_reply_read_as_before() -> None:
    # The common case: the server works for a while after the inner
    # phase, then replies. Nothing is deferred and the reply is read
    # from the socket.
    reply = b"ok"
    relay = Relay()
    try:
        relay.client_peer.sendall(_inner(b"client hello") + _inner(b""))
        relay.server_peer.sendall(_inner(b"server hello") + _inner(b""))
        relay.run()
        relay.server_peer.sendall(_outer(reply) + _outer(b""))
        got, how = _read(relay.server_buf, len(reply))
        ended, _ = _timed(lambda: cast(Buffer, relay.server_buf).read(1))
        check(
            "a reply arriving after the inner phase is read as before",
            got == reply and ended.startswith("EOFError"),
            f"{how}: {got!r}; then {ended}",
        )
    finally:
        relay.close()


def main() -> int:
    print("Bridge fast server rejection regression tests")
    print(f"double_tls: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    test_fast_reply_reaches_server_buffer()
    test_outer_eof_with_reply_is_kept()
    test_client_outer_data_reaches_client_buffer()
    test_late_reply_read_as_before()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("a reply arriving with the server's inner EOF reaches the client")
    return 0


if __name__ == "__main__":
    sys.exit(main())
