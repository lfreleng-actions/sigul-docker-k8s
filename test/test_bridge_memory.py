#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for per-request memory growth in the bridge.
#
# The soak harness measured the bridge's memory growing by a constant
# ~5 kB per request, whatever the request type or payload size, and a
# referrer walk of a live daemon found every request's buffers and
# sockets still reachable from one module-level dict: double_tls's
# debug helper _id() recorded each object it labelled and never let go.
# The labels are only used as arguments to _debug(), which is a no-op,
# but Python evaluates arguments regardless, so the table filled on
# every request whether or not anyone was debugging (patch 16).
#
# The check is behavioural: it labels objects the way the bridge's
# buffers are labelled and asserts none of them outlives its last
# reference.
#
# Run inside the sigul bridge image:
#   python3 test/test_bridge_memory.py

# pyright: reportUnknownMemberType=false, reportAttributeAccessIssue=false
# pyright: reportUnknownVariableType=false, reportUnknownArgumentType=false
#
# double_tls is upstream code this repository only patches, and ships
# no type stubs, so its members are untyped by nature.

import gc
import os
import sys
import weakref

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import double_tls  # noqa: E402

FAILURES: list[str] = []

ITERATIONS = 1000


class _Labelled:
    """Stands in for a buffer or socket the bridge labels per request."""


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def test_labelled_objects_are_released() -> None:
    refs: list[weakref.ref[_Labelled]] = []
    for _ in range(ITERATIONS):
        obj = _Labelled()
        _ = double_tls._id(obj)
        refs.append(weakref.ref(obj))
        del obj
    _ = gc.collect()
    alive = sum(1 for r in refs if r() is not None)
    check(
        "objects labelled for debug output are released",
        alive == 0,
        f"{alive} of {ITERATIONS} still alive",
    )


def test_labels_are_stable() -> None:
    # Debug output is only readable if an object keeps one label.
    obj = _Labelled()
    first = double_tls._id(obj)
    check(
        "an object keeps its label",
        double_tls._id(obj) == first,
        f"label {first!r}",
    )


def main() -> int:
    print("Bridge per-request memory regression tests")
    print()
    test_labelled_objects_are_released()
    test_labels_are_stable()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("nothing the bridge labels per request outlives it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
