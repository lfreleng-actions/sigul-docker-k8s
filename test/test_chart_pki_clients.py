#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Render tests for the chart's per-client certificates (pki.clients,
# #104).
#
# Renders K8S/charts/sigul with helm and checks what the bootstrap Job
# may write against what the chart creates and mounts:
#   - one pre-created, deletion-protected Secret per client, and no
#     shared client Secret, when pki.clients is set
#   - the bootstrap Role reaches exactly the Secrets the chart creates,
#     and never holds "create" on Secrets
#   - the Job is told the same client names and Secret prefix
#   - the admin toolbox mounts server.adminUser's own certificate, and
#     make-bundle.sh with the template it renders
#   - the default render keeps the single shared client Secret
#   - invalid client lists fail the render with a clear message
#
# Needs helm and PyYAML on the host:
#   python3 test/test_chart_pki_clients.py

# pyright: reportUnknownMemberType=false, reportUnknownArgumentType=false
# pyright: reportUnknownVariableType=false, reportAny=false
# pyright: reportExplicitAny=false
#
# Rendered manifests are untyped YAML by nature.

import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml  # pyright: ignore[reportMissingModuleSource]

CHART = Path(__file__).resolve().parent.parent / "K8S/charts/sigul"
RELEASE = "sigul"

FAILURES: list[str] = []

STRICT = ["--set", "server.lenientUsernameCheck=no"]
CLIENTS = ["admin", "opensearch-canary", "release.bot"]


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


def render(*args: str) -> list[dict[str, Any]]:
    done = helm(*args)
    if done.returncode != 0:
        raise SystemExit(f"helm template {' '.join(args)} failed:\n{done.stderr}")
    return [d for d in yaml.safe_load_all(done.stdout) if d]


def client_args(names: list[str]) -> list[str]:
    out = list(STRICT)
    for i, name in enumerate(names):
        out += ["--set", f"pki.clients[{i}].name={name}"]
    return out


def find(docs: list[dict[str, Any]], kind: str, suffix: str) -> dict[str, Any]:
    for doc in docs:
        if doc["kind"] == kind and doc["metadata"]["name"].endswith(suffix):
            return doc
    raise SystemExit(f"no {kind} named *{suffix} in the render")


def secrets(docs: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {d["metadata"]["name"]: d for d in docs if d["kind"] == "Secret"}


def role_secret_rules(docs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    role = find(docs, "Role", "-pki-bootstrap")
    return [r for r in role["rules"] if "secrets" in r.get("resources", [])]


def job_env(docs: list[dict[str, Any]]) -> dict[str, str]:
    job = next(
        d
        for d in docs
        if d["kind"] == "Job" and "pki-bootstrap" in d["metadata"]["name"]
    )
    container = job["spec"]["template"]["spec"]["containers"][0]
    return {e["name"]: e.get("value", "") for e in container["env"]}


def toolbox_client_secret(docs: list[dict[str, Any]]) -> str:
    toolbox = find(docs, "Deployment", "-admin-toolbox")
    found = ""
    for volume in toolbox["spec"]["template"]["spec"]["volumes"]:
        for source in volume.get("projected", {}).get("sources", []):
            secret = source.get("secret", {})
            if any(i.get("key") == "client.p12" for i in secret.get("items", [])):
                found = secret["name"]
    return found


def test_per_client_render() -> None:
    docs = render(*client_args(CLIENTS), "--set", "adminToolbox.enabled=true")
    rendered = secrets(docs)
    wanted = {f"{RELEASE}-client-{c}-p12" for c in CLIENTS}
    check(
        "one Secret per client is pre-created",
        wanted <= set(rendered),
        f"{sorted(wanted - set(rendered)) or 'all present'}",
    )
    check(
        "no shared client Secret is created",
        f"{RELEASE}-client-p12" not in rendered,
        f"Secrets {sorted(rendered)}",
    )
    for name in sorted(wanted & set(rendered)):
        notes = rendered[name]["metadata"].get("annotations", {})
        check(
            f"{name} is protected like the other PKI Secrets",
            notes.get("helm.sh/resource-policy") == "keep"
            and notes.get("argocd.argoproj.io/sync-options")
            == "Prune=false,Delete=false"
            and notes.get("argocd.argoproj.io/sync-wave") == "-2",
            f"annotations {notes}",
        )

    rules = role_secret_rules(docs)
    reachable = {n for r in rules for n in r.get("resourceNames", [])}
    check(
        "the bootstrap Role reaches exactly the Secrets the chart creates",
        reachable == set(rendered),
        f"only Role {sorted(reachable - set(rendered))}, "
        + f"only chart {sorted(set(rendered) - reachable)}",
    )
    check(
        "the bootstrap Role cannot create Secrets",
        all("create" not in r["verbs"] and r.get("resourceNames") for r in rules),
        f"verbs {[r['verbs'] for r in rules]}",
    )

    env = job_env(docs)
    check(
        "the Job is given the client names, prefix and strict checking",
        env.get("PKI_CLIENTS") == " ".join(CLIENTS)
        and env.get("SECRET_CLIENT_P12_PREFIX") == f"{RELEASE}-client-"
        and env.get("ADMIN_USER") == "admin"
        and env.get("LENIENT_USERNAME_CHECK") == "no"
        and "SECRET_CLIENT_P12" not in env,
        f"PKI_CLIENTS={env.get('PKI_CLIENTS')!r}, "
        + f"prefix={env.get('SECRET_CLIENT_P12_PREFIX')!r}",
    )
    check(
        "the admin toolbox mounts the admin's own certificate",
        toolbox_client_secret(docs) == f"{RELEASE}-client-admin-p12",
        f"mounts {toolbox_client_secret(docs)!r}",
    )
    toolbox = find(docs, "Deployment", "-admin-toolbox")["spec"]["template"]["spec"]
    mounts = {
        m["mountPath"]: m["name"] for m in toolbox["containers"][0]["volumeMounts"]
    }
    scripts = find(docs, "ConfigMap", "-scripts")["data"]
    bundler = (CHART / "files/toolbox/make-bundle.sh").read_text()
    check(
        "the admin toolbox carries make-bundle.sh and client.conf.template",
        mounts.get("/scripts") == "scripts"
        and mounts.get("/conf-templates") == "conf-templates"
        and scripts.get("make-bundle.sh") == bundler,
        f"mounts {mounts}",
    )

    server = find(docs, "StatefulSet", "-server")
    pod = server["spec"]["template"]["spec"]
    server_env = {
        e["name"]: e.get("value", "")
        for c in pod.get("initContainers", []) + pod["containers"]
        for e in c.get("env", [])
    }
    check(
        "the server enforces cert CN == user name",
        server_env.get("LENIENT_USERNAME_CHECK") == "no",
        f"LENIENT_USERNAME_CHECK={server_env.get('LENIENT_USERNAME_CHECK')!r}",
    )


def test_default_render() -> None:
    docs = render("--set", "adminToolbox.enabled=true")
    rendered = secrets(docs)
    shared = f"{RELEASE}-client-p12"
    check(
        "without pki.clients the shared client Secret is created",
        shared in rendered
        and not any(
            n.startswith(f"{RELEASE}-client-") and n != shared for n in rendered
        ),
        f"Secrets {sorted(rendered)}",
    )
    reachable = {n for r in role_secret_rules(docs) for n in r.get("resourceNames", [])}
    check(
        "the default Role still reaches exactly the chart's Secrets",
        reachable == set(rendered),
        f"{sorted(reachable ^ set(rendered)) or 'match'}",
    )
    env = job_env(docs)
    check(
        "the default Job publishes the shared bundle",
        env.get("SECRET_CLIENT_P12") == shared and "PKI_CLIENTS" not in env,
        f"SECRET_CLIENT_P12={env.get('SECRET_CLIENT_P12')!r}",
    )
    check(
        "the default toolbox mounts the shared bundle",
        toolbox_client_secret(docs) == shared,
        f"mounts {toolbox_client_secret(docs)!r}",
    )


def test_rejected_values() -> None:
    cases = [
        (
            "an upper-case name",
            client_args(["admin", "Canary"]),
            "not a valid Sigul user name",
        ),
        (
            "a name with '_'",
            client_args(["admin", "ci_bot"]),
            "not a valid Sigul user name",
        ),
        *(
            (
                f"a name with {bad!r}",
                client_args(["admin", f"ci{bad}bot"]),
                "not a valid Sigul user name",
            )
            for bad in ("..", ".-", "-.")
        ),
        (
            "a 64-character name",
            client_args(["admin", "a" * 64]),
            "not a valid Sigul user name",
        ),
        ("a duplicate name", client_args(["admin", "ci", "admin"]), "more than once"),
        (
            "a list without the admin",
            client_args(["ci"]),
            "must include server.adminUser",
        ),
        (
            "lenient username checking",
            ["--set", "pki.clients[0].name=admin"],
            "server.lenientUsernameCheck",
        ),
        (
            "an entry that is not a map",
            [*STRICT, "--set", "pki.clients[0]=admin"],
            "must be a map",
        ),
    ]
    for label, args, message in cases:
        done = helm(*args)
        check(
            f"{label} fails the render",
            done.returncode != 0 and message in done.stderr,
            done.stderr.strip().splitlines()[0][:160] if done.stderr else "rendered",
        )
    accepted = helm(*client_args(["admin", "a" * 63, "ci.bot-2", "a-b.c-d.e"]))
    check(
        "names up to 63 characters with '.' and '-' render",
        accepted.returncode == 0,
        accepted.stderr.strip()[:160] or "rendered",
    )


def main() -> int:
    print("Chart render tests for per-client certificates")
    print(f"chart: {CHART}")
    print()
    test_per_client_render()
    test_default_render()
    test_rejected_values()
    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("pki.clients renders one protected, Role-scoped Secret per client")
    return 0


if __name__ == "__main__":
    sys.exit(main())
