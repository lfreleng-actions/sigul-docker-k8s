#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Verify patch 01's ordering in the installed bridge: within
# bridge_one_request(), the server's TLS handshake runs after the
# server is accepted and before any client is waited for.
#
# Patch 01 exists because upstream deferred the server handshake until
# a client arrived, which let it time out with PR_END_OF_FILE_ERROR.
# What matters is therefore order, and this checks order on the parsed
# code rather than on its text. An earlier version looked for the
# literal "accept()" within ten lines of the handshake, and broke - with
# the order still correct - when patch 15 bounded the accept inside a
# loop: the call gained an argument and moved fourteen lines away.
# Comments, formatting and distance cannot affect this one.
#
# Run inside the bridge image:
#   python3 test/verify_bridge_handshake_order.py

import ast
import os
import sys

SOURCE = os.path.join(os.environ.get("SIGUL_LIB", "/usr/share/sigul"), "bridge.py")


def _call_lines(func: ast.FunctionDef) -> dict[str, list[int]]:
    """Lines of the calls this check cares about, by what they are."""
    found: dict[str, list[int]] = {"accept": [], "handshake": [], "wait": []}
    for node in ast.walk(func):
        if not isinstance(node, ast.Call):
            continue
        target = node.func
        if isinstance(target, ast.Attribute):
            owner = target.value
            if (
                target.attr == "accept"
                and isinstance(owner, ast.Name)
                and owner.id == "server_listen_sock"
            ):
                found["accept"].append(node.lineno)
            elif target.attr == "wait_for_client":
                found["wait"].append(node.lineno)
        elif isinstance(target, ast.Name) and target.id == "_handshake_with_deadline":
            first = node.args[0] if node.args else None
            if isinstance(first, ast.Name) and first.id == "server_sock":
                found["handshake"].append(node.lineno)
    return found


def main() -> int:
    with open(SOURCE, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), SOURCE)
    funcs = [
        n
        for n in ast.walk(tree)
        if isinstance(n, ast.FunctionDef) and n.name == "bridge_one_request"
    ]
    if len(funcs) != 1:
        print(
            f"ERROR: expected one bridge_one_request() in {SOURCE}, found {len(funcs)}"
        )
        return 1
    lines = _call_lines(funcs[0])
    for what, where in lines.items():
        if len(where) != 1:
            print(
                f"ERROR: expected one {what} call in bridge_one_request(), found {where}"
            )
            return 1
    accept, handshake, wait = (
        lines["accept"][0],
        lines["handshake"][0],
        lines["wait"][0],
    )
    print(f"server accept      line {accept}")
    print(f"server handshake   line {handshake}")
    print(f"wait for client    line {wait}")
    if not accept < handshake < wait:
        print(
            "ERROR: the server handshake must follow the accept and precede "
            + "the wait for a client (patch 01)"
        )
        return 1
    print("server handshake runs after accept and before any client: patch 01 holds")
    return 0


if __name__ == "__main__":
    sys.exit(main())
