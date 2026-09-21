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
#   SOAK_K8S_CLUSTER    kind cluster name           (default sigul-soak)
#   SOAK_K8S_CONTEXT    use this context, no kind   (default unset)
#   SOAK_K8S_NAMESPACE  namespace                   (default sigul-soak)
#   SOAK_K8S_RELEASE    helm release name           (default sigul)
#   SOAK_*_IMAGE        images to load and deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$ROOT"

CLUSTER="${SOAK_K8S_CLUSTER:-sigul-soak}"
NAMESPACE="${SOAK_K8S_NAMESPACE:-sigul-soak}"
RELEASE="${SOAK_K8S_RELEASE:-sigul}"
CONTEXT="${SOAK_K8S_CONTEXT:-}"
PASSWORD_FILE="${SOAK_ADMIN_PASSWORD_FILE:-${ROOT}/test-artifacts/admin-password}"

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
    if [[ -n "${SOAK_K8S_CONTEXT:-}" ]]; then
        log "removing release ${RELEASE} from ${NAMESPACE} (cluster left alone)"
        helm --kube-context "$CONTEXT" -n "$NAMESPACE" uninstall "$RELEASE" \
            --ignore-not-found --wait --timeout 3m || true
        # The chart keeps the PKI Secrets on purpose; a soak namespace
        # has nothing worth keeping, and leaving them behind would let
        # the next run inherit a trust domain it did not create.
        kube delete namespace "$NAMESPACE" --ignore-not-found --wait=false || true
    else
        log "deleting kind cluster ${CLUSTER}"
        kind delete cluster --name "$CLUSTER" || true
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
else
    CONTEXT="kind-${CLUSTER}"
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
        log "reusing kind cluster ${CLUSTER}"
    else
        log "creating kind cluster ${CLUSTER}"
        kind create cluster --name "$CLUSTER" --wait 120s
    fi
    for image in "$BRIDGE_IMAGE" "$SERVER_IMAGE" "$CLIENT_IMAGE"; do
        log "loading ${image} into the cluster"
        kind load docker-image "$image" --name "$CLUSTER"
    done
fi

### Release ###################################################

log "installing ${RELEASE} into ${NAMESPACE}"
kube create namespace "$NAMESPACE" --dry-run=client -o yaml | kube apply -f -

# The chart's own Pod Security expectations, applied here because
# nothing else creates this namespace.
kube label namespace "$NAMESPACE" --overwrite \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/warn=restricted

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

# Wait on what the harness actually needs, not just on Helm returning:
# the bootstrap Job having published the PKI, and a client able to
# reach the bridge through it. A run that starts before either is a
# run whose first minute measures the deployment rather than Sigul.
log "waiting for the PKI bootstrap Job"
kube -n "$NAMESPACE" wait --for=condition=Complete job \
    -l "app.kubernetes.io/component=pki-bootstrap" --timeout=5m

log "waiting for the daemons"
for component in bridge server admin-toolbox; do
    kube -n "$NAMESPACE" wait --for=condition=Ready pod \
        -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=${component}" \
        --timeout=5m
done

mkdir -p "$(dirname "$PASSWORD_FILE")"
kube -n "$NAMESPACE" get secret "${RELEASE}-admin" \
    -o jsonpath='{.data.admin-password}' | base64 -d > "$PASSWORD_FILE"
if [[ ! -s "$PASSWORD_FILE" ]]; then
    echo "[k8s] ${RELEASE}-admin holds no admin-password" >&2
    exit 1
fi
log "admin password written to ${PASSWORD_FILE}"

TOOLBOX="$(kube -n "$NAMESPACE" get pod \
    -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=admin-toolbox" \
    -o jsonpath='{.items[0].metadata.name}')"

log "checking the client can sign through the release"
if ! kube -n "$NAMESPACE" exec -i "$TOOLBOX" -c toolbox -- \
        sigul --batch -c /etc/sigul/client.conf list-users \
        < <(printf '%s\0' "$(cat "$PASSWORD_FILE")") >/dev/null; then
    echo "[k8s] the toolbox cannot reach the release; not starting a soak" >&2
    exit 1
fi

cat <<EOF
[k8s] ready. To soak it:

  export SOAK_TARGET=kubernetes
  export SOAK_K8S_CONTEXT=${CONTEXT}
  export SOAK_K8S_NAMESPACE=${NAMESPACE}
  export SOAK_SIGUL_VIA=kubectl
  export SOAK_ADMIN_PASSWORD_FILE=${PASSWORD_FILE}
  python3 -m harness smoke        # from soak/

EOF
