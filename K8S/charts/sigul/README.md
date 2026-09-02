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
3. Platform-team confirmations pending (EVALUATION.md §8.1):
   AppProject conventions and NodePool policy. The encrypted
   StorageClass is **resolved** — the platform team provisions
   `sigul-ebs` (gp3, customer-managed KMS key, `Retain`) in OpenTofu,
   and `K8S/argocd/opensearch-sigul.yaml` claims it by name.
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
   `K8S/argocd/opensearch-sigul.yaml` does. The platform-managed
   `sigul-ebs` class targets this path, and so does the chart-created
   class by default — though `storageClass.provisioner` can point the
   latter at another driver, including a self-managed EBS CSI
   deployment (`ebs.csi.aws.com`), which behaves the same way here.
   Any driver that does **not** apply `fsGroup` puts you in the EFS
   case below regardless of the provisioner named.

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

## Node isolation

Every workload exposes `nodeSelector`, `tolerations` and `affinity`.
The bridge and the server carry their own (`bridge.*`, `server.*`);
the bootstrap Job and the admin toolbox follow the server by default
via `pki.scheduling` and `adminToolbox.scheduling`.

Pinning the key material to a dedicated node pool takes all three,
because a taint only repels:

1. **Taint the pool** — keeps every other workload off it.
2. **Tolerate the taint** — *permits* the Sigul pod to land there.
3. **Select the pool** with `nodeSelector` or `affinity` — *keeps* it
   there.

Step 3 is the one to not skip. A pod with a toleration and nothing
else is free to schedule anywhere, so omitting it buys the cost of a
dedicated pool with none of the isolation, and nothing reports a
problem.

```yaml
server:
  tolerations:
    - key: sigul.linuxfoundation.org/dedicated
      operator: Equal
      value: keys
      effect: NoSchedule
  nodeSelector:
    sigul.linuxfoundation.org/pool: keys
```

That is the whole configuration: the bootstrap Job and the toolbox
inherit both fields, and the bridge stays where it is. Leaving the
bridge on general-purpose nodes is deliberate — it is the
internet-facing component, and it holds no signing keys.

The inheritance default exists because the bootstrap Job is the pod
that generates the CA private key and every leaf key. A Job with no
toleration cannot schedule onto a tainted pool at all, so an
independently-configured Job would be excluded from the isolation by
construction — the most sensitive workload in the chart running on the
shared nodes. Set `pki.scheduling.inheritServer: false` to place it
yourself; the three fields then apply as a set rather than merging
with the server's, and leaving them empty schedules it anywhere.

Node isolation bounds what a **neighbouring tenant's workload** can
reach. It does nothing against cluster-admin, a compromised
kubelet, or anyone who can `exec` into this namespace — the same
boundary that applies to storage encryption (EVALUATION.md §5.2). Pair
it with the namespace-level controls in EVALUATION.md §5.3.

On the target EKS cluster the pool would be a Karpenter NodePool, so
whether a tenant may create one is a governance question for the
platform team (EVALUATION.md §8.1 Q1), not a chart setting.

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

## Uninstall and reinstall

The race below is specific to plain Helm; under Argo CD there is no
`helm install` to lose it. Teardown differs by plane too — see
[Step 1](#step-1-remove-the-deployment).

Always uninstall with `--wait`:

```sh
helm -n <namespace> uninstall <release> --wait
```

Without it, `helm uninstall` returns once the API server has accepted
the delete requests, not once the objects are gone. An install issued
immediately afterwards races the terminating objects:

```text
Error: INSTALLATION FAILED: services "sigul-bridge" not found
```

The window is inside `helm install` itself. It preflights every
rendered resource with a `GET`, and any object that already exists
carrying this release's `meta.helm.sh/release-name` and
`release-namespace` annotations is *adopted* rather than treated as a
conflict. A still-terminating bridge Service is visible to that
lookup, so it is adopted. Because the adoption set is non-empty, Helm
then takes its update path instead of a plain create, and that path
re-reads each target to compute a three-way merge patch. By the time
it re-reads the Service, the delete has completed — hence `not
found`.

So the failure is not about `helm.sh/resource-policy: keep`, despite
the kept Secrets being adopted by the same mechanism: they are still
there when Helm re-reads them. The object that disappears mid-install
is the ordinary Service that the uninstall was still deleting.
`--wait` closes the window by not returning until it is gone; a
`sleep` only makes it less likely.

A reinstall is a **resume, not a clean slate**. Two kinds of state
outlive the release on purpose:

- The PKI and admin Secrets carry `helm.sh/resource-policy: keep`
  (see [Secret contract](#secret-contract)). Losing them is
  unrecoverable — the admin password hash lives in the server
  database, and every issued client bundle is bound to the CA. Helm
  re-adopts them on install because the ownership annotations still
  name the same release and namespace.
- The server PVC comes from a `volumeClaimTemplate`, which Helm never
  tracked, so it survives with the GnuPG home and SQLite database
  intact.

The bootstrap Job therefore finds a sealed marker and skips
generation, which is what makes signing keys survive a reinstall.

Tearing a tenant down for real means clearing **every** layer that
holds the material — the release, the Secrets, the claim, and,
depending on the StorageClass in use, a retained volume and the
storage behind it. Stopping part-way leaves signing keys readable,
and on metered storage still costing money. Take a backup first,
because nothing else can rebuild any of it.

Work through the sections below in order, and do not stop at the
first code block that looks like a complete teardown. Select by label
rather than by name — object names come from `sigul.fullname`, so a
release `foo` owns `foo-sigul-server` and its claim is
`data-foo-sigul-server-0`, and `nameOverride` / `fullnameOverride`
move them again.

### Step 1: remove the deployment

First, while the pod still exists, record which node it is on:

```sh
kubectl -n <namespace> get pod \
  -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=server \
  -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
```

A `hostPath` PV need not carry `nodeAffinity`, and when it does not,
the pod's `spec.nodeName` is the only record of which node holds the
data. Step 4 needs it, and this step destroys it.

The rest of this step differs by management plane. Get it right
before going
further: steps 2 onward destroy the trust domain, and running them
against a tenant that is still up leaves the bridge and server
running with no PKI and no way to rebuild it.

**Plain Helm:**

```sh
helm -n <namespace> uninstall <release> --wait
```

**Argo CD:** there is no Helm release to uninstall. Argo renders the
chart and applies the manifests itself, so `helm uninstall` fails —
there is no release for it to find, whatever is actually running.
Delete the owning Application instead — and note that Argo
cascades to managed resources only when the Application carries the
resources finalizer, which `K8S/argocd/opensearch-sigul.yaml` does
not. Deleting it as-is orphans the workloads rather than removing
them:

Prefer the CLI, which sets the finalizer correctly for you:

```sh
# Cascade is the default
argocd app delete <app-name>
```

Without the `argocd` CLI, set the finalizer by hand — but read the
current list first. A merge patch **replaces** `metadata.finalizers`
wholesale, so applying one blindly drops any other controller's
finalizer and skips the cleanup it was there to perform:

```sh
kubectl -n <argocd-namespace> get application <app-name> \
  -o jsonpath='{.metadata.finalizers}{"\n"}'
```

If that prints an empty list the patch below is safe as written;
otherwise add `resources-finalizer.argocd.argoproj.io` to the entries
already present and patch with the full list.

```sh
kubectl -n <argocd-namespace> patch application <app-name> \
  --type merge \
  -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
kubectl -n <argocd-namespace> delete application <app-name>
```

`<release>` is the Application's `spec.source.helm.releaseName` and
`<namespace>` its `spec.destination.namespace` — not the Application
name, which lives in the Argo CD namespace instead.

The cascade will **not** take the Secrets with it: they carry
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`, the
Argo-side counterpart of `helm.sh/resource-policy: keep`. That is why
step 2 exists on both planes.

**Then, on either plane, confirm the pods have gone.** Neither tool's
own wait covers them, and step 2 destroys the trust domain — so this
is the check that stops it running against a live server. Look
before waiting:

```sh
kubectl -n <namespace> get pod -l app.kubernetes.io/instance=<release>
```

- **`No resources found`** — they have already exited. Go to step 2.
  Do not run the `wait` below: with nothing to match it exits
  non-zero with `error: no matching resources found`, which looks
  like a failure but is the state you want.

  If you expected pods here, check `<release>` before concluding the
  teardown worked — an empty list also means a wrong selector.
- **Anything listed** — wait for it:

  ```sh
  kubectl -n <namespace> wait --for=delete pod \
    -l app.kubernetes.io/instance=<release> --timeout=300s
  ```

Both waits stop one level too high, for the same reason: they track
the objects the tool manages, and a StatefulSet's pods are created by
the StatefulSet controller, not by the tool.

- `helm uninstall --wait` waits only on resources rendered in the
  release, and uninstall's propagation defaults to `background`, so
  the StatefulSet delete returns immediately and its pod is collected
  asynchronously. (`--cascade foreground` makes Helm wait on the
  dependents, but the explicit check above is worth keeping either
  way.)
- Argo's finalizer defaults to *foreground* propagation, so the
  Application stays `Terminating` until its managed resources are
  gone — which again means the StatefulSet object, not the pod.

Until `sigul-server` actually exits it holds the signing volume
mounted and the keys open.

### Step 2: Secrets and claim

Record what backs the claim **before** deleting it. Under a `Delete`
policy the PV disappears along with the PVC, taking the only pointer
to the underlying storage with it — and, as step 4 notes, the PV
vanishing does not always mean the data did:

```sh
kubectl -n <namespace> get pvc \
  -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=server \
  -o custom-columns=PVC:.metadata.name,PV:.spec.volumeName
```

Expect one row, but do not assume it. The delete below is by label
and takes every match, and a past `nameOverride`/`fullnameOverride`
change leaves the old StatefulSet's claim behind carrying the same
instance and component labels. Save **each** PV listed, not just the
first — any you skip is deleted unrecorded:

```sh
kubectl get pv <pv-name> -o yaml > <pv-name>.yaml
```

**On EFS, the PV is not enough.** A dynamically provisioned volume
handle looks like `fs-0abc…::fsap-0def…`, and the directory it maps
to lives on the *access point* — `RootDirectory.Path` is not in the
PV at all. `DeleteVolume` removes the access point, so once the claim
is gone that path is unrecoverable. Take it now, for each PV saved
above, using the `fsap-` id from its `spec.csi.volumeHandle`:

```sh
aws efs describe-access-points --access-point-id <fsap-...> \
  --query 'AccessPoints[0].RootDirectory.Path' --output text
```

Then remove them:

```sh
kubectl -n <namespace> delete secret \
  -l app.kubernetes.io/instance=<release>

kubectl -n <namespace> delete pvc \
  -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=server
```

### Step 3: retained PersistentVolume

Whether anything survived step 2 depends on the StorageClass, which
the chart does not pin:

- **`storageClass.create: true`** — the chart's own class, which sets
  `reclaimPolicy: Retain`. The PV is left `Released` and the volume
  is intact.
- **`server.persistence.storageClassName` set** — that class's
  reclaim policy governs, and the chart has no say in it. On
  `project-shared` EKS that names `sigul-ebs`, which OpenTofu defines
  as `Retain`, so the volume survives there; treat that as a fact
  about that one class rather than about named classes generally.
- **Neither, which is the default** — the cluster default class
  governs, and its policy is often `Delete`.

Only the first is guaranteed by the chart, and it is opt-in —
`storageClass.create` defaults to `false`, so a stock install lands on
the cluster default class. Check rather than assume. `Released` PVs
keep their `claimRef`, which is what ties one to a tenant; on a shared
cluster there will be other tenants' volumes in the same list:

```sh
kubectl get pv \
  -o custom-columns=\
PV:.metadata.name,\
STATUS:.status.phase,\
RECLAIM:.spec.persistentVolumeReclaimPolicy,\
NS:.spec.claimRef.namespace,\
CLAIM:.spec.claimRef.name
```

Find the row whose `NS`/`CLAIM` match a claim deleted in step 2, then
branch on its `RECLAIM` value — not on the row simply being there. A
`Delete`-policy PV does not vanish the instant the claim goes; it
sits `Released`/`Terminating` while the provisioner removes the
backing storage.

If step 2 recorded more than one claim, work through steps 3 and 4
once **per pair**. They can differ: a volume left over from an
earlier `fullnameOverride` may sit on a different StorageClass, so
one can be `Delete` and already gone while another is `Retain` and
still holding signing keys.

- **No matching row** — a `Delete` class has already finished and
  released the volume. Kubernetes is done, but that does not by
  itself prove the *data* was erased: some drivers delete their
  handle and leave the contents. Check the YAML saved in step 2
  against the last item in step 4 before considering this closed.

- **`RECLAIM: Delete`** — cleanup is in progress. Leave it alone: the
  provisioner reads the PV to find out what to delete, so removing
  the object by hand can strand the volume permanently — the opposite
  of what this procedure is for. Wait for it instead:

  ```sh
  kubectl wait --for=delete pv/<pv-name> --timeout=300s
  ```

  Once it is gone, Kubernetes has released the volume — but check the
  `Delete`-policy note at the end of step 4 before treating the
  teardown as finished, because some drivers delete their handle and
  leave the data. If the PV is still there after the timeout, the
  provisioner is failing — check its logs rather than forcing the
  delete.

- **`RECLAIM: Retain`** — nothing will clean this up for you, so it
  is yours to remove. Step 2 already saved its definition, and step 4
  reads that file: for a `local` or `hostPath` volume it is the only
  record of the directory and the node holding it, so confirm you
  have it before removing the object — otherwise the signing keys are
  stranded on a disk you can no longer locate.

  ```sh
  kubectl delete pv <pv-name>
  ```

  Then continue to step 4.

### Step 4: backing storage

For a `Retain` volume found in step 3, and for the `Delete` case
called out at the end of this section. `Retain` means the underlying
storage outlives the PV object, and deleting the PV does not delete
it — the GnuPG home and SQLite database are still there.

Read the volume source from the YAML saved in step 2 and follow the
branch that matches. There is no universal identifier here, so the
wrong branch will appear to succeed while leaving the keys in place.

- **`spec.csi` with `driver: ebs.csi.eks.amazonaws.com`** (or
  `ebs.csi.aws.com`) — what the chart-created class provisions.
  `spec.csi.volumeHandle` is the EBS volume ID:

  ```sh
  aws ec2 delete-volume --volume-id <vol-...>

  # Confirm rather than assume; expect InvalidVolume.NotFound
  aws ec2 describe-volumes --volume-ids <vol-...>
  ```

- **`spec.csi` with any other driver** — EFS, Ceph RBD, Longhorn and
  so on. `spec.csi.volumeHandle` identifies the object inside that
  system, not an EC2 volume, so use that provider's own deletion
  procedure.

- **`spec.local` or `spec.hostPath`, with no `spec.csi` at all** —
  what the local-path and hostpath provisioners produce, including
  the development configuration in `values-local-smoke.yaml`. These
  PVs have no CSI driver or handle; the data is a plain directory on
  one node. Take the path from `spec.local.path` or
  `spec.hostPath.path`, and the node from `spec.nodeAffinity` — or,
  when the PV carries none, the node recorded in step 1. Erase the
  directory there, however node access is normally obtained:

  ```sh
  # kubectl debug mounts the node's filesystem under /host
  kubectl debug node/<node> -it --image=busybox \
    -- rm -rf /host/<path>
  ```

Do not stop at `kubectl delete pv` in any of these cases: the keys
remain readable to anyone who can reach the storage until this step
completes, and on a metered backend it keeps accruing cost.

**`Delete`-policy volumes are not automatically exempt.** A driver's
`DeleteVolume` removes *its* object, which is not always the data.
The AWS EFS CSI driver is the case to know about here: it deletes the
access point but leaves the root directory and its contents, because
`deleteAccessPointRootDir` defaults to `false`. A `Delete`-policy EFS
volume therefore disappears from `kubectl get pv` with the signing
keys still on the filesystem. If the YAML saved in step 2 names
`efs.csi.aws.com`, mount the filesystem and delete the root directory
recorded in step 2 — or confirm the driver was deployed with
`deleteAccessPointRootDir=true`. EBS and the local drivers do erase
their storage on delete.

## Quick validation

```sh
helm lint .
helm template sigul . --namespace opensearch-sigul
```
