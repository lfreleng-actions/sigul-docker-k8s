# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# pyright: standard, reportMissingImports=false, reportMissingModuleSource=false
# Test tooling over untyped libraries (locust, docker, matplotlib); the
# repository default of "all" would add annotation ceremony here without
# catching defects in the code under test.
"""Registry of every fault the harness knows how to inflict."""

from __future__ import annotations

from ..target import Target
from .base import Fault
from .clients import CLIENT_FAULTS
from .network import NETWORK_FAULTS
from .process import PROCESS_FAULTS


def build_registry(target: Target) -> dict[str, Fault]:
    """Instantiate one of each fault, keyed by name."""
    registry: dict[str, Fault] = {}
    for cls in CLIENT_FAULTS + NETWORK_FAULTS:
        instance = cls()
        registry[instance.name] = instance
    for cls in PROCESS_FAULTS:
        instance = cls(target)
        registry[instance.name] = instance
    return registry


__all__ = ["Fault", "build_registry"]
