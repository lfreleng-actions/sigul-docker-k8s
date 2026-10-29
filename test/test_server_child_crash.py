#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Regression test for the server's handling of request children that
# die (patch 22, #97).
#
# The parent forks one child per request. A child that died abnormally
# - an unhandled exception, an unknown exit status, a signal - used to
# end the parent's main loop, so one failing request stopped the server
# for every client until it was restarted. A death now fails only that
# request; only a crash loop, MAX_CHILD_DEATHS deaths within
# CHILD_DEATH_WINDOW_SECONDS, still ends the server, so its supervisor
# restarts a pod whose request path is broken.
#
# These checks drive the rule the main loop applies, server._child_died,
# with synthetic death times; scripts/run-lifecycle-tests.sh kills a real
# request child on the running stack.
#
# Run inside the sigul server image:
#   python3 test/test_server_child_crash.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAttributeAccessIssue=false
#
# server is upstream code this repository only patches, and ships no
# type stubs, so its members are untyped by nature.

import os
import sys

sys.path.insert(0, os.environ.get("SIGUL_LIB", "/usr/share/sigul"))

import server  # noqa: E402

FAILURES: list[str] = []

PATCHED = hasattr(server, "_child_died")


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def deaths_at(times: list[float]) -> tuple[list[float], list[bool]]:
    """Feed deaths at the given times; return the window and each verdict."""
    deaths: list[float] = []
    verdicts: list[bool] = []
    for now in times:
        deaths, crash_loop = server._child_died(deaths, now)
        verdicts.append(crash_loop)
    return deaths, verdicts


def test_single_death_keeps_serving() -> None:
    _, verdicts = deaths_at([1000.0])
    check(
        "one request child dying does not stop the server",
        verdicts == [False],
        f"verdict {verdicts[0]}",
    )


def test_crash_loop_stops_the_server() -> None:
    limit = server.MAX_CHILD_DEATHS
    _, verdicts = deaths_at([1000.0 + n for n in range(limit)])
    check(
        f"{limit} deaths within the window stop the server, and no fewer do",
        verdicts == [False] * (limit - 1) + [True],
        f"verdicts {verdicts}",
    )


def test_old_deaths_expire() -> None:
    limit = server.MAX_CHILD_DEATHS
    window = server.CHILD_DEATH_WINDOW_SECONDS
    times = [1000.0 + n for n in range(limit - 1)]
    times.append(1000.0 + window + limit)  # the earlier ones have expired
    deaths, verdicts = deaths_at(times)
    check(
        "deaths older than the window no longer count",
        verdicts[-1] is False and len(deaths) == 1,
        f"last verdict {verdicts[-1]}, deaths in window {len(deaths)}",
    )


def test_steady_trickle_never_stops() -> None:
    window = server.CHILD_DEATH_WINDOW_SECONDS
    spacing = window / (server.MAX_CHILD_DEATHS - 1) + 1
    _, verdicts = deaths_at([1000.0 + n * spacing for n in range(100)])
    check(
        "occasional deaths over a long run never stop the server",
        not any(verdicts),
        f"{len(verdicts)} deaths {spacing:.0f}s apart, {sum(verdicts)} stops",
    )


def main() -> int:
    print("Server request child crash regression tests")
    print(f"server: {'PATCHED' if PATCHED else 'UNPATCHED'}")
    print()
    if not PATCHED:
        check(
            "the server tolerates a request child's death",
            False,
            "server._child_died is missing: any child's death ends the server",
        )
    else:
        test_single_death_keeps_serving()
        test_crash_loop_stops_the_server()
        test_old_deaths_expire()
        test_steady_trickle_never_stops()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("a request child's death fails only its request; a crash loop exits")
    return 0


if __name__ == "__main__":
    sys.exit(main())
