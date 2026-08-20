#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""CLI for the sigul PKI bootstrap Job.

Minimal replacement for kubectl so the Job can run in the sigul
bridge image (python3 + requests available) without shipping kubectl.
The Kubernetes API layer lives in k8s_api.py, mounted alongside this
script from the same ConfigMap.

Usage:
    publish-secrets.py exists NAME [--key KEY]...
        -> exit 0 if Secret NAME holds data and every --key given is
           present with a non-empty value, 1 otherwise
    publish-secrets.py get NAME KEY
        -> print the vetted bookkeeping value of KEY, or exit 1 if
           the Secret or the key is absent. Only the non-sensitive
           bookkeeping keys in PRINTABLE_KEYS are accepted, and only
           literals from their vetted value sets are ever written to
           stdout - decoded Secret bytes never leave this process
    publish-secrets.py apply NAME [--if-absent]
        [--file key=path]... [--literal k=v]...
        -> create or replace Secret NAME (replace carries the
           current resourceVersion for optimistic concurrency;
           --if-absent leaves an existing Secret untouched)
    publish-secrets.py restart {deployment|statefulset} NAME
        -> patch the workload's pod template annotations to trigger
           a rolling restart (kubectl rollout restart equivalent)
    publish-secrets.py lock NAME --identity ID [--duration SECS]
        -> acquire the named Lease, or exit 1 if another runner
           holds it (compare-and-set; only one caller can win)
    publish-secrets.py unlock NAME --identity ID
        -> release the Lease if this identity still holds it
"""

import argparse
import sys
from collections.abc import Callable
from typing import cast

from k8s_api import (
    acquire_lease,
    apply_secret,
    get_secret_key,
    release_lease,
    restart_workload,
    secret_exists,
)

# The only keys the 'get' subcommand may read, mapped to the complete
# set of values it may print. 'get' exists solely so the bootstrap
# shell script can read these bookkeeping fields via command
# substitution; restricting output to these vetted literals guarantees
# no Secret material (key bytes, passwords) can ever reach stdout or a
# pod log, regardless of how the tool is invoked.
PRINTABLE_KEYS: dict[str, frozenset[str]] = {
    "state": frozenset({"complete", "in-progress"}),
    "rotation-required": frozenset({"true", "false"}),
}

# Printed when a bookkeeping key holds a value outside its vetted set
# (for example a hand-edited marker Secret). Callers treat it as "not
# any recognized value": the state machine fails closed on it, and
# boolean comparisons come out false.
UNRECOGNIZED = "unrecognized"


def vetted_output(key: str, value: str) -> str:
    """Map a bookkeeping value onto a literal safe to print.

    Returns the matching constant from PRINTABLE_KEYS, or the
    UNRECOGNIZED sentinel. The return value is always one of these
    fixed literals - never the Secret-derived string itself - so
    nothing read from the Kubernetes API can flow to stdout.
    """
    for candidate in sorted(PRINTABLE_KEYS[key]):
        if value == candidate:
            return candidate
    return UNRECOGNIZED


def cmd_exists(args: argparse.Namespace) -> int:
    wanted: list[str] = list(args.key)  # pyright: ignore[reportAny]
    return 0 if secret_exists(str(args.name), wanted) else 1  # pyright: ignore[reportAny]


def cmd_get(args: argparse.Namespace) -> int:
    key = str(args.key)  # pyright: ignore[reportAny]
    value = get_secret_key(str(args.name), key)  # pyright: ignore[reportAny]
    if value is None:
        return 1
    print(vetted_output(key, value))
    return 0


def cmd_apply(args: argparse.Namespace) -> int:
    files: list[str] = list(args.file)  # pyright: ignore[reportAny]
    literals: list[str] = list(args.literal)  # pyright: ignore[reportAny]
    apply_secret(str(args.name), files, literals, bool(args.if_absent))  # pyright: ignore[reportAny]
    return 0


def cmd_restart(args: argparse.Namespace) -> int:
    restart_workload(str(args.kind), str(args.name))  # pyright: ignore[reportAny]
    return 0


def cmd_lock(args: argparse.Namespace) -> int:
    return acquire_lease(
        str(args.name),  # pyright: ignore[reportAny]
        str(args.identity),  # pyright: ignore[reportAny]
        int(args.duration),  # pyright: ignore[reportAny]
    )


def cmd_unlock(args: argparse.Namespace) -> int:
    release_lease(str(args.name), str(args.identity))  # pyright: ignore[reportAny]
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_exists = sub.add_parser("exists")
    _ = p_exists.add_argument("name")
    _ = p_exists.add_argument("--key", action="append", default=[])
    p_exists.set_defaults(handler=cmd_exists)
    p_get = sub.add_parser("get")
    _ = p_get.add_argument("name")
    _ = p_get.add_argument("key", choices=sorted(PRINTABLE_KEYS))
    p_get.set_defaults(handler=cmd_get)
    p_apply = sub.add_parser("apply")
    _ = p_apply.add_argument("name")
    _ = p_apply.add_argument("--file", action="append", default=[])
    _ = p_apply.add_argument("--literal", action="append", default=[])
    _ = p_apply.add_argument("--if-absent", action="store_true")
    p_apply.set_defaults(handler=cmd_apply)
    p_restart = sub.add_parser("restart")
    _ = p_restart.add_argument("kind", choices=["deployment", "statefulset"])
    _ = p_restart.add_argument("name")
    p_restart.set_defaults(handler=cmd_restart)
    p_lock = sub.add_parser("lock")
    _ = p_lock.add_argument("name")
    _ = p_lock.add_argument("--identity", required=True)
    _ = p_lock.add_argument("--duration", type=int, default=1800)
    p_lock.set_defaults(handler=cmd_lock)
    p_unlock = sub.add_parser("unlock")
    _ = p_unlock.add_argument("name")
    _ = p_unlock.add_argument("--identity", required=True)
    p_unlock.set_defaults(handler=cmd_unlock)
    args = parser.parse_args()

    handler = cast("Callable[[argparse.Namespace], int]", args.handler)
    return handler(args)


if __name__ == "__main__":
    sys.exit(main())
