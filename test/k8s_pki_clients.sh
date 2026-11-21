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
#   - a bundle make-bundle.sh builds from the cluster, in either
#     format, unpacks in the client image and signs through the bridge
#   - once a client's user is deleted its bundle can do nothing
#
# It also proves the chart's large-file limits (#156), which the same
# install sets - server.maxFilePayloadSize and
# server.requestTimeoutSeconds:
#   - the server.conf the server reads holds both values
#   - a file under the payload limit signs and its signature verifies
#   - a file over it fails promptly, with the reason in the server's
#     log, and the next request is served
#
# The Compose stack the other integration tests use has no PKI
# bootstrap Job, so this runs the chart's own.
#
# Usage (images already built and tagged locally; make-bundle.sh also
# needs certutil, pk12util, gpg, xz and jq on this host):
#   bash test/k8s_pki_clients.sh [--keep]
#
# Environment:
#   PKI_TEST_CLUSTER        kind cluster name    (default pki-clients)
#   PKI_TEST_BRIDGE_IMAGE   bridge image          (default bridge-linux-amd64-image:test)
#   PKI_TEST_SERVER_IMAGE   server image          (default server-linux-amd64-image:test)
#   PKI_TEST_CLIENT_IMAGE   client image          (default client-linux-amd64-image:test)
#   PKI_TEST_LOG_DIR        diagnostics on failure, and after any run
#                           with PKI_TEST_LARGE_FILE_BYTES set
#                           (default test-artifacts/k8s-pki-clients)
#   PKI_TEST_DIAG_TIMEOUT   seconds each diagnostics kubectl call may take (default 60)
#   PKI_TEST_DIAG_BUDGET    seconds all diagnostics together may take (default 180)
#   PKI_TEST_LARGE_FILE_BYTES    size of the file signed under the
#                           payload limit (default 4194304, 4 MiB). The
#                           limit is set 1 MiB above it. Set it above
#                           1 GiB - 2147483648, say - to sign a file
#                           that large. Whenever it is set, the run
#                           also reports what the request cost: the
#                           time taken, when the server's /tmp first
#                           held the whole file and how long the
#                           signature took from then (the interval in
#                           which no byte crosses the bridge), the
#                           server log's timestamps for the request,
#                           the server's memory and /tmp use, and the
#                           free disk on this host and on the node. It
#                           collects the diagnostics below even when
#                           it passes, and creates the file over the
#                           limit sparse. Needs that many bytes free
#                           in the toolbox's /workspace and as many
#                           again in the server's /tmp.
#   PKI_TEST_LARGE_FILE_TIMEOUT  seconds that signing may take when
#                           PKI_TEST_LARGE_FILE_BYTES is set (default
#                           1800, the request timeout installed)
#
# --keep leaves the cluster up for inspection; otherwise it is deleted.
#
# On failure, and after any run with PKI_TEST_LARGE_FILE_BYTES set,
# PKI_TEST_LOG_DIR holds, for the bridge, server, admin toolbox and
# bootstrap Job (COMPONENT), and each of their pods (POD):
#   resources.txt                 pods, Jobs and Secrets (get -o wide)
#   events.txt                    namespace events, oldest first
#   workloads.yaml                StatefulSets, Deployments and Jobs
#                                 (get -o yaml)
#   COMPONENT.log                 current containers' stdout, every
#                                 container, prefixed and timestamped
#   COMPONENT.describe.txt        kubectl describe of the pods: probe
#                                 failures, last state, restart reasons
#   POD.CONTAINER.previous.log    the previous container's stdout
#                                 (logs --previous --timestamps), for
#                                 each container that restarted
#   POD.sigul_bridge.log          /var/log/sigul_bridge.log and
#   POD.sigul_server.log          /var/log/sigul_server.log, the
#                                 daemons' own logs; a first line
#                                 "UNAVAILABLE: ..." and kubectl's error
#                                 instead when the container would not
#                                 take an exec
# Collection is best effort: it never changes the exit status or stops
# the cluster being deleted. Every kubectl call in it has a deadline
# (PKI_TEST_DIAG_TIMEOUT) and the calls together have a budget
# (PKI_TEST_DIAG_BUDGET), so an API server that stops answering cannot
# hold the cleanup trap past the budget. A file whose query the spent
# budget skipped says "SKIPPED: ..." instead.

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

# The large-file limits (#156). The payload limit sits 1 MiB above the
# file signed under it, and the file refused is one byte over the
# limit, so the default run moves only a few mebibytes.
LARGE_FILE_BYTES="${PKI_TEST_LARGE_FILE_BYTES:-4194304}"
case "${LARGE_FILE_BYTES}" in
    '' | 0* | *[!0-9]*)
        printf 'PKI_TEST_LARGE_FILE_BYTES must be a positive integer, got %s\n' \
            "${LARGE_FILE_BYTES}" >&2
        exit 2
        ;;
esac
PAYLOAD_LIMIT=$((LARGE_FILE_BYTES + 1048576))
OVER_LIMIT_BYTES=$((PAYLOAD_LIMIT + 1))
# Not the chart's default, so that finding it in server.conf shows the
# value was carried there.
SERVER_REQUEST_TIMEOUT=1800
# How long signing the file under the limit may take: an ordinary
# request's bound, or far longer for a run above 1 GiB.
LARGE_FILE_TIMEOUT="${REQUEST_TIMEOUT}"
if [ -n "${PKI_TEST_LARGE_FILE_BYTES:-}" ]; then
    LARGE_FILE_TIMEOUT="${PKI_TEST_LARGE_FILE_TIMEOUT:-${SERVER_REQUEST_TIMEOUT}}"
fi
# A refused upload must fail well inside this. Half the bridge's idle
# deadline (patch 11, 120 s): a client that only fails when the bridge
# gives up on a silent connection has hung, and does not pass.
OVER_LIMIT_BOUND=60

PASSED=0
FAILED=()

log() { printf '[pki-clients] %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; PASSED=$((PASSED + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILED+=("$*"); }
kube() { kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"; }
genpw() { head -c 18 /dev/urandom | base64 | tr -d '=+/'; }

# A crash-looping container can leave kubectl waiting on its stream,
# and an API server that stops answering can stall any call, so every
# diagnostics query goes through diag and its deadline. Each call also
# stops at DIAG_DEADLINE, which collect_diagnostics sets from the
# budget, so the whole collection leaves the job time to delete the
# cluster and upload the artefact.
DIAG_TIMEOUT="${PKI_TEST_DIAG_TIMEOUT:-60}"
DIAG_BUDGET="${PKI_TEST_DIAG_BUDGET:-180}"
DIAG_DEADLINE=0
diag() {
    local left=$((DIAG_DEADLINE - SECONDS))
    if [ "${left}" -le 0 ]; then
        printf 'SKIPPED: diagnostics budget of %s s spent\n' "${DIAG_BUDGET}" >&2
        return 124
    fi
    if [ "${left}" -gt "${DIAG_TIMEOUT}" ]; then
        left="${DIAG_TIMEOUT}"
    fi
    timeout "${left}" kubectl --context "${CONTEXT}" -n "${NAMESPACE}" "$@"
}

# daemon_log POD DAEMON: Sigul writes /var/log/sigul_DAEMON.log, not
# stdout, from the container named DAEMON. A container that will not
# take an exec gets a file saying so instead.
daemon_log() {
    local pod="$1" daemon="$2" out rc
    out="${LOG_DIR}/${pod}.sigul_${daemon}.log"
    diag exec "${pod}" -c "${daemon}" -- cat "/var/log/sigul_${daemon}.log" \
        > "${out}" 2> "${out}.err"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        {
            printf 'UNAVAILABLE: reading /var/log/sigul_%s.log from %s/%s exited %s\n' \
                "${daemon}" "${pod}" "${daemon}" "${rc}"
            cat "${out}.err"
        } > "${out}"
    fi
    rm -f "${out}.err"
}

# Best effort throughout: cleanup runs this in a subshell where errexit
# does not apply, so one failed kubectl call does not stop the rest.
collect_diagnostics() {
    local component pod container restarts
    DIAG_DEADLINE=$((SECONDS + DIAG_BUDGET))
    mkdir -p "${LOG_DIR}"
    diag get pods,jobs,secrets -o wide > "${LOG_DIR}/resources.txt" 2>&1
    diag get events --sort-by=.lastTimestamp > "${LOG_DIR}/events.txt" 2>&1
    diag get statefulset,deployment,job -o yaml > "${LOG_DIR}/workloads.yaml" 2>&1
    for component in bridge server admin-toolbox pki-bootstrap; do
        diag logs -l "app.kubernetes.io/component=${component}" \
            --all-containers --prefix --timestamps --tail=2000 \
            > "${LOG_DIR}/${component}.log" 2>&1
        diag describe pods -l "app.kubernetes.io/component=${component}" \
            > "${LOG_DIR}/${component}.describe.txt" 2>&1
        for pod in $(diag get pods -l "app.kubernetes.io/component=${component}" \
                -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
            while read -r container restarts; do
                [ -n "${container}" ] && [ "${restarts:-0}" -gt 0 ] 2>/dev/null \
                    || continue
                diag logs "${pod}" -c "${container}" --previous --timestamps \
                    > "${LOG_DIR}/${pod}.${container}.previous.log" 2>&1
            done < <(diag get pod "${pod}" -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{" "}{.restartCount}{"\n"}{end}{range .status.containerStatuses[*]}{.name}{" "}{.restartCount}{"\n"}{end}' 2>/dev/null)
            case "${component}" in
                bridge | server) daemon_log "${pod}" "${component}" ;;
            esac
        done
    done
}

# A large-file run keeps its diagnostics when it passes too: the
# daemons' logs hold the server's own timings for the request.
cleanup() {
    local rc=$?
    if [ "${rc}" -ne 0 ] || [ "${#FAILED[@]}" -gt 0 ] \
            || [ -n "${PKI_TEST_LARGE_FILE_BYTES:-}" ]; then
        ( collect_diagnostics ) || true
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
    --set "server.maxFilePayloadSize=${PAYLOAD_LIMIT}"
    --set "server.requestTimeoutSeconds=${SERVER_REQUEST_TIMEOUT}"
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

# Lines of the server's log matching a pattern. The server's
# rejections are counted before and after each negative check so each
# one is attributed to the request just made.
server_log_count() {
    {
        kube logs "${SERVER_POD}" -c server 2>/dev/null || true
        kube exec "${SERVER_POD}" -c server -- \
            cat /var/log/sigul_server.log 2>/dev/null || true
    } | grep -c -- "$1" || true
}

cn_mismatches() { server_log_count 'Cert CN and user differ'; }

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

### Large-file limits (#156) #########################################

# The limits this release was installed with, in the server.conf
# nss-init.sh rendered. Counted, never printed: the file holds the NSS
# password.
conf_lines() {
    kube exec "${SERVER_POD}" -c server -- \
        grep -cx -- "$1" /etc/sigul/server.conf 2>/dev/null || true
}
for line in "max-file-payload-size: ${PAYLOAD_LIMIT}" \
        "request-timeout: ${SERVER_REQUEST_TIMEOUT}"; do
    if [ "$(conf_lines "${line}")" = 1 ]; then
        pass "the server's server.conf holds '${line}'"
    else
        fail "the server's server.conf holds '${line}'"
    fi
done

# large_toolbox CMD...: in_toolbox, given as long as the large file may
# take rather than an ordinary request's bound.
large_toolbox() { REQUEST_TIMEOUT="${LARGE_FILE_TIMEOUT}" in_toolbox "$@"; }

# server_exec SECONDS CMD...: CMD in the server container, bounded so
# that a stalled exec stream cannot hold the run.
server_exec() {
    local limit="$1"
    shift
    timeout --kill-after=5 "${limit}" \
        kubectl --context "${CONTEXT}" -n "${NAMESPACE}" \
        exec "${SERVER_POD}" -c server -- "$@" 2>/dev/null
}

# log_df LABEL CMD...: the output of CMD, a df, one log line each.
log_df() {
    local label="$1" out line
    shift
    if out="$("$@" 2>&1)" && [ -n "${out}" ]; then
        while IFS= read -r line; do
            log "large-file run: df ${label}: ${line}"
        done <<< "${out}"
    else
        log "large-file run: df ${label}: unavailable"
    fi
}

# A large-file run reports the disk it starts with, and creates the
# file over the limit without writing its data: the server refuses
# that file on its declared size, so its content does not matter.
over_limit_file="head -c ${OVER_LIMIT_BYTES} /dev/urandom > /workspace/over-limit.bin"
if [ -n "${PKI_TEST_LARGE_FILE_BYTES:-}" ]; then
    log_df "on the runner" df -h /
    log_df "on the node, from the server's /tmp" server_exec 30 df -h /tmp
    log_df "on the node, from the toolbox's /workspace" in_toolbox df -h /workspace
    over_limit_file="truncate -s ${OVER_LIMIT_BYTES} /workspace/over-limit.bin"
    log "large-file run: the ${OVER_LIMIT_BYTES}-byte file over the limit is sparse, which saves ${OVER_LIMIT_BYTES} bytes of the toolbox's /workspace and the time to write them"
fi

# Both files are generated in the toolbox, as the soak generates its
# payloads: the apiserver's exec stream is far too slow to carry them.
if large_toolbox sh -c "
        head -c ${LARGE_FILE_BYTES} /dev/urandom > /workspace/under-limit.bin &&
        ${over_limit_file}
        " >/dev/null \
        && printf '%s\0' "${ADMIN_PASSWORD}" | in_toolbox sh -c "
        sigul --batch -c ${ADMIN_CONF} get-public-key --password ${KEY} \
            > /workspace/large-file-key.asc" >/dev/null; then
    pass "the toolbox holds a ${LARGE_FILE_BYTES}-byte file, a ${OVER_LIMIT_BYTES}-byte file and ${KEY}'s public key"
else
    fail "the toolbox holds a ${LARGE_FILE_BYTES}-byte file, a ${OVER_LIMIT_BYTES}-byte file and ${KEY}'s public key"
fi

# sign_data_as CONFIG PASSPHRASE NAME: a detached signature of
# /workspace/NAME.bin in /workspace/NAME.sig.
sign_data_as() {
    printf '%s\0' "$2" | sigul_as "$1" \
        sign-data -o "/workspace/$3.sig" "${KEY}" "/workspace/$3.bin"
}

# TMP_SAMPLE, run in the server container, prints 'total' and the
# bytes in /tmp, when du reports them, and 'payload' and the size of
# the largest upload in it, 0 for none, when find succeeds.
# shellcheck disable=SC2016  # expanded by the server container
TMP_SAMPLE='used="$(du -sb /tmp 2>/dev/null)"
[ -z "${used}" ] || printf "total %s\n" "${used%%[[:space:]]*}"
sizes="$(find /tmp -mindepth 1 -maxdepth 1 -type f -name "tmp*" -printf "%s\n")" &&
    printf "payload %s\n" "$(printf "0\n%s\n" "${sizes}" | sort -n | tail -n 1)"'

# A large-file run reports what the request cost the server. The
# upload is in the server's /tmp only while the request runs, so its
# size is sampled meanwhile: watch_server_tmp FILE keeps the largest
# total use of /tmp seen in FILE until FILE.stop appears or the
# request's bound passes. That total counts directories and any other
# file too, so it can reach the file's size before the upload has, and
# says nothing of when the upload ended. The server writes the upload,
# in order, to a file of its own directly in /tmp (tempfile.mkstemp,
# so named tmp*), which holds the whole file once it is as large as
# it: each sample reads the largest such file's size for that.
# The upload ends between two samples: after the last one that began
# and answered with less than the whole file, and before the first
# that answered with all of it. FILE.full then holds the two, in
# seconds since signing began (${started}): when that last sample
# began, 0 if none did, and when the first full one returned. A
# failed or timed-out sample tells nothing, so the two may lie more
# than one sampling period apart. After the upload nothing crosses
# the bridge until the server replies, and the bridge drops a
# request silent for 120 s. The second time may fall after signing
# has ended, when that sample's exec returned late: the reader of
# FILE.full must not take a time later than the signing's own for
# the end of the upload.
# Each sample's exec is bounded too, by 30 s or the time left, so a
# stalled exec stream cannot hold the sampler, and the wait for it,
# past that bound; with no time left it stops rather than sample.
watch_server_tmp() {
    local peak=0 sample used payload left asked below=0 full=""
    local deadline=$((SECONDS + LARGE_FILE_TIMEOUT))
    while [ ! -e "$1.stop" ] && [ "${SECONDS}" -lt "${deadline}" ]; do
        left=$((deadline - SECONDS))
        # SECONDS may tick past the deadline after the loop's check,
        # and GNU timeout reads 0 as no limit at all.
        if [ "${left}" -le 0 ]; then
            break
        elif [ "${left}" -gt 30 ]; then
            left=30
        fi
        asked=$((SECONDS - started))
        sample="$(server_exec "${left}" sh -c "${TMP_SAMPLE}" || true)"
        used="$(sed -n 's/^total //p' <<< "${sample}")"
        payload="$(sed -n 's/^payload //p' <<< "${sample}")"
        if [[ "${used}" =~ ^[0-9]+$ ]] && [ "${used}" -gt "${peak}" ]; then
            peak="${used}"
        fi
        printf '%s\n' "${peak}" > "$1"
        if ! [[ "${payload}" =~ ^[0-9]+$ ]]; then
            payload=""
        fi
        if [ -z "${full}" ] && [ -n "${payload}" ]; then
            if [ "${payload}" -ge "${LARGE_FILE_BYTES}" ]; then
                full=$((SECONDS - started))
                printf '%s %s\n' "${below}" "${full}" > "$1.full"
            else
                below="${asked}"
            fi
        fi
        sleep 2
    done
}

# log_stamp LINE MARKER: what the server's log wrote ahead of MARKER
# on LINE, its timestamp and level.
log_stamp() {
    local stamp="${1%%"$2"*}"
    stamp="${stamp%"${stamp##*[![:space:]]}"}"
    printf '%s' "${stamp:-unavailable}"
}

LARGE_TMP=""
signed=""
log_lines_before=0
started="${SECONDS}"
if [ -n "${PKI_TEST_LARGE_FILE_BYTES:-}" ]; then
    LARGE_TMP="$(mktemp -d)"
    # Where the server's log stands, so that the lines read from it
    # afterwards are this request's.
    log_lines_before="$(server_exec 30 cat /var/log/sigul_server.log \
        | wc -l || true)"
    started="${SECONDS}"
    watch_server_tmp "${LARGE_TMP}/tmp-peak" &
    tmp_watcher=$!
fi
if out="$(REQUEST_TIMEOUT="${LARGE_FILE_TIMEOUT}" \
        sign_data_as "${CANARY_CONF}" "${CANARY_KEY_PASSPHRASE}" under-limit)"; then
    signed=yes
    pass "a ${LARGE_FILE_BYTES}-byte file, under the ${PAYLOAD_LIMIT}-byte limit, is signed"
else
    fail "a ${LARGE_FILE_BYTES}-byte file, under the ${PAYLOAD_LIMIT}-byte limit, is signed"
    printf '%s\n' "${out}"
fi
elapsed=$((SECONDS - started))
if [ -n "${LARGE_TMP}" ]; then
    touch "${LARGE_TMP}/tmp-peak.stop"
    wait "${tmp_watcher}" || true
    memory_peak="$(server_exec 30 cat /sys/fs/cgroup/memory.peak \
        || echo unavailable)"
    # anon is the server's own memory and file is page cache, which
    # the kernel can give back: memory.peak at the limit with events
    # showing no oom is page cache, not the server running out.
    memory_stat="$(server_exec 30 cat /sys/fs/cgroup/memory.stat \
        | grep -E '^(anon|file) ' | paste -sd ' ' - || true)"
    memory_events="$(server_exec 30 cat /sys/fs/cgroup/memory.events \
        | paste -sd ' ' - || true)"
    tmp_peak="$(cat "${LARGE_TMP}/tmp-peak" 2>/dev/null || echo unavailable)"
    tmp_below=""
    tmp_full=""
    read -r tmp_below tmp_full 2>/dev/null < "${LARGE_TMP}/tmp-peak.full" || true
    # The request's own lines in the server's log: the first 'Signed
    # data' written since signing began, and the 'Request:' before it.
    request_line=""
    signed_line=""
    {
        IFS= read -r request_line
        IFS= read -r signed_line
    } < <(server_exec 30 cat /var/log/sigul_server.log \
        | awk -v skip="${log_lines_before:-0}" '
            NR <= skip { next }
            /Request:/ { request = $0 }
            /Signed data/ { print request; print; signed = 1; exit }
            END { if (!signed) print request }') || true
    # A request that failed returned no signature, and the bridge's
    # deadline is one way it fails: its times are those of the
    # failure, and are not reported as a signature's.
    if [ -n "${signed}" ]; then
        log "large-file run: ${LARGE_FILE_BYTES} bytes signed in ${elapsed} s"
    else
        log "large-file run: signing ${LARGE_FILE_BYTES} bytes failed after ${elapsed} s, so the time to a signature is unavailable"
    fi
    if [ -z "${tmp_full}" ] || [ -z "${tmp_below}" ]; then
        log "large-file run: server /tmp was never seen holding the whole file, so the silent interval is unavailable"
    elif [ "${tmp_full}" -gt "${elapsed}" ]; then
        # The sample's exec returned after signing had ended, so
        # its time is not the upload's end.
        log "large-file run: the sample that found the whole file in server /tmp returned ${tmp_full} s after signing began, later than the ${elapsed} s the signing took, so the silent interval is unavailable"
    else
        # The upload ended after the last sample to find less began
        # and before the first to find it all returned, so the time
        # from its end lies between the two differences below.
        log "large-file run: server /tmp first held the whole file ${tmp_full} s after signing began; the last sample to find less began at ${tmp_below} s, so the upload ended between the two, each to the second"
        if [ -n "${signed}" ]; then
            log "large-file run: $((elapsed - tmp_full)) s from then to the signature returning; that approximates the silent interval, which lies between $((elapsed - tmp_full)) and $((elapsed - tmp_below)) s"
        else
            log "large-file run: $((elapsed - tmp_full)) s from then to the failure, which came between $((elapsed - tmp_full)) and $((elapsed - tmp_below)) s after the upload ended; no signature returned, so the time from then to a signature is unavailable"
        fi
    fi
    log "large-file run: server log 'Request:' line stamped $(log_stamp "${request_line}" 'Request:')"
    log "large-file run: server log 'Signed data' line stamped $(log_stamp "${signed_line}" 'Signed data')"
    log "large-file run: server memory.peak ${memory_peak} bytes, since the container started"
    log "large-file run: server memory.stat after signing: ${memory_stat:-unavailable}"
    log "large-file run: server memory.events since the container started: ${memory_events:-unavailable}"
    log "large-file run: server /tmp peak ${tmp_peak} bytes, sampled every 2 s"
    rm -rf "${LARGE_TMP}"
fi

if out="$(large_toolbox bash -eu -c "
        export GNUPGHOME=\$(mktemp -d)
        gpg --batch --quiet --import /workspace/large-file-key.asc
        gpg --batch --verify /workspace/under-limit.sig /workspace/under-limit.bin
        ")"; then
    pass "the signature of the ${LARGE_FILE_BYTES}-byte file verifies against ${KEY}'s public key"
else
    fail "the signature of the ${LARGE_FILE_BYTES}-byte file verifies against ${KEY}'s public key"
    printf '%s\n' "${out}"
fi

# Over the limit the server logs the reason and, in Sigul v1.4, sends
# no reply. What the client then prints is logged here and not
# asserted. Its status is: 124 and 137 are this script's own timeouts
# ending a client that hung, so they do not count as failing promptly.
refusals_before="$(server_log_count 'Payload too large')"
started="${SECONDS}"
status=0
out="$(sign_data_as "${CANARY_CONF}" "${CANARY_KEY_PASSPHRASE}" over-limit)" || status=$?
elapsed=$((SECONDS - started))
refusals_after="$(server_log_count 'Payload too large')"
log "over the limit the client exited ${status} after ${elapsed} s, printing: ${out//$'\n'/ }"
case "${status}" in
    0 | 124 | 137) refused=false ;;
    *) refused=true ;;
esac
if ${refused} && [ "${elapsed}" -lt "${OVER_LIMIT_BOUND}" ]; then
    pass "a ${OVER_LIMIT_BYTES}-byte file, over the limit, fails within ${OVER_LIMIT_BOUND} s"
else
    fail "a ${OVER_LIMIT_BYTES}-byte file, over the limit, fails within ${OVER_LIMIT_BOUND} s: exit ${status} after ${elapsed} s"
fi
if [ "${refusals_after}" -gt "${refusals_before}" ]; then
    pass "the server's log names the reason: 'Payload too large'"
else
    fail "the server's log names the reason: 'Payload too large' counted ${refusals_before} -> ${refusals_after}"
fi

if sign_as "${CANARY_CONF}" "${CANARY_KEY_PASSPHRASE}" /workspace/after-refusal.asc >/dev/null; then
    pass "the next request after the refused upload is served"
else
    fail "the next request after the refused upload is served"
fi

### Bundles from make-bundle.sh (#116) ###############################

# Builds ${CANARY}'s bundle from the cluster in each format, installs
# it in the toolbox (the client image) as its consumer would, and
# signs with it through the bridge. Needs certutil, pk12util, gpg, xz
# and jq on this host.
MAKE_BUNDLE="${CHART}/files/toolbox/make-bundle.sh"
BUNDLE_TMP="$(mktemp -d)"
printf '%s\n' "${CANARY_KEY_PASSPHRASE}" > "${BUNDLE_TMP}/passphrase"

bundle_signs() {
    # bundle_signs FORMAT
    local format="$1" dir="/workspace/bundle-$1" out="${BUNDLE_TMP}/$1" result
    if ! bash "${MAKE_BUNDLE}" --context "${CONTEXT}" --namespace "${NAMESPACE}" \
            --release "${FULLNAME}" --client "${CANARY}" \
            --bridge "${FULLNAME}-bridge.${NAMESPACE}.svc.cluster.local" \
            --nss-dir "${dir}/sigul" --format "${format}" \
            --key-passphrase-file "${BUNDLE_TMP}/passphrase" \
            --out "${out}" >/dev/null; then
        fail "make-bundle.sh --format ${format} builds ${CANARY}'s bundle"
        return
    fi
    pass "make-bundle.sh --format ${format} builds ${CANARY}'s bundle"
    if [ "${format}" = action ]; then
        # Unpack SIGUL_CREDENTIALS as sigul-sign-action does.
        base64 -d < "${out}/sigul-credentials.b64" > "${out}/credentials.json"
        jq -r .config "${out}/credentials.json" | base64 -d > "${out}/client.conf"
        jq -r .pki "${out}/credentials.json" | base64 -d > "${out}/sigul-pki.asc"
        if [ "$(jq -r .password "${out}/credentials.json")" = "${CANARY_KEY_PASSPHRASE}" ]; then
            pass "SIGUL_CREDENTIALS carries the key passphrase"
        else
            fail "SIGUL_CREDENTIALS carries the key passphrase"
        fi
    fi
    in_toolbox mkdir -p "${dir}" >/dev/null
    in_toolbox sh -c "cat > ${dir}/client.conf" < "${out}/client.conf" >/dev/null
    in_toolbox sh -c "cat > ${dir}/sigul-pki.asc" < "${out}/sigul-pki.asc" >/dev/null
    if ! printf '%s\n' "${CANARY_KEY_PASSPHRASE}" | in_toolbox bash -eu -o pipefail -c "
            export GNUPGHOME=\$(mktemp -d)
            gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 0 \
                -d ${dir}/sigul-pki.asc | tar -xJf - -C ${dir}
            " >/dev/null; then
        fail "the --format ${format} bundle decrypts and unpacks in the client image"
        return
    fi
    if result="$(sign_as "${dir}/client.conf" "${CANARY_KEY_PASSPHRASE}" "${dir}/signed.asc")" \
            && in_toolbox grep -q 'BEGIN PGP SIGNATURE' "${dir}/signed.asc"; then
        pass "${CANARY} signs through the bridge with its --format ${format} bundle"
    else
        fail "${CANARY} signs through the bridge with its --format ${format} bundle"
        printf '%s\n' "${result}"
    fi
}

bundle_signs files
bundle_signs action
rm -rf "${BUNDLE_TMP}"

if in_toolbox bash /scripts/make-bundle.sh --help >/dev/null; then
    pass "the admin toolbox carries make-bundle.sh"
else
    fail "the admin toolbox carries make-bundle.sh"
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
