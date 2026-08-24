<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 The Linux Foundation
-->

# Sigul Helm Chart

Deploys the Sigul signing infrastructure (bridge + server) on
Kubernetes. One release per tenant/project, each owning a private PKI
trust domain. Design rationale: see `../../docs/EVALUATION.md`.

## Status

**Functionally validated on Docker Desktop Kubernetes (2026-08-17):**
PKI bootstrap Job → Secrets → bridge Ready → server established
connection → admin auth → `new-key` (RSA 4096 GPG) → `sign-data` →
independent `gpg --verify` GOODSIG → server pod deleted/recreated →
key survived on PVC → signing works post-restart. All workloads run
non-root (UID 1000) with `readOnlyRootFilesystem` and all
capabilities dropped, using unmodified upstream images.

Remaining before production (EKS):

1. `pki.externalFQDN` is a placeholder until the production DNS name
   under the project domain is assigned.
2. Images are pinned to the `v0.1.6` release (multi-arch,
   Grype-gated, provenance/SBOM attested, public on GHCR with
   anonymous pulls verified).
3. Platform-team confirmations pending (EVALUATION.md §8.1): KMS CMK
   for the StorageClass, AppProject conventions, NodePool policy.
4. Known behavior: clients hitting the bridge during the server↔bridge
   reconnect window (a few seconds after a server restart) get
   `Unexpected EOF in NSPR`; retry succeeds. CI clients should use
   retries (sigul's own `retry-attempts` or workflow-level).

Operational notes discovered during validation (encoded in the
templates as comments):

- **Never point tcpSocket/nc probes at the bridge** - accepted bare
  connections break its serial accept loop (44333 handshake errors,
  44334 backlog exhaustion). All probes are exec-based (`ss`/`pgrep`).
- The server needs a generous `startupProbe` - first boot includes
  bridge-wait + DB schema + admin creation before `sigul_server`
  exists for liveness to find.
- `lenient-username-check: yes` matches the CI stack (cert + password
  auth). Strict CN==username needs per-user client certs - candidate
  hardening once per-user issuance exists.
- `server.persistence.volumePermissions.enabled` exists for storage
  that does not establish ownership itself: local-path/hostpath
  provisioners, and EFS on a direct mount **with root access
  preserved** (root-squashed mounts leave it in `Init:Error`). Keep
  it disabled with the
  EBS CSI driver, which applies `fsGroup` on its own; enabling it
  caps the namespace at `baseline` PodSecurity — see [Volume
  permissions and Pod Security
  Standards](#volume-permissions-and-pod-security-standards) for
  which case applies where.
  It leaves the volume root at mode `2775` —
  exactly what `fsGroup` expects — because a tighter mode keeps the
  root permanently mismatched, so `fsGroupChangePolicy:
  OnRootMismatch` relabels the volume on every mount and re-opens the
  GnuPG home to the group; sigul then refuses to start.
- `pki.mode: force` regenerates the trust domain. Every component
  must then be restarted (each rebuilds its NSS database from the new
  Secrets at pod start) - a partial restart creates a split trust
  domain. The obligation is recorded on the marker
  (`rotation-required`) and cleared only once the rollout has
  actually been triggered, so it survives an interrupted run, a
  failed rollout, or a manual one the operator has not performed yet;
  a later sync picks it up. By default the rollout is **manual** (the
  Job logs the commands, including the patch that clears the flag);
  set `pki.forceRestartWorkloads: true` to automate it, accepting
  that the bootstrap ServiceAccount then holds workload patch
  (= pod-template modification) RBAC. The admin credential is not
  rotated - it lives in a separate Secret because the server database
  retains the original hash.
- Secret verification checks the **key contract**, not just that the
  object holds data: a partial restore leaving `passwords` without
  `server-nss-password` would otherwise pass and strand the workloads
  on a missing `secretKeyRef` long after the Job reported success.
- Set `networkPolicy.apiServerCIDRs` in production so the bootstrap
  Job's egress is limited to the API endpoint rather than any
  HTTPS destination. The example Argo CD Application carries a
  placeholder value rather than leaving it unset, so an unreviewed
  copy fails loudly instead of silently keeping open egress.
- The marker Secret records `state: in-progress` before generation
  and `state: complete` after, so the Job can tell a crashed first
  attempt (safe to redo) from a completed bootstrap. In `auto` mode
  it refuses to run when PKI Secrets are populated but the marker is
  empty: silently regenerating there would leave the running pods on
  the old trust domain and invalidate every issued client bundle.
  Recover by re-sealing the marker (the Job logs the `kubectl patch`
  command) or, to rebuild deliberately, re-run with `pki.mode=force`.
- Bootstrap runs are serialised by a Lease
  (`<release>-pki-lock`). Under Argo CD the hook lifecycle already
  prevents overlap, but plain Helm can leave two revisioned bootstrap
  Jobs alive at once, and interleaved writes to the CA/P12/password
  Secrets would produce a mixed trust domain. The loser exits and its
  Job backoff retries once the holder has finished.
- The Job is an Argo CD **Sync hook** (wave -1) but a plain,
  revisioned Job under Helm - deliberately not a Helm hook, which
  would drag its ConfigMap, RBAC and pre-created Secrets into the
  hook lifecycle. Under Helm the workloads are therefore created
  alongside it, so the Job marks `rotation-required` on the marker
  before publishing anything; a run interrupted after a pod consumed
  its output is recovered with a coordinated restart.

## Architecture

- **PKI bootstrap Job** (Argo sync-wave -1): generates CA + component
  certs with `certutil` (Sigul's native mechanics, unchanged) in a
  memory-backed scratch dir, publishes Secrets via the API, then
  discards the CA private key with the pod. Idempotent via a marker
  Secret (`pki.mode: auto|force|skip`).
- **Bridge** (wave 1): Deployment, stateless — NSS DB rebuilt from
  Secrets each start. ClusterIP Service (44333 + 44334) plus an
  internet-facing NLB (44334 only, L4 passthrough; double-TLS forbids
  TLS termination).
- **Server** (wave 2): StatefulSet, single replica, PVC at
  `/var/lib/sigul` holding GnuPG home + SQLite DB (fixes the compose
  stack's DB-path defect). No Service — egress-only to the bridge.
- **NetworkPolicies**: default-deny; bridge 44334 open (mutual TLS is
  the gate), 44333 restricted to the server pod.
- **Admin toolbox** (optional, disabled): in-cluster client pod for
  key ceremonies, so admin credentials never leave the cluster.

## Secret contract

Produced by the bootstrap Job, consumed by workloads:

| Secret | Keys | Consumers |
| --- | --- | --- |
| `<release>-ca-public` | `ca.crt`, `bridge.crt` | all initContainers |
| `<release>-bridge-p12` | `bridge.p12` | bridge |
| `<release>-server-p12` | `server.p12` | server |
| `<release>-client-p12` | `client.p12` | toolbox; CI bundles |
| `<release>-passwords` | NSS + P12 passwords (PKI-coupled) | all |
| `<release>-admin` | `admin-password` (created once) | server, toolbox |
| `<release>-pki-complete` | `state` + metadata | Job idempotency marker |

## Volume permissions and Pod Security Standards

Every workload the chart ships runs unprivileged (UID 1000,
`readOnlyRootFilesystem`, all capabilities dropped) and satisfies
`restricted` PodSecurity — with one opt-in exception.

`server.persistence.volumePermissions.enabled: true` adds a
`volume-permissions` initContainer that runs as UID 0 and adds
`CHOWN`, `FOWNER` and `DAC_OVERRIDE`. All three are on `baseline`'s
capability allow-list, and `baseline` places no constraint on
`runAsUser`, so the pod is admitted at that level. `restricted`
forbids UID 0 and permits adding `NET_BIND_SERVICE` only, so it
rejects the pod whatever the capability list says.

Enabling this therefore caps the namespace at `baseline`:

| Namespace enforces | `volumePermissions: false` | `volumePermissions: true` |
| --- | --- | --- |
| `privileged` | admitted | admitted |
| `baseline` | admitted | admitted |
| `restricted` | admitted | **rejected** |

The capability list is minimal, and deliberately excludes
`DAC_READ_SEARCH`. `CAP_DAC_OVERRIDE` already bypasses read, write
and execute checks, and for a directory the execute bit *is* the
search bit — so it covers everything the recursive `chown` needs to
walk, including the mode-`700` GnuPG home left by an earlier run.
`DAC_READ_SEARCH` adds nothing there, and it is the one capability in
the original list that `baseline` rejects. Earlier revisions of this
chart included it, and a `baseline` namespace refused the pod:

```text
create Pod sigul-server-0 in StatefulSet sigul-server failed error:
pods "sigul-server-0" is forbidden: violates PodSecurity
"baseline:latest": non-default capabilities (container
"volume-permissions" must not include "DAC_READ_SEARCH" in
securityContext.capabilities.add)
```

If you see that, you are on an older chart. Do not re-add the
capability to a newer one — it costs the whole `baseline` profile and
buys nothing.

Which path applies:

1. **Production (EKS with the EBS CSI driver)** — leave
   `volumePermissions.enabled: false`, the default. The EBS CSI driver
   applies `fsGroup` to the volume itself, so the initContainer has
   nothing to do and the namespace can enforce `restricted`, as
   `K8S/argocd/opensearch-sigul.yaml` does. This is the path the
   chart-created StorageClass targets (`provisioner:
   ebs.csi.eks.amazonaws.com`).

   EFS is **not** equivalent. Its CSI driver does not perform
   `fsGroup` ownership management, so leaving `volumePermissions`
   disabled will not give the server a writable volume. Something
   has to make the volume's root directory owned by UID/GID `1000`
   before the server starts, and which options exist depends on how
   the filesystem is reached:

   - **Direct mount, root access preserved** — EFS does not squash
     root by default, so `volumePermissions` works here: the
     initContainer chowns the volume as it would any other. It costs
     the `restricted` profile, as above.
   - **Direct mount, `elasticfilesystem:ClientRootAccess` withheld**
     — root is mapped to the anonymous UID, so the initContainer's
     `chown` fails with `Operation not permitted`. Its command is
     `chown … && chmod …`, so the container exits non-zero and the
     pod stays in `Init:Error` — that failing initContainer is the
     symptom to troubleshoot, not a silently unwritable volume.
     There is no access point to configure here either, so the
     directory has to be given the right ownership out-of-band, from
     a client that does hold root access.
   - **Access point** — set its `PosixUser` to `1000`/`1000`, and
     leave `volumePermissions` disabled: the access point enforces
     that identity, so a `chown` cannot take effect anyway. Note
     that `CreationInfo` (`OwnerUid`/`OwnerGid`/`Permissions`)
     applies **only** when EFS creates the root path. Point the
     access point at a path that does not exist yet; against an
     existing directory EFS keeps whatever ownership it already has,
     and the server still cannot write.
2. **Local development (k3d/k3s local-path, Docker Desktop
   hostpath)** — these provisioners ignore `fsGroup`, so the
   initContainer is required and the namespace must not enforce
   `restricted`. An unlabelled namespace is unrestricted, so nothing
   extra is needed unless a cluster-wide default applies it.

PodSecurity is an admission check, so a rejected pod is never created
rather than created and failing. Recovery needs no reinstall: the
StatefulSet controller keeps retrying the create with backoff, so
relabelling the namespace is enough and the pod appears on the next
attempt. Labelling first is still preferable — it avoids a burst of
admission failures in the event log.

See the [Pod Security Standards][pss] for the full profile
definitions.

[pss]: https://kubernetes.io/docs/concepts/security/pod-security-standards/

## Admin toolbox

Set `adminToolbox.enabled: true` for key ceremonies and user
provisioning, then disable it again. In `--batch` mode sigul reads
credentials from stdin as NUL-terminated values - it never reads them
from the environment - so the admin password must be piped in:

```sh
kubectl exec -it deploy/<release>-admin-toolbox -- bash

printf '%s\0' "$SIGUL_ADMIN_PASSWORD" \
  | sigul --batch -c /etc/sigul/client.conf list-users
```

Commands taking a further secret expect the values in order, admin
password first:

```sh
printf '%s\0%s\0' "$SIGUL_ADMIN_PASSWORD" "$KEY_PASSPHRASE" \
  | sigul --batch -c /etc/sigul/client.conf new-key \
      --key-admin admin <key-name>
```

Signing commands take only the key passphrase:

```sh
printf '%s\0' "$KEY_PASSPHRASE" \
  | sigul --batch -c /etc/sigul/client.conf sign-text \
      -o <output> <key-name> <file>
```

## Producing the CI client bundle

The GitHub Action consumes a GPG-encrypted tar.xz of the client
`.sigul/` directory. Until automated, build it from the
`<release>-client-p12` + `<release>-ca-public` + `<release>-passwords`
Secrets following the same import steps as `files/scripts/nss-init.sh`
(runbook to be written — EVALUATION.md §9 Phase 4).

## Quick validation

```sh
helm lint .
helm template sigul . --namespace opensearch-sigul
```
