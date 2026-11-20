# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Render tests for the chart's large-file limits (#156):
# server.maxFilePayloadSize and server.requestTimeoutSeconds.
#
# Renders K8S/charts/sigul with helm and checks what the server's
# nss-init container is given to write into server.conf:
#   - the defaults are the limits the chart had before they were values
#   - a value reaches the container as plain decimal digits whether it
#     came from --set (an integer), a values file (a float, which
#     prints as 8.589934592e+09 unless converted) or a quoted string
#   - zero, a negative number, a fraction, a word and a value above
#     the maximum each fail the render, naming the value
#   - server.conf.template takes both from nss-init.sh, whose
#     fallbacks are the chart's defaults
#
# Needs helm and PyYAML on the host:
#   python3 test/test_chart_large_file_limits.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAny=false
# pyright: reportExplicitAny=false
#
# Rendered manifests are untyped YAML by nature.

import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import yaml  # pyright: ignore[reportMissingModuleSource]

CHART = Path(__file__).resolve().parent.parent / "K8S/charts/sigul"
RELEASE = "sigul"

FAILURES: list[str] = []

PAYLOAD = "server.maxFilePayloadSize"
TIMEOUT = "server.requestTimeoutSeconds"
DEFAULTS = {"MAX_FILE_PAYLOAD_SIZE": "1073741824", "REQUEST_TIMEOUT_SECONDS": "3600"}
# 8 GiB, above 2^32, and six hours.
RAISED = {"MAX_FILE_PAYLOAD_SIZE": "8589934592", "REQUEST_TIMEOUT_SECONDS": "21600"}
# The largest values the chart accepts: every integer up to the first
# survives a values file's float, and signal.alarm() takes the second.
LARGEST = {
    "MAX_FILE_PAYLOAD_SIZE": "9007199254740991",
    "REQUEST_TIMEOUT_SECONDS": "2147483647",
}
REFUSED = {
    "zero": "0",
    "a negative number": "-1",
    "a fraction": "1.5",
    "a word": "large",
}
TOO_LARGE = {PAYLOAD: "9007199254740992", TIMEOUT: "2147483648"}


def check(label: str, ok: bool, detail: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}: {detail}")
    if not ok:
        FAILURES.append(label)


def helm(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["helm", "template", RELEASE, str(CHART), "--namespace", "sigul", *args],
        capture_output=True,
        text=True,
        check=False,
    )


def from_set(payload: str, timeout: str) -> list[str]:
    return ["--set", f"{PAYLOAD}={payload}", "--set", f"{TIMEOUT}={timeout}"]


def from_file(directory: str, payload: str, timeout: str) -> list[str]:
    """The same two values as a values file, written as given: bare
    digits are a YAML number, which helm reads as a float. Each call
    writes a file of its own, so one built before another is rendered
    still holds what it was given."""
    with tempfile.NamedTemporaryFile(
        "w", dir=directory, prefix="values-", suffix=".yaml", delete=False
    ) as file:
        _ = file.write(
            f"server:\n  maxFilePayloadSize: {payload}\n"
            + f"  requestTimeoutSeconds: {timeout}\n"
        )
    return ["-f", file.name]


def documents(done: subprocess.CompletedProcess[str]) -> list[dict[str, Any]]:
    if done.returncode != 0:
        raise SystemExit(f"helm template failed:\n{done.stderr}")
    return [d for d in yaml.safe_load_all(done.stdout) if d]


def find(docs: list[dict[str, Any]], kind: str, suffix: str) -> dict[str, Any]:
    for doc in docs:
        if doc["kind"] == kind and doc["metadata"]["name"].endswith(suffix):
            return doc
    raise SystemExit(f"no {kind} named *{suffix} in the render")


def limits(docs: list[dict[str, Any]]) -> dict[str, Any]:
    """What the server's nss-init container, which writes server.conf,
    is given for the two limits. Values as the manifest holds them."""
    pod = find(docs, "StatefulSet", "-server")["spec"]["template"]["spec"]
    init = next(c for c in pod["initContainers"] if c["name"] == "nss-init")
    return {e["name"]: e.get("value") for e in init["env"] if e["name"] in DEFAULTS}


def test_defaults() -> None:
    got = limits(documents(helm()))
    check(
        "the defaults are 1 GiB and one hour",
        got == DEFAULTS,
        f"{got}",
    )


def test_values_render_as_decimal_integers() -> None:
    with tempfile.TemporaryDirectory() as directory:
        for wanted in (RAISED, LARGEST):
            payload = wanted["MAX_FILE_PAYLOAD_SIZE"]
            timeout = wanted["REQUEST_TIMEOUT_SECONDS"]
            routes = {
                "--set": from_set(payload, timeout),
                "a values file": from_file(directory, payload, timeout),
                "a values file, quoted": from_file(
                    directory, f'"{payload}"', f'"{timeout}"'
                ),
                "--set-string": [
                    "--set-string",
                    f"{PAYLOAD}={payload}",
                    "--set-string",
                    f"{TIMEOUT}={timeout}",
                ],
            }
            for route, args in routes.items():
                got = limits(documents(helm(*args)))
                check(
                    f"{payload} and {timeout} through {route} are plain digits",
                    got == wanted,
                    f"{got}",
                )


def refused(label: str, name: str, args: list[str]) -> None:
    done = helm(*args)
    check(
        f"{label} fails the render",
        done.returncode != 0 and f"{name} must be a positive integer" in done.stderr,
        done.stderr.strip().splitlines()[0][-150:] if done.stderr else "rendered",
    )


def test_rejected_values() -> None:
    with tempfile.TemporaryDirectory() as directory:
        for name in (PAYLOAD, TIMEOUT):
            cases = {
                **REFUSED,
                f"{TOO_LARGE[name]}, above the maximum": TOO_LARGE[name],
            }
            for label, bad in cases.items():
                # The other value stays valid, so only this one can be
                # what fails the render.
                payload, timeout = (bad, "3600") if name == PAYLOAD else ("1024", bad)
                refused(f"{label} for {name}, --set", name, from_set(payload, timeout))
                refused(
                    f"{label} for {name}, a values file",
                    name,
                    from_file(directory, payload, timeout),
                )


def test_server_conf_takes_both() -> None:
    docs = documents(helm())
    template = find(docs, "ConfigMap", "-conf-templates")["data"][
        "server.conf.template"
    ]
    script = find(docs, "ConfigMap", "-scripts")["data"]["nss-init.sh"]
    lines = template.splitlines()
    check(
        "server.conf.template takes both limits from nss-init.sh",
        "max-file-payload-size: ${MAX_FILE_PAYLOAD_SIZE}" in lines
        and "request-timeout: ${REQUEST_TIMEOUT_SECONDS}" in lines,
        f"{[line for line in lines if 'payload-size' in line or 'timeout' in line]}",
    )
    for name, default in DEFAULTS.items():
        check(
            f"nss-init.sh substitutes {name}, falling back to the chart default",
            f"s|\\${{{name}}}|${{{name}:-{default}}}|g" in script,
            f"{[line.strip() for line in script.splitlines() if name in line]}",
        )


def main() -> int:
    print("Chart render tests for the large-file limits")
    print(f"chart: {CHART}")
    print()
    test_defaults()
    test_values_render_as_decimal_integers()
    test_rejected_values()
    test_server_conf_takes_both()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("both limits reach server.conf as plain decimal integers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
