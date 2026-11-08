#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Integration test for per-client certificates (pki.clients, #104).
#
# Installs this checkout's chart into a kind cluster with the shared
# client certificate, then adopts per-client certificates the way the
# chart README's runbook does - pki.mode=force, a coordinated restart
# and strict username checking - and proves, against the running
# server, that:
#   - the admin toolbox still performs admin operations
#   - a client signs as its own user with its own bundle
#   - the same bundle claiming another user (-u admin, or another
#     client's name) is rejected with "Cert CN and user differ", even
#     with that user's correct password
#   - once a client's user is deleted its bundle can do nothing
#
# The Compose stack the other integration tests use has no PKI
# bootstrap Job, so this runs the chart's own.
#
# Usage (images already built and tagged locally):
#   bash test/k8s_pki_clients.sh [--keep]
#
# Environment:
#   PKI_TEST_CLUSTER        kind cluster name    (default pki-clients)
#   PKI_TEST_BRIDGE_IMAGE   bridge image          (default bridge-linux-amd64-image:test)
#   PKI_TEST_SERVER_IMAGE   server image          (default server-linux-amd64-image:test)
#   PKI_TEST_CLIENT_IMAGE   client image          (default client-linux-amd64-image:test)
#   PKI_TEST_LOG_DIR        diagnostics on failure (default test-artifacts/k8s-pki-clients)
#
# --keep leaves the cluster up for inspection; otherwise it is deleted.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${REPO_DIR}/K8S/charts/sigul"
# Free of the substring "sigul" for the reason soak/k8s/deploy.sh
# gives: kind names its node container after the cluster.
CLUSTER="${PKI_TEST_CLUSTER:-pki-clients}"
CONTEXT="kind-${CLUSTER}"
NAMESPACE=pki-clients
RELEASE=sigul
BRIDGE_IMAGE="${PKI_TEST_BRIDGE_IMAGE:-bridge-linux-amd64-image:test}"
SERVER_IMAGE="${PKI_TEST_SERVER_IMAGE:-server-linux-amd64-image:test}"
CLIENT_IMAGE="${PKI_TEST_CLIENT_IMAGE:-client-linux-amd64-image:test}"
LOG_DIR="${PKI_TEST_LOG_DIR:-${REPO_DIR}/test-artifacts/k8s-pki-clients}"
KEEP=false
[ "${1:-}" != "--keep" ] || KEEP=true

CANARY=opensearch-canary
OTHER=opensearch-other
KEY=pki-clients-test-key
# Sigul limits for a request: a wedged bridge must fail the test, not
# hang the job. `timeout` inside the pod ends the client; the outer
# one ends a kubectl exec whose stream never closes.
REQUEST_TIMEOUT=120

PASSED=0
FAILED=()

log() { printf '[pki-clients] %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILED+=("$*"); }
kube() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }
genpw() { head -c 18 /dev/urandom | base64 | tr -d '=+/'; }

collect_diagnostics() {
    mkdir -p "${LOG_DIR}"
    kube get pods,jobs,secrets -o wide > "${LOG_DIR}/resources.txt" 2>&1 || true
    kube get events --sort-by=.lastTimestamp > "${LOG_DIR}/events.txt" 2>&1 || true
    for component in bridge server admin-toolbox pki-bootstrap; do
        kube logs -l "app.kubernetes.io/component=${component}" \
            --all-containers --prefix --tail=2000 \
            > "${LOG_DIR}/${component}.log" 2>&1 || true
    done
}

cleanup() {
    local rc=$?
    if [ "${rc}" -ne 0 ] || [ "${#FAILED[@]}" -gt 0 ]; then
        collect_diagnostics
        log "diagnostics in ${LOG_DIR}"
    fi
    if ! ${KEEP}; then
        kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
    fi
    exit "${rc}"
}
trap cleanup EXIT

### Cluster and first install (shared client certificate) ###########

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
    log "creating kind cluster ${CLUSTER}"
    kind create cluster --name "${CLUSTER}" --wait 120s
fi
for image in "${BRIDGE_IMAGE}" "${SERVER_IMAGE}" "${CLIENT_IMAGE}"; do
    log "loading ${image}"
    kind load docker-image "${image}" --name "${CLUSTER}"
done

kubectl --context "${CONTEXT}" create namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f -
kubectl --context "${CONTEXT}" label namespace "${NAMESPACE}" --overwrite \
    pod-security.kubernetes.io/enforce=restricted >/dev/null

HELM=(helm --kube-context "${CONTEXT}" -n "${NAMESPACE}")
BASE_VALUES=(
    --set "images.bridge.repository=${BRIDGE_IMAGE%:*}"
    --set "images.bridge.tag=${BRIDGE_IMAGE##*:}"
    --set "images.bridge.pullPolicy=Never"
    --set "images.bridge.digest="
    --set "images.server.repository=${SERVER_IMAGE%:*}"
    --set "images.server.tag=${SERVER_IMAGE##*:}"
    --set "images.server.pullPolicy=Never"
    --set "images.server.digest="
    --set "images.client.repository=${CLIENT_IMAGE%:*}"
    --set "images.client.tag=${CLIENT_IMAGE##*:}"
    --set "images.client.pullPolicy=Never"
    --set "images.client.digest="
    --set "adminToolbox.enabled=true"
    --set "bridge.service.external.enabled=false"
    --set "pki.externalFQDN=sigul-bridge.pki-clients.test"
    --set "server.persistence.size=1Gi"
    --set "server.persistence.storageClassName="
    --set "server.persistence.volumePermissions.enabled=false"
    --set "storageClass.create=false"
)

# The workloads and the Job, by label: the chart's fullname helper
# decides the names (see soak/k8s/deploy.sh).
newest() {
    kube get "$1" -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=$2" \
        --sort-by=.metadata.creationTimestamp -o name | tail -1
}

wait_for_release() {
    local job workload
    job="$(newest job pki-bootstrap)"
    log "waiting for ${job}"
    kube wait --for=condition=Complete "${job}" --timeout=5m
    for workload in "$(newest deployment bridge)" "$(newest statefulset server)" \
            "$(newest deployment admin-toolbox)"; do
        kube rollout status "${workload}" --timeout=5m
    done
    TOOLBOX="$(kube get pod \
        -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=admin-toolbox" \
        --field-selector=status.phase=Running \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1:].metadata.name}')"
    SERVER_POD="$(kube get pod \
        -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=server" \
        -o jsonpath='{.items[0].metadata.name}')"
}

log "installing with the shared client certificate"
"${HELM[@]}" upgrade --install "${RELEASE}" "${CHART}" "${BASE_VALUES[@]}" \
    --wait --timeout 10m
wait_for_release

FULLNAME="$(newest deployment bridge)"
FULLNAME="${FULLNAME#deployment.apps/}"
FULLNAME="${FULLNAME%-bridge}"

secret_value() {
    # secret_value SECRET KEY -> decoded value on stdout
    kube get secret "$1" -o "jsonpath={.data.${2//./\\.}}" | base64 -d
}

ADMIN_PASSWORD="$(secret_value "${FULLNAME}-admin" admin-password)"

# in_toolbox CMD... with NUL-separated stdin; prints combined output.
in_toolbox() {
    timeout "$((REQUEST_TIMEOUT + 15))" \
        kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
        exec -i "${TOOLBOX}" -c toolbox -- \
        timeout --signal=KILL "${REQUEST_TIMEOUT}" "$@" 2>&1
}

# sigul_as CONFIG [sigul args...], secrets as NUL-separated stdin.
sigul_as() {
    local config="$1"
    shift
    in_toolbox sigul --batch -c "${config}" "$@"
}

ADMIN_CONF=/etc/sigul/client.conf
if printf '%s\0' "${ADMIN_PASSWORD}" | sigul_as "${ADMIN_CONF}" list-users >/dev/null; then
    pass "the shared-certificate install authenticates the admin"
else
    fail "the shared-certificate install authenticates the admin"
fi

### Adopt per-client certificates (README runbook) ###################

log "adopting pki.clients with pki.mode=force and strict checking"
"${HELM[@]}" upgrade "${RELEASE}" "${CHART}" "${BASE_VALUES[@]}" \
    --set "pki.mode=force" \
    --set "pki.forceRestartWorkloads=true" \
    --set "server.lenientUsernameCheck=no" \
    --set "pki.clients[0].name=admin" \
    --set "pki.clients[1].name=${CANARY}" \
    --set "pki.clients[2].name=${OTHER}" \
    --wait --timeout 10m
wait_for_release

for client in admin "${CANARY}" "${OTHER}"; do
    if [ -n "$(kube get secret "${FULLNAME}-client-${client}-p12" \
            -o jsonpath='{.data.client\.p12}')" ]; then
        pass "${FULLNAME}-client-${client}-p12 is published"
    else
        fail "${FULLNAME}-client-${client}-p12 is published"
    fi
done

### Users, a key and grants, from the toolbox ########################

if printf '%s\0' "${ADMIN_PASSWORD}" | sigul_as "${ADMIN_CONF}" list-users >/dev/null; then
    pass "the toolbox, on the admin's own certificate, runs list-users"
else
    fail "the toolbox, on the admin's own certificate, runs list-users"
fi

KEY_PASSPHRASE="$(genpw)"
CANARY_PASSWORD="$(genpw)"
OTHER_PASSWORD="$(genpw)"
CANARY_KEY_PASSPHRASE="$(genpw)"
OTHER_KEY_PASSPHRASE="$(genpw)"

admin_step() {
    # admin_step LABEL STDIN-VALUES... -- SIGUL-ARGS...
    local label="$1" values=() out
    shift
    while [ "$1" != "--" ]; do values+=("$1"); shift; done
    shift
    if out="$(printf '%s\0' "${values[@]}" | sigul_as "${ADMIN_CONF}" "$@")"; then
        pass "toolbox: ${label}"
    else
        fail "toolbox: ${label}"
        printf '%s\n' "${out}"
    fi
}

admin_step "new-user ${CANARY}" "${ADMIN_PASSWORD}" "${CANARY_PASSWORD}" \
    -- new-user --with-password "${CANARY}"
admin_step "new-user ${OTHER}" "${ADMIN_PASSWORD}" "${OTHER_PASSWORD}" \
    -- new-user --with-password "${OTHER}"
admin_step "new-key ${KEY}" "${ADMIN_PASSWORD}" "${KEY_PASSPHRASE}" \
    -- new-key --key-admin admin \
    --gnupg-name-real 'Sigul per-client test' \
    --gnupg-name-email 'pki-clients@example.invalid' "${KEY}"
admin_step "grant-key-access ${KEY} ${CANARY}" "${KEY_PASSPHRASE}" "${CANARY_KEY_PASSPHRASE}" \
    -- grant-key-access "${KEY}" "${CANARY}"
admin_step "grant-key-access ${KEY} ${OTHER}" "${KEY_PASSPHRASE}" "${OTHER_KEY_PASSPHRASE}" \
    -- grant-key-access "${KEY}" "${OTHER}"

### Client bundles, built as the README describes ####################

# build_bundle NAME: an NSS database and client.conf in the toolbox's
# /workspace/NAME, from the published Secrets alone.
build_bundle() {
    local name="$1" dir="/workspace/$1" nss_password
    nss_password="$(genpw)"
    in_toolbox mkdir -p "${dir}/nss" >/dev/null
    secret_value "${FULLNAME}-client-${name}-p12" client.p12 \
        | in_toolbox sh -c "cat > ${dir}/client.p12" >/dev/null
    secret_value "${FULLNAME}-ca-public" ca.crt \
        | in_toolbox sh -c "cat > ${dir}/ca.crt" >/dev/null
    secret_value "${FULLNAME}-ca-public" bridge.crt \
        | in_toolbox sh -c "cat > ${dir}/bridge.crt" >/dev/null
    secret_value "${FULLNAME}-passwords" p12-password \
        | in_toolbox sh -c "cat > ${dir}/p12.pw" >/dev/null
    printf '%s' "${nss_password}" \
        | in_toolbox sh -c "cat > ${dir}/nss.pw" >/dev/null
    in_toolbox bash -euc "
        cd ${dir}
        certutil -N -d sql:nss -f nss.pw
        certutil -A -d sql:nss -f nss.pw -n sigul-ca -t CT,C,C -a -i ca.crt
        certutil -A -d sql:nss -f nss.pw -n sigul-bridge-cert -t P,P,P -a -i bridge.crt
        pk12util -i client.p12 -d sql:nss -k nss.pw -w p12.pw
        sed -e 's|^user-name:.*|user-name: ${name}|' \
            -e 's|^nss-dir:.*|nss-dir: ${dir}/nss|' \
            -e \"s|^nss-password:.*|nss-password: \$(cat nss.pw)|\" \
            ${ADMIN_CONF} > client.conf
        rm -f client.p12 p12.pw
    " >/dev/null
}

build_bundle "${CANARY}"
build_bundle "${OTHER}"
CANARY_CONF="/workspace/${CANARY}/client.conf"
OTHER_CONF="/workspace/${OTHER}/client.conf"
printf 'per-client certificate test\n' | in_toolbox sh -c 'cat > /workspace/msg.txt' >/dev/null

# The server's rejections, counted before and after each negative
# check so each one is attributed to the request just made.
cn_mismatches() {
    {
        kube logs "${SERVER_POD}" -c server 2>/dev/null || true
        kube exec "${SERVER_POD}" -c server -- \
            cat /var/log/sigul_server.log 2>/dev/null || true
    } | grep -c 'Cert CN and user differ' || true
}

sign_as() {
    # sign_as CONFIG PASSPHRASE OUTPUT [extra sigul args before the command]
    local config="$1" passphrase="$2" output="$3"
    shift 3
    printf '%s\0' "${passphrase}" | sigul_as "${config}" "$@" \
        sign-text -o "${output}" "${KEY}" /workspace/msg.txt
}

### The checks #######################################################

if out="$(sign_as "${CANARY_CONF}" "${CANARY_KEY_PASSPHRASE}" /workspace/canary.asc)" \
        && in_toolbox grep -q 'BEGIN PGP SIGNATURE' /workspace/canary.asc; then
    pass "${CANARY} signs as itself with its own bundle"
else
    fail "${CANARY} signs as itself with its own bundle"
    printf '%s\n' "${out}"
fi

expect_cn_rejection() {
    # expect_cn_rejection LABEL STDIN-VALUE CONFIG SIGUL-ARGS...
    local label="$1" value="$2" config="$3" before after out
    shift 3
    before="$(cn_mismatches)"
    if out="$(printf '%s\0' "${value}" | sigul_as "${config}" "$@")"; then
        fail "${label}: the request succeeded"
        return
    fi
    after="$(cn_mismatches)"
    if grep -qi 'authentication failed' <<< "${out}" && [ "${after}" -gt "${before}" ]; then
        pass "${label}: rejected with 'Cert CN and user differ'"
    else
        fail "${label}: client said '${out//$'\n'/ }', server CN mismatches ${before} -> ${after}"
    fi
}

expect_cn_rejection "${CANARY}'s bundle claiming admin (correct admin password)" \
    "${ADMIN_PASSWORD}" "${CANARY_CONF}" -u admin list-users
expect_cn_rejection "${CANARY}'s bundle claiming ${OTHER} (${OTHER}'s key passphrase)" \
    "${OTHER_KEY_PASSPHRASE}" "${CANARY_CONF}" -u "${OTHER}" \
    sign-text -o /workspace/stolen.asc "${KEY}" /workspace/msg.txt
expect_cn_rejection "${OTHER}'s bundle claiming ${CANARY} (${CANARY}'s key passphrase)" \
    "${CANARY_KEY_PASSPHRASE}" "${OTHER_CONF}" -u "${CANARY}" \
    sign-text -o /workspace/stolen.asc "${KEY}" /workspace/msg.txt

if sign_as "${OTHER_CONF}" "${OTHER_KEY_PASSPHRASE}" /workspace/other.asc >/dev/null; then
    pass "${OTHER} still signs as itself"
else
    fail "${OTHER} still signs as itself"
fi

### Cutting off a client (README runbook) ############################

admin_step "revoke-key-access ${KEY} ${CANARY}" "${ADMIN_PASSWORD}" \
    -- revoke-key-access --password "${KEY}" "${CANARY}"
admin_step "delete-user ${CANARY}" "${ADMIN_PASSWORD}" -- delete-user "${CANARY}"

if out="$(sign_as "${CANARY_CONF}" "${CANARY_KEY_PASSPHRASE}" /workspace/after-delete.asc)"; then
    fail "${CANARY}'s bundle cannot sign once its user is deleted"
elif grep -qi 'authentication failed' <<< "${out}"; then
    pass "${CANARY}'s bundle cannot sign once its user is deleted"
else
    fail "${CANARY}'s bundle failed after delete-user, but not on authentication: ${out}"
fi
expect_cn_rejection "${CANARY}'s deleted bundle claiming admin" \
    "${ADMIN_PASSWORD}" "${CANARY_CONF}" -u admin list-users

echo
if [ "${#FAILED[@]}" -gt 0 ]; then
    log "${#FAILED[@]} FAILED, ${PASSED} passed"
    printf '  %s\n' "${FAILED[@]}"
    exit 1
fi
log "all ${PASSED} checks passed: a bundle authenticates only as its own user"
