#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""HTTP health endpoint for the sigul bridge pod.

Bare TCP health checks against the Sigul listeners disrupt the
bridge's serial accept loop (accepted connections trigger an immediate
TLS handshake; unaccepted ones exhaust the small client backlog), so
the NLB probes this sidecar instead. It reports 200 when the bridge
process is listening on both ports, determined by reading
/proc/net/tcp* - no connections are ever made to the daemon.

Usage: bridge-healthcheck.py CLIENT_PORT SERVER_PORT LISTEN_PORT
"""

import http.server
import sys

CLIENT_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 44334
SERVER_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 44333
LISTEN_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8080

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


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        healthy = ports_listening()
        status = 200 if healthy else 503
        body = b"ok\n" if healthy else b"bridge not listening\n"
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
        + f" (watching {CLIENT_PORT}, {SERVER_PORT})"
    )
    print(msg, flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
