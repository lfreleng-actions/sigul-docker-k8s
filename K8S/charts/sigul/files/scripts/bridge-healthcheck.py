#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""HTTP health endpoint for the sigul bridge pod.

Bare TCP health checks against the Sigul listeners disrupt the
bridge's serial accept loop (accepted connections trigger an immediate
TLS handshake; unaccepted ones exhaust the small client backlog), so
the NLB probes this sidecar instead. No connections are ever made to
the daemon.

/healthz reports 200 when the bridge is listening on both ports and
its heartbeat is fresh. Listening alone is not enough: a frozen or
wedged bridge keeps its listening sockets, so it looked healthy to
this endpoint - and to the NLB behind it - indefinitely, while every
request hung. The heartbeat is a file the bridge daemon keeps fresh
only while its main loop is making progress (patch 15), read from the
/run volume the two containers share.

/alive reports only on this sidecar, and is what its own probes use.
Using /healthz for them would restart the sidecar whenever the bridge
wedged, and replacing a healthy container does nothing for an
unhealthy neighbour.

Usage: bridge-healthcheck.py CLIENT_PORT SERVER_PORT LISTEN_PORT
       [HEARTBEAT_PATH]
"""

import http.server
import os
import sys
import time

CLIENT_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 44334
SERVER_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 44333
LISTEN_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8080
HEARTBEAT_PATH = sys.argv[4] if len(sys.argv) > 4 else "/run/sigul_bridge.heartbeat"

#: Oldest the heartbeat may be. The daemon refreshes it every five
#: seconds while healthy, so this is six missed beats of headroom.
HEARTBEAT_MAX_AGE_SECONDS = 30

TCP_LISTEN = "0A"  # socket state in /proc/net/tcp*


def _listening_ports(path: str) -> set[int]:
    """Ports in LISTEN state recorded in one /proc/net/tcp* file.

    A missing or unreadable file yields no ports rather than raising:
    /proc/net/tcp6 is absent on IPv6-disabled hosts.
    """
    try:
        with open(path, encoding="ascii") as fh:
            rows = fh.readlines()[1:]  # first line is the header
    except OSError:
        return set()
    ports: set[int] = set()
    for row in rows:
        fields = row.split()
        if len(fields) > 3 and fields[3] == TCP_LISTEN:
            # local_address is "HEXADDR:HEXPORT"
            ports.add(int(fields[1].rsplit(":", 1)[1], 16))
    return ports


def ports_listening() -> bool:
    """True when the bridge holds both Sigul ports open."""
    wanted = {CLIENT_PORT, SERVER_PORT}
    found: set[int] = set()
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        found |= _listening_ports(path)
    # Subset, not equality: this sidecar's own listener appears here
    # too, as would any other socket in the pod's network namespace.
    return wanted <= found


def heartbeat_age() -> float | None:
    """Seconds since the bridge last proved progress; None if never."""
    try:
        return time.time() - os.stat(HEARTBEAT_PATH).st_mtime
    except OSError:
        return None


def bridge_problem() -> str | None:
    """Why the bridge cannot serve, or None if it can."""
    if not ports_listening():
        return "bridge not listening"
    age = heartbeat_age()
    if age is None:
        return "bridge heartbeat missing"
    if age > HEARTBEAT_MAX_AGE_SECONDS:
        return f"bridge heartbeat stale ({age:.0f}s old)"
    return None


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        # Answering at all is the whole of /alive's test.
        problem = None if self.path == "/alive" else bridge_problem()
        status = 503 if problem else 200
        body = f"{problem}\n".encode() if problem else b"ok\n"
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        _ = self.wfile.write(body)

    # Health checks arrive every few seconds; keep logs quiet.
    # (typing.override not used: the repo mypy hook predates 3.12.)
    def log_message(  # pyright: ignore[reportImplicitOverride]
        self, format: str, *args: object
    ) -> None:  # noqa: A002
        del format, args


def main() -> int:
    server = http.server.ThreadingHTTPServer(("", LISTEN_PORT), HealthHandler)
    msg = (
        f"[bridge-healthcheck] serving on :{LISTEN_PORT}"
        + f" (watching {CLIENT_PORT}, {SERVER_PORT}, {HEARTBEAT_PATH})"
    )
    print(msg, flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
