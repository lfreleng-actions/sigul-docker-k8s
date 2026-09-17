# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Network conditions, applied through Toxiproxy.

Two proxies stand in front of the bridge: one on the client port, one
on the server port. Every fault here is a toxic on one of them, so the
stack's own configuration is untouched and each condition can be
switched on and off in the middle of a run.

The server-link faults are the ones with production history. The
server holds a single idle connection to the bridge for as long as it
takes the next request to arrive; anything on that path that drops
state silently - NAT tables, load-balancer idle timeouts, a rebooted
firewall - produces a connection that both ends believe is open and
neither can use.
"""

from __future__ import annotations

import os

from .base import Fault, ToxiproxyClient

PROXY_CLIENT = "bridge_client"
PROXY_SERVER = "bridge_server"

_client: ToxiproxyClient | None = None


def client() -> ToxiproxyClient:
    global _client
    if _client is None:
        _client = ToxiproxyClient(
            os.environ.get("SOAK_TOXIPROXY_URL", "http://toxiproxy:8474")
        )
    return _client


def configure_proxies(bridge_upstream: str = "sigul-bridge") -> None:
    """Create both proxies. Idempotent."""
    api = client()
    api.wait_ready()
    api.ensure_proxy(PROXY_CLIENT, "0.0.0.0:44334", f"{bridge_upstream}:44334")
    api.ensure_proxy(PROXY_SERVER, "0.0.0.0:44333", f"{bridge_upstream}:44333")
    api.reset()


class _ToxicFault(Fault):
    """One toxic type on one proxy, in one or both directions.

    Toxiproxy's `upstream` is the direction from the connecting side
    towards the service it proxies; `downstream` is the reply path. On
    the server proxy the connecting side is the Sigul server, so
    server->bridge traffic - including the server's FIN - is upstream.
    """

    proxy: str = PROXY_CLIENT
    toxic_type: str = ""
    streams: tuple[str, ...] = ("downstream",)
    toxicity: float = 1.0
    attributes: dict = {}  # noqa: RUF012 - overridden per subclass

    def start(self) -> None:
        for stream in self.streams:
            client().add_toxic(
                self.proxy,
                f"{self.name}_{stream}",
                self.toxic_type,
                stream=stream,
                toxicity=self.toxicity,
                attributes=dict(self.attributes),
            )

    def stop(self) -> None:
        for stream in self.streams:
            client().remove_toxic(self.proxy, f"{self.name}_{stream}")


class LatencyClient(_ToxicFault):
    name = "net_latency_client"
    description = "200 ms +/- 100 ms added to every client->bridge packet."
    implication = (
        "Latency alone should only slow requests, never fail them; failures "
        "here mean a timeout somewhere is tuned for a LAN."
    )
    proxy = PROXY_CLIENT
    toxic_type = "latency"
    streams = ("upstream",)
    attributes = {"latency": 200, "jitter": 100}  # noqa: RUF012


class BandwidthSqueeze(_ToxicFault):
    name = "net_bandwidth_squeeze"
    description = "Cap client->bridge throughput at 64 KB/s during large uploads."
    implication = (
        "A slow uploader (a 64 MiB payload takes ~17 minutes at this rate) "
        "holds the bridge's slot for the whole transfer with nothing bounding it."
    )
    proxy = PROXY_CLIENT
    toxic_type = "bandwidth"
    streams = ("upstream",)
    attributes = {"rate": 64}  # noqa: RUF012


class ResetPeerClient(_ToxicFault):
    name = "net_reset_peer_client"
    description = "RST client connections roughly two seconds after they open."
    implication = (
        "Mid-request resets from the network leave server children or "
        "bridge state behind that a clean close would have released."
    )
    proxy = PROXY_CLIENT
    toxic_type = "reset_peer"
    streams = ("downstream",)
    attributes = {"timeout": 2000}  # noqa: RUF012


class BlackholeClient(_ToxicFault):
    name = "net_blackhole_client"
    service_possible_during = False
    description = (
        "Stop forwarding client<->bridge data with no FIN and no RST: the "
        "connection stays open and carries nothing."
    )
    implication = (
        "A silently dead client connection is indistinguishable from a slow "
        "one to the bridge; with no deadline it waits indefinitely."
    )
    proxy = PROXY_CLIENT
    toxic_type = "timeout"
    streams = ("upstream", "downstream")
    attributes = {"timeout": 0}  # noqa: RUF012


class BlackholeServerLink(_ToxicFault):
    name = "net_blackhole_server_link"
    service_possible_during = False
    description = (
        "Stop forwarding server<->bridge data with no FIN and no RST - the "
        "idle connection dies silently, as behind a NAT or load balancer."
    )
    implication = (
        "This is the production incident, network-caused: the server's "
        "teardown waits on a close that never comes, and every request "
        "fails until the pod restarts."
    )
    proxy = PROXY_SERVER
    toxic_type = "timeout"
    streams = ("upstream", "downstream")
    attributes = {"timeout": 0}  # noqa: RUF012


NETWORK_FAULTS: tuple[type[Fault], ...] = (
    LatencyClient,
    BandwidthSqueeze,
    ResetPeerClient,
    BlackholeClient,
    BlackholeServerLink,
)
