#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Stand up the Sigul chart in a cluster for the soak harness to
# measure, and leave behind the two things the harness needs to reach
# it: a kube context and the admin password.
#
# Creates a kind cluster by default. Point SOAK_K8S_CONTEXT at an
# existing cluster to use that instead - useful locally, where a
# Docker Desktop or minikube cluster is already running and creating
# another costs minutes for nothing.
#
# Images are loaded from the local daemon rather than pulled: the
# whole point is to soak the images this checkout just built, and
# those are never published.
#
#   ./soak/k8s/deploy.sh                 # create/reuse kind, install
#   ./soak/k8s/deploy.sh --teardown      # delete the release and cluster
#
# Environment:
#   SOAK_K8S_CLUSTER    kind cluster name           (default soak-k8s)
#   SOAK_K8S_CONTEXT    use this context, no kind   (default unset)
#   SOAK_K8S_NAMESPACE  namespace                   (default sigul-soak)
#   SOAK_K8S_RELEASE    helm release name           (default sigul)
#   SOAK_*_IMAGE        images to load and deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$ROOT"

# Deliberately free of the substring "sigul": kind names its node
# container "<cluster>-control-plane", and
# deploy-sigul-infrastructure.sh --force-clean-volumes removes every
# container matching `name=sigul`. A cluster called sigul-soak is
# therefore destroyed by any Compose soak run on the same machine,
# minutes into an unrelated Kubernetes run.
CLUSTER="${SOAK_K8S_CLUSTER:-soak-k8s}"
NAMESPACE="${SOAK_K8S_NAMESPACE:-sigul-soak}"
RELEASE="${SOAK_K8S_RELEASE:-sigul}"
CONTEXT="${SOAK_K8S_CONTEXT:-}"

# Which kind cluster, if any, this script is responsible for. Teardown
# branches on this rather than on whether a context is set, because
# the environment file written at the end of a successful deploy sets
# SOAK_K8S_CONTEXT - so a user who follows the documented flow and
# sources it would then have their own kind cluster classified as
# somebody else's and left running. Empty means the cluster was not
# created here and must not be deleted here.
#
# Provisional at this point: a deploy that turns out to be *reusing* a
# cluster it did not create disowns it below. A bare --teardown, with
# no environment sourced and no context given, keeps it - that
# invocation is an explicit instruction to remove the soak cluster.
if [[ -n "${SOAK_K8S_MANAGED_CLUSTER+set}" ]]; then
    MANAGED_CLUSTER="$SOAK_K8S_MANAGED_CLUSTER"
    MANAGED_EXPLICIT=true
elif [[ -n "$CONTEXT" ]]; then
    MANAGED_CLUSTER=""
    MANAGED_EXPLICIT=false
else
    MANAGED_CLUSTER="$CLUSTER"
    MANAGED_EXPLICIT=false
fi
# Not test-artifacts/admin-password: that is where
# deploy-sigul-infrastructure.sh writes the *Compose* stack's admin
# password, and a Compose soak on the same machine would overwrite
# this one. The symptom is a Kubernetes run failing every request with
# "Authentication failed" against a release that is perfectly healthy.
PASSWORD_FILE="${SOAK_ADMIN_PASSWORD_FILE:-${ROOT}/test-artifacts/k8s-admin-password}"

detect_platform() {
    case "$(uname -m)" in
        x86_64 | amd64) echo linux-amd64 ;;
        aarch64 | arm64) echo linux-arm64 ;;
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
    esac
}
PLATFORM="${SOAK_RUNNER_PLATFORM:-$(detect_platform)}"
BRIDGE_IMAGE="${SOAK_BRIDGE_IMAGE:-bridge-${PLATFORM}-image:test}"
SERVER_IMAGE="${SOAK_SERVER_IMAGE:-server-${PLATFORM}-image:test}"
CLIENT_IMAGE="${SOAK_CLIENT_IMAGE:-client-${PLATFORM}-image:test}"

log() { printf '[k8s] %s\n' "$*"; }

kube() { kubectl --context "$CONTEXT" "$@"; }

teardown() {
    if [[ -z "$MANAGED_CLUSTER" ]]; then
        log "removing release ${RELEASE} from ${NAMESPACE} (cluster left alone)"
        # Not tolerated with `|| true`: --ignore-not-found already
        # covers an absent release, so a failure here means the
        # release is still running - and the next step deletes its
        # admin Secret, its PKI and the server's volume. Stop instead.
        helm --kube-context "$CONTEXT" -n "$NAMESPACE" uninstall "$RELEASE" \
            --ignore-not-found --wait --timeout 3m
        # The chart's teardown contract, from K8S/charts/sigul/README.md:
        # neither helm's --wait nor Argo's finalizer covers the pods,
        # because a StatefulSet's pods are created by its controller
        # rather than by the tool, and uninstall's propagation defaults
        # to background. Until sigul-server actually exits it still has
        # the signing volume mounted and the keys open, and the next
        # step destroys both.
        #
        # Guarded by a look first, as that README insists: with nothing
        # to match, `wait --for=delete` exits non-zero with "no matching
        # resources found", which reads as a failure but is the state
        # being waited for.
        #
        # Captured into a variable rather than tested as a pipeline, so
        # that a failed lookup aborts under `set -e` instead of reading
        # as "no pods". Treating an unreachable apiserver as an empty
        # namespace would skip this wait and go straight to deleting
        # the keys and the volume of a server that may still be
        # running - the exact hazard the wait exists to prevent. A
        # namespace that does not exist answers a label selector with
        # an empty list and exit 0, so the benign case is unaffected.
        local remaining
        remaining="$(kube -n "$NAMESPACE" get pod \
            -l "app.kubernetes.io/instance=${RELEASE}" -o name)"
        if [[ -n "$remaining" ]]; then
            log "waiting for ${RELEASE}'s pods to exit"
            kube -n "$NAMESPACE" wait --for=delete pod \
                -l "app.kubernetes.io/instance=${RELEASE}" --timeout=300s
        fi
        # The chart keeps its PKI Secrets and its bootstrap lock Lease
        # on purpose, and uninstall honours that, so remove them
        # explicitly - a soak namespace has no trust domain worth
        # preserving, and leaving one behind lets the next run inherit
        # a PKI it did not create.
        #
        # The Lease is the chart's teardown contract again: it survives
        # both management planes, and clearing it is only safe once
        # every pod has exited, because removing one a live bootstrap
        # runner still holds would let a second runner start alongside
        # it. The wait above is exactly that precondition.
        #
        # Scoped to the release's own objects rather than deleting the
        # namespace: in this mode the namespace may have existed
        # beforehand and may hold things this script never created.
        kube -n "$NAMESPACE" delete secret,pvc,lease \
            -l "app.kubernetes.io/instance=${RELEASE}" --ignore-not-found
    else
        log "deleting kind cluster ${MANAGED_CLUSTER}"
        kind delete cluster --name "$MANAGED_CLUSTER" || true
    fi
}

if [[ "${1:-}" == "--teardown" ]]; then
    CONTEXT="${CONTEXT:-kind-${CLUSTER}}"
    teardown
    exit 0
fi

### Cluster ###################################################

if [[ -n "$CONTEXT" ]]; then
    log "using existing context ${CONTEXT}"
    # The values pin pullPolicy: Never, because the images this soak
    # exists to exercise are built locally and never published. Only
    # kind can be handed them; any other cluster must already have
    # them, so say so plainly rather than letting it fail later as an
    # ImagePullBackOff with no explanation.
    for image in "$BRIDGE_IMAGE" "$SERVER_IMAGE" "$CLIENT_IMAGE"; do
        log "expecting ${image} to be present on the cluster's nodes already"
    done
else
    CONTEXT="kind-${CLUSTER}"
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
        log "reusing kind cluster ${CLUSTER}"
        # Found in place, so this run did not create it and does not
        # get to delete it. The name is this script's own, so it is
        # most likely an earlier run's - but "most likely" is not a
        # basis for destroying a cluster, and the cost of being wrong
        # is asymmetric. Unless ownership was stated explicitly, the
        # generated environment disclaims it.
        if ! $MANAGED_EXPLICIT; then
            MANAGED_CLUSTER=""
            log "  not created by this run; --teardown will leave it"
            log "  remove it with: kind delete cluster --name ${CLUSTER}"
        fi
    else
        log "creating kind cluster ${CLUSTER}"
        kind create cluster --name "$CLUSTER" --wait 120s
        if ! $MANAGED_EXPLICIT; then
            MANAGED_CLUSTER="$CLUSTER"
        fi
    fi
    for image in "$BRIDGE_IMAGE" "$SERVER_IMAGE" "$CLIENT_IMAGE"; do
        log "loading ${image} into the cluster"
        kind load docker-image "$image" --name "$CLUSTER"
    done
fi

### Release ###################################################

log "installing ${RELEASE} into ${NAMESPACE}"
# Whether the release is already running decides if the workloads have
# to be rolled below; asked before the upgrade, because afterwards the
# answer is always yes.
#
# `helm list` and not `helm status`, for the same reason the pod
# lookup above captures rather than tests: status exits non-zero both
# for an absent release and for an apiserver that did not answer, and
# reading the second as the first skips the rollout - so the run would
# measure the previous images while reporting on the new ones. A list
# that fails aborts here instead; an empty one is a real answer, and a
# namespace that does not exist yet gives one.
installed="$(helm --kube-context "$CONTEXT" -n "$NAMESPACE" list -q \
    --filter "^${RELEASE}$")"
if [[ -n "$installed" ]]; then
    PREEXISTING=true
else
    PREEXISTING=false
fi

# The chart expects its namespace to enforce restricted Pod Security,
# and this is the only thing that creates one - but only when it does
# create one. Relabelling a namespace found in place changes the
# admission policy for workloads this script knows nothing about:
# theirs keep running, while their next update is refused. Say what
# was skipped instead, so a soak that is not exercising PSA is not
# mistaken for one that is.
if kube get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log "namespace ${NAMESPACE} already exists; leaving its labels alone"
    log "  (Pod Security enforcement is whatever that namespace sets)"
else
    kube create namespace "$NAMESPACE"
    kube label namespace "$NAMESPACE" --overwrite \
        pod-security.kubernetes.io/enforce=restricted \
        pod-security.kubernetes.io/warn=restricted
fi

helm --kube-context "$CONTEXT" -n "$NAMESPACE" upgrade --install \
    "$RELEASE" "${ROOT}/K8S/charts/sigul" \
    --values "${SCRIPT_DIR}/values.yaml" \
    --set "images.bridge.repository=${BRIDGE_IMAGE%:*}" \
    --set "images.bridge.tag=${BRIDGE_IMAGE##*:}" \
    --set "images.server.repository=${SERVER_IMAGE%:*}" \
    --set "images.server.tag=${SERVER_IMAGE##*:}" \
    --set "images.client.repository=${CLIENT_IMAGE%:*}" \
    --set "images.client.tag=${CLIENT_IMAGE##*:}" \
    --wait --timeout 10m

### Readiness #################################################

# Resources are addressed by label, never by a name built from
# ${RELEASE}. The chart's fullname helper appends the chart name to
# any release whose name does not already contain "sigul", so
# SOAK_K8S_RELEASE=test installs as test-sigul-bridge and every
# guessed name misses. Labels are the chart's own answer to what
# belongs to this release.
resolve() {
    # resolve <kind[,kind]> <component> -> kind/name, or empty
    kube -n "$NAMESPACE" get "$1" \
        -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=$2" \
        --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1
}

BRIDGE_WORKLOAD="$(resolve deployment bridge || true)"
SERVER_WORKLOAD="$(resolve statefulset server || true)"
TOOLBOX_WORKLOAD="$(resolve deployment admin-toolbox || true)"
for workload in "$BRIDGE_WORKLOAD" "$SERVER_WORKLOAD" "$TOOLBOX_WORKLOAD"; do
    if [[ -z "$workload" ]]; then
        echo "[k8s] ${RELEASE} in ${NAMESPACE} is missing a workload" >&2
        kube -n "$NAMESPACE" get deployment,statefulset >&2 || true
        exit 1
    fi
done
# The chart's fullname, taken from a name Helm rendered rather than
# re-derived here. The Secrets carry no component label, so this is
# the only way to address them without duplicating the helper.
FULLNAME="${BRIDGE_WORKLOAD#deployment.apps/}"
FULLNAME="${FULLNAME%-bridge}"

# Loading an image into a reused cluster does not disturb pods that are
# already running it: the tags are stable, so an unchanged pod spec
# means Helm has nothing to roll and the soak would quietly measure
# whatever the previous run left behind. Restart the workloads so the
# images just loaded are the ones under test - but only where there was
# something to go stale. On a first install the pods are created after
# the images are loaded, and restarting them there only races the
# readiness checks below.
#
# Not tolerated with `|| true`: a restart that did not happen is the
# stale-image case this exists to prevent, and `rollout status` below
# would then pass at once against the revision that was supposed to
# have been replaced. The workloads were resolved just above, so there
# is nothing benign left for a failure here to mean.
if $PREEXISTING; then
    log "rolling the workloads onto the images just loaded"
    for workload in "$BRIDGE_WORKLOAD" "$SERVER_WORKLOAD" "$TOOLBOX_WORKLOAD"; do
        kube -n "$NAMESPACE" rollout restart "$workload"
    done
fi

# Wait on what the harness actually needs, not just on Helm returning:
# the bootstrap Job having published the PKI, and a client able to
# reach the bridge through it. A run that starts before either is a
# run whose first minute measures the deployment rather than Sigul.
#
# The newest Job for this release, by name: the Job is revisioned and
# kept for an hour after it finishes, so a label selector also matches
# earlier revisions - and a failed one never gains Complete, which
# would hang this wait until it timed out however well the current
# revision did.
log "waiting for the PKI bootstrap Job"
PKI_JOB="$(resolve job pki-bootstrap || true)"
if [[ -z "$PKI_JOB" ]]; then
    echo "[k8s] no PKI bootstrap Job for ${RELEASE} in ${NAMESPACE}" >&2
    exit 1
fi
kube -n "$NAMESPACE" wait --for=condition=Complete "$PKI_JOB" --timeout=5m

# `rollout status` rather than `wait --for=condition=Ready pod -l ...`:
# a label selector matches the outgoing pod as well as its
# replacement, and an outgoing pod stays Ready for seconds after it is
# told to go. The wait then returns satisfied by the pod being
# replaced, and the checks that follow run against a half-rolled
# release. `rollout status` is revision-aware and cannot be answered
# by the previous one.
log "waiting for the daemons"
for workload in "$BRIDGE_WORKLOAD" "$SERVER_WORKLOAD" "$TOOLBOX_WORKLOAD"; do
    kube -n "$NAMESPACE" rollout status "$workload" --timeout=5m
done

mkdir -p "$(dirname "$PASSWORD_FILE")"
# Created empty and private before anything is written into it: the
# caller's umask would otherwise leave the signing admin's password
# world-readable, and a chmod afterwards leaves a window in which it
# is not. Matches what deploy-sigul-infrastructure.sh does.
install -m 600 /dev/null "$PASSWORD_FILE"
kube -n "$NAMESPACE" get secret "${FULLNAME}-admin" \
    -o jsonpath='{.data.admin-password}' | base64 -d > "$PASSWORD_FILE"
if [[ ! -s "$PASSWORD_FILE" ]]; then
    echo "[k8s] ${FULLNAME}-admin holds no admin-password" >&2
    exit 1
fi
log "admin password written to ${PASSWORD_FILE}"

# A label selector can still match a pod on its way out, and name
# order decides which comes first - so ask for the ones the kubelet
# says are Ready and take the newest of those.
TOOLBOX="$(kube -n "$NAMESPACE" get pod \
    -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=admin-toolbox" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}')"
if [[ -z "$TOOLBOX" ]]; then
    echo "[k8s] no admin toolbox pod in ${NAMESPACE}" >&2
    exit 1
fi

# `list-users` and not a signing request: the soak's key is created by
# the load generator at test start, so there is nothing to sign with
# yet. What this does prove is the whole path up to that point - the
# client's certificate, the bridge pairing it with the server, the
# server's database, and the admin password just read out of the
# Secret. A broken key path is not covered and is found by the first
# measured sign_text instead.
#
# Bounded on both sides, as the harness bounds its own requests. The
# Sigul client waits without limit by design, so a wedged bridge here
# would hang the deploy until the whole CI job was cancelled - no
# diagnostics, no cleanup, and an hour gone. `timeout` inside the
# container ends the client; `timeout` outside ends a kubectl whose
# exec stream never closes, which the first cannot help with.
AUTH_TIMEOUT=60
log "checking the client can reach the server and authenticate"
if ! timeout "$((AUTH_TIMEOUT + 15))" \
        kubectl --context "$CONTEXT" -n "$NAMESPACE" \
        exec -i "$TOOLBOX" -c toolbox -- \
        timeout --signal=KILL "$AUTH_TIMEOUT" \
        sigul --batch -c /etc/sigul/client.conf list-users \
        < <(printf '%s\0' "$(cat "$PASSWORD_FILE")") >/dev/null; then
    echo "[k8s] the toolbox cannot reach the release; not starting a soak" >&2
    echo "[k8s] (no answer within ${AUTH_TIMEOUT}s counts as cannot)" >&2
    exit 1
fi

# Written as well as printed. The harness needs all of this and
# defaults to the Compose target without it, so a copy that can be
# sourced is the difference between the documented invocation working
# and it silently soaking the wrong stack. 0600 because it names the
# file holding the admin password.
ENV_FILE="$(dirname "$PASSWORD_FILE")/soak-k8s.env"
install -m 600 /dev/null "$ENV_FILE"
# Values are shell-escaped, because two of them are paths: a checkout
# under a directory with a space in it would otherwise write a line
# that, once sourced, sets the variable to the first word and runs the
# rest as a command.
{
    printf 'SOAK_TARGET=kubernetes\n'
    printf 'SOAK_K8S_CONTEXT=%q\n' "$CONTEXT"
    printf 'SOAK_K8S_NAMESPACE=%q\n' "$NAMESPACE"
    printf 'SOAK_K8S_RELEASE=%q\n' "$RELEASE"
    # Empty when the cluster was not created here, so that sourcing
    # this and then running --teardown deletes exactly what this
    # script made and nothing else.
    printf 'SOAK_K8S_MANAGED_CLUSTER=%q\n' "$MANAGED_CLUSTER"
    printf 'SOAK_SIGUL_VIA=kubectl\n'
    printf 'SOAK_ADMIN_PASSWORD_FILE=%q\n' "$PASSWORD_FILE"
    printf 'SOAK_OUTPUT_DIR=%q\n' "${ROOT}/soak/results"
} > "$ENV_FILE"

cat <<EOF
[k8s] ready. To soak it:

  set -a; . $(printf '%q' "$ENV_FILE"); set +a
  cd soak && python3 -m harness k8s

EOF
