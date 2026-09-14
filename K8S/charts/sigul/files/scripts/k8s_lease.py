# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""Bootstrap lock for the sigul PKI Job, backed by a coordination Lease.

Split from k8s_api.py, which stays the generic API layer: this module
owns one concern, mutual exclusion between concurrent bootstrap runners,
and the timing rules that go with it. Mounted alongside its sibling from
the scripts ConfigMap.

Acquisition is a compare-and-set on the Lease's resourceVersion, so the
API server admits exactly one runner. The chart renders the object
(templates/lease.yaml), but Argo CD discards it -
coordination.k8s.io/Lease is in Argo's compiled-in core exclusion list -
so this module creates it when it is absent.

Every entry point costs at most two sequential requests. pki-bootstrap.sh
wraps each publish-secrets invocation in `timeout 70`, sized for exactly
that; a third would let the wrapper kill a runner mid-create, stranding
the lock under a dead pod's identity until it expires.
"""

import datetime
import json
import os
import sys
import time
from typing import cast

import requests
from k8s_api import SA_DIR, TIMEOUT, api_base

# How long to wait for someone else's Lease to appear before creating
# it. templates/lease.yaml renders the object, but Helm's kind sorter
# places the unrecognised Lease kind *after* Job, so on a fresh install
# the Job manifest is submitted a few milliseconds before the Lease is.
# Waiting here lets Helm's own create land first; only Argo CD, which
# discards the manifest outright, ever reaches the end of the window.
#
# The window has to be free in budget terms, not just cheap in the
# common case (see the two-request budget above). So a poll is started
# only while its own timeout still fits inside the window, and the poll
# timeout is short enough for several to fit. A slow first read then
# consumes the window rather than extending past it, keeping the whole
# read within one TIMEOUT.
LEASE_WAIT_SECONDS = 15
LEASE_POLL_SECONDS = 1
LEASE_POLL_TIMEOUT = 5


def _lease_url(base: str, namespace: str, name: str) -> str:
    return f"{base}/apis/coordination.k8s.io/v1/namespaces/{namespace}/leases/{name}"


def _now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def _parse_ts(value: str) -> datetime.datetime | None:
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def _lease_metadata(name: str, namespace: str) -> dict[str, object]:
    """Metadata for a Job-created Lease, matching the chart's own.

    LOCK_LEASE_METADATA carries the labels and annotations rendered by
    templates/lease.yaml, so a Lease this Job creates is indistinguishable
    in metadata from one Helm created. That matters beyond tidiness: Helm
    refuses to install over an object it does not own, and adopts one
    whose managed-by label and meta.helm.sh/release-* annotations match
    the release. Stamping them here keeps a Job-created Lease adoptable,
    so a release installed under Argo CD can later be managed with plain
    Helm, and an install that lost the create race is retryable.

    It does not rescue the install being raced. Helm fixes its adoption
    set before creating anything, so a Lease appearing after that
    preflight still fails that install with AlreadyExists; the next one
    adopts it. See the note in templates/lease.yaml.
    """
    meta: dict[str, object] = {"name": name, "namespace": namespace}
    rendered = os.environ.get("LOCK_LEASE_METADATA", "").strip()
    if rendered:
        meta.update(cast("dict[str, object]", json.loads(rendered)))
    return meta


def _create_lease(name: str, identity: str, duration: int) -> int:
    """Create the bootstrap Lease, already held by this identity.

    Returns 0 when this runner created and therefore holds it, and 1
    when another actor created it first (409 Conflict), which the
    caller treats as losing the lock.

    Creating it held, rather than creating it empty and acquiring in a
    second call, keeps acquisition a single atomic operation: there is
    no window in which the Lease exists unheld.
    """
    base, headers, namespace = api_base()
    now = _now().strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    body = {
        "apiVersion": "coordination.k8s.io/v1",
        "kind": "Lease",
        "metadata": _lease_metadata(name, namespace),
        "spec": {
            "holderIdentity": identity,
            "leaseDurationSeconds": duration,
            "acquireTime": now,
            "renewTime": now,
        },
    }
    resp = requests.post(
        f"{base}/apis/coordination.k8s.io/v1/namespaces/{namespace}/leases",
        json=body,
        headers=headers,
        verify=f"{SA_DIR}/ca.crt",
        timeout=TIMEOUT,
    )
    if resp.status_code == 409:
        # Someone else created it between our read and this POST.
        print(
            f"[publish-secrets] Lease {namespace}/{name} created"
            + " concurrently; backing off for the Job to retry",
            file=sys.stderr,
        )
        return 1
    resp.raise_for_status()
    print(
        f"[publish-secrets] created and acquired Lease {namespace}/{name}",
        file=sys.stderr,
    )
    return 0


def _read_lease(url: str, headers: dict[str, str]) -> requests.Response:
    """Read the Lease, re-polling a 404 before reporting it absent.

    Returns the first non-404 response, or the last 404 once the window
    closes. Under Helm the Lease arrives within milliseconds of the Job
    manifest, so a 404 clears at once and the Job never creates the
    object; under Argo CD nothing ever arrives and the full window
    elapses once, ahead of PKI generation that takes far longer.

    Bounded so the whole call cannot outlast a single TIMEOUT: a poll
    is started only while its own timeout still fits inside the window,
    and a slow first read consumes the window instead of extending it.
    That keeps lock acquisition at two sequential requests, which is
    what pki-bootstrap.sh's 70s wrapper budgets for.
    """
    deadline = time.monotonic() + LEASE_WAIT_SECONDS
    resp = requests.get(
        url, headers=headers, verify=f"{SA_DIR}/ca.crt", timeout=TIMEOUT
    )
    reserve = LEASE_POLL_SECONDS + LEASE_POLL_TIMEOUT
    while resp.status_code == 404 and time.monotonic() + reserve <= deadline:
        time.sleep(LEASE_POLL_SECONDS)
        try:
            resp = requests.get(
                url,
                headers=headers,
                verify=f"{SA_DIR}/ca.crt",
                timeout=LEASE_POLL_TIMEOUT,
            )
        except requests.RequestException as exc:
            # Opportunistic, so a failed poll is not fatal: retrying it
            # would eat the reserve the create still needs. Keep the
            # last 404 and fall through, where a concurrent creator
            # still shows up as a 409 on the POST.
            print(
                f"[publish-secrets] Lease poll failed ({exc}); continuing",
                file=sys.stderr,
            )
            break
    return resp


def acquire_lease(name: str, identity: str, duration: int) -> int:
    """Compare-and-set acquisition of the bootstrap Lease.

    Returns 0 when this identity holds the lease afterwards, 1 when
    another runner holds an unexpired lease or won the race. The
    conditional patch (carrying the observed resourceVersion) is what
    makes concurrent bootstrap Jobs mutually exclusive: the API server
    admits exactly one of them.

    The Lease is created here when it is absent. templates/lease.yaml
    renders one for plain Helm, but Argo CD cannot manage it:
    coordination.k8s.io/Lease is in its *core* exclusion list, which is
    compiled in and cannot be re-enabled by resource.inclusions, so the
    rendered Lease is silently dropped on every Argo CD installation
    and the Job would otherwise find nothing to lock against.

    A 404 is therefore re-polled for LEASE_WAIT_SECONDS before this Job
    creates the object itself, so that whenever the chart's own Lease is
    going to arrive it arrives first and Helm remains its sole creator.
    Every path here costs at most two sequential requests, the budget
    pki-bootstrap.sh's 70s wrapper is sized for.
    """
    base, headers, namespace = api_base()
    url = _lease_url(base, namespace, name)
    resp = _read_lease(url, headers)
    if resp.status_code == 404:
        # Losing this race means backing off, not re-reading. A runner
        # that creates the Lease creates it held, so the winner is
        # already working and the Job's backoff retries once it has
        # finished. Re-reading would make acquisition a third
        # sequential request, past what pki-bootstrap.sh's wrapper
        # allows the subcommand. The one case that costs a retry it
        # need not - the chart's own unheld Lease landing inside our
        # POST - is what the wait window above already makes remote.
        return _create_lease(name, identity, duration)
    resp.raise_for_status()
    body = cast("dict[str, object]", resp.json())
    spec = cast("dict[str, object]", body.get("spec") or {})
    holder = str(spec.get("holderIdentity") or "")
    renewed = _parse_ts(str(spec.get("renewTime") or ""))
    held_for = int(cast("int", spec.get("leaseDurationSeconds") or duration))

    if holder and holder != identity and renewed is not None:
        age = (_now() - renewed).total_seconds()
        if age < held_for:
            msg = (
                f"[publish-secrets] Lease {namespace}/{name} held by"
                + f" {holder} for another {int(held_for - age)}s"
            )
            print(msg, file=sys.stderr)
            return 1

    meta = cast("dict[str, object]", body.get("metadata") or {})
    # acquireTime/renewTime are MicroTime: RFC3339 with exactly
    # microsecond precision. Anything else is rejected with a 422.
    now = _now().strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    patch: dict[str, object] = {
        "metadata": {"resourceVersion": str(meta.get("resourceVersion") or "")},
        "spec": {
            "holderIdentity": identity,
            "leaseDurationSeconds": duration,
            "acquireTime": now,
            "renewTime": now,
        },
    }
    patch_headers = dict(headers)
    patch_headers["Content-Type"] = "application/merge-patch+json"
    resp = requests.patch(
        url,
        json=patch,
        headers=patch_headers,
        verify=f"{SA_DIR}/ca.crt",
        timeout=TIMEOUT,
    )
    if resp.status_code == 409:
        # Another runner patched between our GET and PATCH; it won.
        print(
            f"[publish-secrets] lost the race for Lease {namespace}/{name}",
            file=sys.stderr,
        )
        return 1
    resp.raise_for_status()
    print(f"[publish-secrets] acquired Lease {namespace}/{name}", file=sys.stderr)
    return 0


def release_lease(name: str, identity: str) -> None:
    """Clear the Lease if this identity still holds it."""
    base, headers, namespace = api_base()
    url = _lease_url(base, namespace, name)
    resp = requests.get(
        url, headers=headers, verify=f"{SA_DIR}/ca.crt", timeout=TIMEOUT
    )
    if resp.status_code == 404:
        return
    resp.raise_for_status()
    body = cast("dict[str, object]", resp.json())
    spec = cast("dict[str, object]", body.get("spec") or {})
    if str(spec.get("holderIdentity") or "") != identity:
        return
    meta = cast("dict[str, object]", body.get("metadata") or {})
    patch: dict[str, object] = {
        "metadata": {"resourceVersion": str(meta.get("resourceVersion") or "")},
        "spec": {"holderIdentity": None, "acquireTime": None, "renewTime": None},
    }
    patch_headers = dict(headers)
    patch_headers["Content-Type"] = "application/merge-patch+json"
    resp = requests.patch(
        url,
        json=patch,
        headers=patch_headers,
        verify=f"{SA_DIR}/ca.crt",
        timeout=TIMEOUT,
    )
    if resp.status_code != 409:
        resp.raise_for_status()
    print(f"[publish-secrets] released Lease {namespace}/{name}", file=sys.stderr)
