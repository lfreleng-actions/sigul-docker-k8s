#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Connection-lifecycle tests for the running compose stack.
#
# The signing suite exercises every operation, but each invocation
# opens a fresh connection and never tears one down against a peer
# that misbehaves. That gap let a deadlock ship: the server served one
# request in production and then answered nothing for six hours while
# every health signal said it was fine. These tests target the
# lifecycle itself - what happens between requests, and when a peer
# goes away.
#
# Run against an already-deployed stack, after run-signing-tests.sh:
#
#   SIGUL_CLIENT_IMAGE=client-...:test ./scripts/run-lifecycle-tests.sh
#
# Every test asserts on observable state - socket tables, process
# tables, whether the next request succeeds - not on log text.

set -euo pipefail

CLIENT_IMAGE="${SIGUL_CLIENT_IMAGE:-}"
CLIENT_NSS_VOLUME="sigul-docker_sigul_client_nss"
CLIENT_CONFIG_VOLUME="sigul-docker_sigul_client_config"
SERVER_CONTAINER="sigul-server"
BRIDGE_CONTAINER="sigul-bridge"
SERVER_PORT=44333

if [[ -z "$CLIENT_IMAGE" ]]; then
    echo "ERROR: SIGUL_CLIENT_IMAGE environment variable must be set" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ ! -f "${PROJECT_ROOT}/test-artifacts/admin-password" ]]; then
    echo "ERROR: test-artifacts/admin-password missing" >&2
    exit 1
fi
ADMIN_PASSWORD="$(cat "${PROJECT_ROOT}/test-artifacts/admin-password")"

NETWORK="$(docker network ls --filter 'name=sigul' --format '{{.Name}}' | head -1)"
if [[ -z "$NETWORK" ]]; then
    echo "ERROR: no sigul docker network found - is the stack up?" >&2
    exit 1
fi

PASSED=0
FAILED=0

pass() { echo "  PASS  $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL  $*" >&2; FAILED=$((FAILED + 1)); }
note() { echo "        $*"; }
phase() { echo; echo "=== $* ==="; }

# One read-only request through the whole stack. Prints the user list
# (or the error) and returns the client's exit status.
#
# --init matters: bash exec()s a single-command -c string, which would
# make `timeout` PID 1, and GNU timeout exits 125 as PID 1 without
# running anything.
list_users() {
    printf '%s\0' "$ADMIN_PASSWORD" | docker run --rm -i --init \
        --user 1000:1000 \
        --network "$NETWORK" \
        -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
        -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        bash -c 'timeout 60 sigul --batch -c /etc/sigul/client.conf list-users' \
        2>&1
}

# Count bridge-side sockets on the server port in a given TCP state.
bridge_sockets_in() {
    local state="$1"
    docker exec "$BRIDGE_CONTAINER" sh -c \
        "ss -Htan state ${state} '( sport = :${SERVER_PORT} )' 2>/dev/null | wc -l" \
        | tr -d '[:space:]'
}

# Count established server->bridge connections, as the readiness probe does.
server_established() {
    docker exec "$SERVER_CONTAINER" sh -c \
        "ss -Htn state established '( dport = :${SERVER_PORT} )' 2>/dev/null | wc -l" \
        | tr -d '[:space:]'
}

# Wait up to $1 seconds for the server to hold an established connection.
wait_for_server_connection() {
    local deadline=$(( $(date +%s) + $1 ))
    while (( $(date +%s) < deadline )); do
        if [[ "$(server_established)" != "0" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ----------------------------------------------------------------------
phase "0: baseline - one request must work before we break anything"
# ----------------------------------------------------------------------
out="$(list_users)" || true
if [[ "$out" == *admin* ]]; then
    pass "baseline request succeeded"
else
    fail "baseline request failed: $out"
    echo "Stack is not healthy; aborting lifecycle tests." >&2
    exit 1
fi

# ----------------------------------------------------------------------
phase "1: sequential requests - the server must re-arm after each"
# ----------------------------------------------------------------------
# One forked child per request; after each the parent must fork a
# replacement that reconnects. A wedged teardown stops that here.
ok=0
for n in 1 2 3; do
    out="$(list_users)" || true
    if [[ "$out" == *admin* ]]; then
        ok=$((ok + 1))
    else
        note "request $n failed: $out"
    fi
done
if (( ok == 3 )); then
    pass "3 sequential requests all succeeded"
else
    fail "only ${ok}/3 sequential requests succeeded"
fi

if wait_for_server_connection 20; then
    pass "server re-established its bridge connection after the last request"
else
    fail "server has no established bridge connection after requests"
fi

# ----------------------------------------------------------------------
phase "2: failed handshakes on the server port must not leak sockets"
# ----------------------------------------------------------------------
# Before the fix, a server-side TLS handshake failure left the accepted
# socket unclosed - one CLOSE-WAIT per attempt, forever. An external
# scanner or a misconfigured peer could exhaust the bridge.
#
# The bridge accepts on the server port only between servers, so bogus
# connects queue in the listen backlog until the next request cycle
# completes; the real request below is what drains them through the
# handshake-failure path being tested.
before="$(bridge_sockets_in close-wait)"
for _ in 1 2 3 4 5; do
    docker run --rm --init --network "$NETWORK" "$CLIENT_IMAGE" \
        python3 -c "import socket; socket.create_connection(('${BRIDGE_CONTAINER}', ${SERVER_PORT}), timeout=8).close()" \
        >/dev/null 2>&1 || true
done
out="$(list_users)" || true
if [[ "$out" == *admin* ]]; then
    pass "request succeeded with bogus connections queued"
else
    fail "request failed with bogus connections queued: $out"
fi

# The real server must still be able to reconnect past the noise.
if wait_for_server_connection 30; then
    pass "server reconnected after the bogus handshakes"
else
    fail "server did not reconnect after the bogus handshakes"
fi
sleep 2
after="$(bridge_sockets_in close-wait)"
note "bridge CLOSE-WAIT sockets: before=${before} after=${after}"
if (( after <= before )); then
    pass "no sockets leaked by 5 failed server-side handshakes"
else
    fail "failed handshakes leaked $((after - before)) socket(s) in CLOSE-WAIT"
fi

# ----------------------------------------------------------------------
phase "3: server dies while the bridge waits for a client"
# ----------------------------------------------------------------------
# This is the production sequence. The bridge accepts the server, then
# blocks waiting for a client - potentially for hours. If the server's
# connection dies in that window, an unpatched bridge notices only when
# a client finally arrives, and hands it the dead connection. It also
# never reads the server's FIN, so its half stays in CLOSE-WAIT and an
# unpatched server's teardown waits on it forever.
before="$(bridge_sockets_in close-wait)"
docker restart "$SERVER_CONTAINER" >/dev/null 2>&1
sleep 5
after="$(bridge_sockets_in close-wait)"
note "bridge CLOSE-WAIT sockets: before=${before} after=${after}"
if (( after <= before )); then
    pass "bridge closed the dead server socket (no new CLOSE-WAIT)"
else
    fail "bridge left $((after - before)) dead server socket(s) in CLOSE-WAIT"
fi

if wait_for_server_connection 60; then
    pass "restarted server established a new bridge connection"
else
    fail "restarted server never connected to the bridge"
fi

# The first request after the restart must succeed. An unpatched bridge
# pairs it with the dead socket and it fails with "Unexpected EOF".
out="$(list_users)" || true
if [[ "$out" == *admin* ]]; then
    pass "first request after server restart succeeded (no dead socket handed out)"
else
    fail "first request after server restart failed: $out"
fi

# ----------------------------------------------------------------------
phase "4: no wedged teardown left behind"
# ----------------------------------------------------------------------
# The deadlock signature: a server child and its forwarding helper both
# alive with no established connection, parked in waitpid()/poll().
# Healthy is exactly three sigul processes (parent, child, helper) and
# one established connection.
procs="$(docker exec "$SERVER_CONTAINER" sh -c "pgrep -fc 'serve[r]\.py'" | tr -d '[:space:]')"
est="$(server_established)"
note "server processes=${procs} established=${est}"
if [[ "$procs" == "3" && "$est" == "1" ]]; then
    pass "server process tree is healthy (3 procs, 1 established)"
else
    fail "server looks wedged or over-forked (procs=${procs}, established=${est})"
fi

# ----------------------------------------------------------------------
echo
echo "Lifecycle tests: ${PASSED} passed, ${FAILED} failed"
(( FAILED == 0 ))
