# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Fault primitives.

A fault is anything that makes the stack's life hard, expressed as a
pair of operations: switch it on, switch it off. The scheduler holds
each one on for a window and then measures how long the service takes
to serve again once it is off.

Faults must be scrupulous about cleaning up in `stop()`, including
after a failed `start()`. A leaked toxic or a permanently paused
container does not fail one check, it silently invalidates every
measurement that follows it.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from abc import ABC, abstractmethod


class ProductDefect(Exception):
    """The fault ran as intended and observed the defect it exists to find.

    Distinct from any other exception a fault may raise: those mean the
    harness failed to inject or remove the fault and the window is
    invalid, which nothing may excuse. This means the product failed,
    which an expectation may record as known.
    """


class Fault(ABC):
    """One reproducible way of mistreating the stack."""

    #: Stable identifier used in profiles, timelines and reports.
    name: str = "unnamed"

    #: One line, written for whoever reads the failure report.
    description: str = ""

    #: What a human should conclude if the service does not recover
    #: from this fault. Carried into the report so a red result
    #: explains itself without needing the source.
    implication: str = ""

    #: Whether honest clients could, in principle, still be served
    #: while this fault is active. True for a misbehaving client - the
    #: bridge ought to shed it and serve the others - so a stall during
    #: the window is a defect. False when the fault removes the service
    #: itself (a frozen bridge, a blackholed server link): only the
    #: recovery afterwards can be judged.
    service_possible_during: bool = True

    @abstractmethod
    def start(self) -> None:
        """Begin the fault."""

    @abstractmethod
    def stop(self) -> None:
        """End the fault and remove all trace of it. Must be idempotent."""


class ToxiproxyError(RuntimeError):
    """An HTTP error from the Toxiproxy control API."""

    def __init__(self, status: int, method: str, path: str, detail: str) -> None:
        super().__init__(f"toxiproxy {method} {path}: {status} {detail}")
        self.status = status


class ToxiproxyClient:
    """Minimal Toxiproxy control client.

    Uses urllib rather than requests so the harness image needs no
    extra dependency for what amounts to four JSON calls.
    """

    def __init__(self, base_url: str) -> None:
        self._base = base_url.rstrip("/")

    def _call(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(  # noqa: S310 - fixed private URL
            f"{self._base}{path}",
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:  # noqa: S310
                payload = response.read()
                return json.loads(payload) if payload else {}
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise ToxiproxyError(exc.code, method, path, detail) from exc

    def ensure_proxy(self, name: str, listen: str, upstream: str) -> None:
        """Create a proxy, tolerating one that already exists."""
        try:
            self._call(
                "POST",
                "/proxies",
                {"name": name, "listen": listen, "upstream": upstream, "enabled": True},
            )
        except ToxiproxyError as exc:
            if exc.status != 409:
                raise

    def add_toxic(
        self,
        proxy: str,
        name: str,
        toxic_type: str,
        stream: str = "downstream",
        toxicity: float = 1.0,
        attributes: dict | None = None,
    ) -> None:
        self._call(
            "POST",
            f"/proxies/{proxy}/toxics",
            {
                "name": name,
                "type": toxic_type,
                "stream": stream,
                "toxicity": toxicity,
                "attributes": attributes or {},
            },
        )

    def remove_toxic(self, proxy: str, name: str) -> None:
        """Remove a toxic. Tolerates one that is already gone, nothing else.

        Any other failure propagates: a toxic left active after its
        window would silently contaminate every measurement after it.
        """
        try:
            self._call("DELETE", f"/proxies/{proxy}/toxics/{name}")
        except ToxiproxyError as exc:
            if exc.status != 404:
                raise

    def reset(self) -> None:
        """Drop every toxic on every proxy."""
        self._call("POST", "/reset")

    def wait_ready(self, attempts: int = 60) -> None:
        import time

        for _ in range(attempts):
            try:
                self._call("GET", "/version")
                return
            except Exception:  # noqa: BLE001 - polling a starting service
                time.sleep(1)
        raise RuntimeError("toxiproxy did not become ready")
