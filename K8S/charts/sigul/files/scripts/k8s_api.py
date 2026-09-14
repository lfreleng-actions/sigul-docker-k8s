# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""Kubernetes API layer for the sigul PKI bootstrap Job.

Imported by publish-secrets.py, which ships alongside this module in
the scripts ConfigMap (/scripts inside the Job pod). Talks to the API
server directly with the pod's ServiceAccount token so the Job can run
in the sigul bridge image (python3 + requests available) without
shipping kubectl.

The PKI bootstrap lock lives in its sibling k8s_lease.py, which builds
on the primitives here.
"""

import base64
import datetime
import os
import sys
from typing import cast

import requests

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
TIMEOUT = 30


def api_base() -> tuple[str, dict[str, str], str]:
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    with open(f"{SA_DIR}/token", encoding="utf-8") as fh:
        token = fh.read().strip()
    with open(f"{SA_DIR}/namespace", encoding="utf-8") as fh:
        namespace = fh.read().strip()
    base = f"https://{host}:{port}"
    headers = {"Authorization": f"Bearer {token}"}
    return base, headers, namespace


def get_secret(name: str) -> requests.Response:
    base, headers, namespace = api_base()
    return requests.get(
        f"{base}/api/v1/namespaces/{namespace}/secrets/{name}",
        headers=headers,
        verify=f"{SA_DIR}/ca.crt",
        timeout=TIMEOUT,
    )


def secret_exists(name: str, keys: list[str] | None = None) -> bool:
    """True when the Secret is populated and satisfies its key contract.

    The chart pre-creates all Secrets empty (so RBAC needs no
    'create' verb); an empty data map therefore means 'not yet
    bootstrapped'.

    A non-empty data map is not sufficient on its own: a Secret
    restored from a partial backup can hold some keys and not others,
    and the workloads would then fail on a missing secretKeyRef long
    after the bootstrap Job reported success. Callers pass the exact
    keys they depend on, and every one must be present and non-empty.
    """
    resp = get_secret(name)
    if resp.status_code == 404:
        return False
    if resp.status_code != 200:
        resp.raise_for_status()
        return False  # unreachable; keeps type-checkers happy
    body = cast("dict[str, object]", resp.json())
    data = cast("dict[str, str]", body.get("data") or {})
    if not data:
        return False
    missing = [k for k in (keys or []) if not data.get(k)]
    if missing:
        msg = (
            f"[publish-secrets] Secret {name} is missing or has empty"
            + f" keys: {', '.join(missing)}"
        )
        print(msg, file=sys.stderr)
        return False
    return True


def get_secret_key(name: str, key: str) -> str | None:
    """Decoded value of KEY, or None if the Secret or key is absent."""
    resp = get_secret(name)
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    body = cast("dict[str, object]", resp.json())
    data = cast("dict[str, str]", body.get("data") or {})
    encoded = data.get(key)
    if encoded is None:
        return None
    return base64.b64decode(encoded).decode("utf-8")


def apply_secret(
    name: str, files: list[str], literals: list[str], if_absent: bool
) -> None:
    data: dict[str, str] = {}
    for spec in files:
        key, _, path = spec.partition("=")
        with open(path, "rb") as fh:
            data[key] = base64.b64encode(fh.read()).decode("ascii")
    for spec in literals:
        key, _, value = spec.partition("=")
        data[key] = base64.b64encode(value.encode("utf-8")).decode("ascii")

    base, headers, namespace = api_base()
    ca_path = f"{SA_DIR}/ca.crt"

    existing = get_secret(name)
    if existing.status_code != 200:
        # The chart pre-creates every Secret this Job writes to, and
        # the Role deliberately lacks 'create'. A missing object means
        # the release is broken (e.g. someone deleted it) - surface
        # that clearly instead of a confusing 403.
        existing.raise_for_status()
        msg = (
            f"[publish-secrets] Secret {namespace}/{name} does not exist;"
            + " it should be pre-created by the Helm chart"
            + " (templates/secrets.yaml). Re-sync the release."
        )
        raise SystemExit(msg)

    existing_body = cast("dict[str, object]", existing.json())
    existing_data = existing_body.get("data")
    if if_absent and existing_data:
        msg = (
            f"[publish-secrets] Secret {namespace}/{name} already"
            + " populated; left untouched (--if-absent)"
        )
        print(msg, file=sys.stderr)
        return

    # JSON merge-patch touching ONLY /data: metadata (labels etc.)
    # stays owned by the Helm chart / Argo field managers - a full
    # PUT was observed stealing label ownership and causing
    # server-side-apply conflicts on subsequent Helm/Argo syncs.
    # resourceVersion is included for optimistic concurrency: a
    # concurrent writer produces a clean 409 and the Job retries.
    current_meta = cast("dict[str, object]", existing_body.get("metadata") or {})
    rv = str(current_meta.get("resourceVersion") or "")
    patch: dict[str, object] = {"data": data}
    if rv:
        patch["metadata"] = {"resourceVersion": rv}
    patch_headers = dict(headers)
    patch_headers["Content-Type"] = "application/merge-patch+json"
    resp = requests.patch(
        f"{base}/api/v1/namespaces/{namespace}/secrets/{name}",
        json=patch,
        headers=patch_headers,
        verify=ca_path,
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    print(f"[publish-secrets] applied Secret {namespace}/{name}", file=sys.stderr)


def restart_workload(kind: str, name: str) -> None:
    plurals = {"deployment": "deployments", "statefulset": "statefulsets"}
    plural = plurals[kind]
    base, headers, namespace = api_base()
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    patch = {
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        "sigul.linuxfoundation.org/restarted-at": now,
                    }
                }
            }
        }
    }
    patch_headers = dict(headers)
    patch_headers["Content-Type"] = "application/strategic-merge-patch+json"
    resp = requests.patch(
        f"{base}/apis/apps/v1/namespaces/{namespace}/{plural}/{name}",
        json=patch,
        headers=patch_headers,
        verify=f"{SA_DIR}/ca.crt",
        timeout=TIMEOUT,
    )
    if resp.status_code == 404:
        # First install with pki.mode=force: the wave -1 hook runs
        # before the workloads exist. Nothing to restart yet - the
        # pods will start on the freshly published PKI anyway.
        msg = (
            f"[publish-secrets] {kind} {namespace}/{name} not found;"
            + " skipping restart (nothing running on the old PKI)"
        )
        print(msg, file=sys.stderr)
        return
    resp.raise_for_status()
    msg = (
        f"[publish-secrets] triggered rolling restart of {kind}"
        + f" {namespace}/{name}"
    )
    print(msg, file=sys.stderr)
