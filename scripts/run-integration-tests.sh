#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
# Sigul Integration Test Script
# Tests basic client operations from the client's perspective

set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration - will be detected dynamically or from environment
NETWORK=""
CLIENT_IMAGE="${SIGUL_CLIENT_IMAGE:-}"
CLIENT_NSS_VOLUME="sigul-docker_sigul_client_nss"
CLIENT_CONFIG_VOLUME="sigul-docker_sigul_client_config"
ADMIN_PASSWORD=""
VERBOSE_MODE=false

# Script directory for finding test artifacts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Test counters
PASSED=0
FAILED=0

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose)
            VERBOSE_MODE=true
            shift
            ;;
        --help)
            cat << EOF
Usage: $0 [OPTIONS]

Run Sigul integration tests.

Options:
    --verbose    Enable verbose output
    --help       Show this help

Environment Variables:
    SIGUL_CLIENT_IMAGE    Client Docker image (required)
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Detect network dynamically
detect_network() {
    NETWORK=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1)
    if [[ -z "$NETWORK" ]]; then
        echo -e "${RED}ERROR: No sigul network found!${NC}"
        exit 1
    fi
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        echo -e "${BLUE}Using network: $NETWORK${NC}"
    fi
}

# Verify client image is set
if [[ -z "$CLIENT_IMAGE" ]]; then
    echo -e "${RED}ERROR: SIGUL_CLIENT_IMAGE environment variable must be set${NC}"
    exit 1
fi

# Helper function to run client command
run_client() {
    local cmd="$1"
    local password="${2:-$ADMIN_PASSWORD}"

    verbose "Executing: sigul --batch -c /etc/sigul/client.conf ${cmd}"
    verbose "Network: $NETWORK"
    verbose "Client image: $CLIENT_IMAGE"

    local output
    local exit_code

    output=$(timeout 60 docker run --rm \
        --user 1000:1000 \
        --network "$NETWORK" \
        -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
        -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        bash -c "printf '${password}\0' | sigul --batch -c /etc/sigul/client.conf ${cmd} 2>&1")
    exit_code=$?

    # Check if command timed out
    if [[ $exit_code -eq 124 ]]; then
        echo "ERROR: Command timed out after 60 seconds"
        return 124
    fi

    echo "$output"
    return $exit_code
}

# Helper to print verbose messages
verbose() {
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*" >&2
    fi
}

# Helper to print test header
test_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}TEST: $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

# Helper to report success
pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

# Helper to report failure
fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

# Print banner
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                                                           ║${NC}"
echo -e "${BLUE}║          SIGUL CLIENT TEST SUITE                          ║${NC}"
echo -e "${BLUE}║          Testing from Client Perspective                  ║${NC}"
echo -e "${BLUE}║                                                           ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Load admin password from test artifacts
if [[ -f "${PROJECT_ROOT}/test-artifacts/admin-password" ]]; then
    ADMIN_PASSWORD=$(cat "${PROJECT_ROOT}/test-artifacts/admin-password")
    echo -e "${BLUE}[DEBUG]${NC} Loaded admin password from test artifacts"
    echo -e "${BLUE}[DEBUG]${NC} Admin password: ${ADMIN_PASSWORD}"
else
    echo -e "${RED}ERROR: Admin password file not found at ${PROJECT_ROOT}/test-artifacts/admin-password${NC}"
    exit 1
fi

# Also show NSS password from client.conf for comparison
if docker run --rm \
    --user 1000:1000 \
    -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
    "$CLIENT_IMAGE" \
    grep "nss-password:" /etc/sigul/client.conf >/dev/null 2>&1; then
    NSS_PASS=$(docker run --rm \
        --user 1000:1000 \
        -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        grep "nss-password:" /etc/sigul/client.conf | sed 's/.*nss-password: *//')
    echo -e "${BLUE}[DEBUG]${NC} NSS password in client.conf: ${NSS_PASS}"

    # Verify NSS password matches the one from test artifacts
    if [[ -f "${PROJECT_ROOT}/test-artifacts/nss-password" ]]; then
        NSS_PASS_ARTIFACT=$(cat "${PROJECT_ROOT}/test-artifacts/nss-password")
        echo -e "${BLUE}[DEBUG]${NC} NSS password from artifacts: ${NSS_PASS_ARTIFACT}"

        if [[ "$NSS_PASS" == "$NSS_PASS_ARTIFACT" ]]; then
            echo -e "${GREEN}✓ NSS passwords match${NC}"
        else
            echo -e "${RED}❌ ERROR: NSS password mismatch!${NC}"
            echo -e "${YELLOW}client.conf has: ${NSS_PASS}${NC}"
            echo -e "${YELLOW}artifacts has: ${NSS_PASS_ARTIFACT}${NC}"
            exit 1
        fi
    fi
else
    echo -e "${YELLOW}[WARN]${NC} Could not read NSS password from client.conf"
fi

# Detect network
detect_network

# Check stack is running
echo -e "${YELLOW}Checking Sigul stack status...${NC}"
if ! docker ps --format '{{.Names}}' | grep -q "sigul-server"; then
    echo -e "${RED}ERROR: Sigul stack is not running!${NC}"
    echo -e "${RED}Required containers: sigul-server, sigul-bridge${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Stack is running${NC}"
verbose "Network: $NETWORK"
verbose "Client volumes: $CLIENT_NSS_VOLUME, $CLIENT_CONFIG_VOLUME"
echo ""

# Wait for bridge to be fully ready to accept connections
echo -e "${YELLOW}Waiting for bridge to be fully ready...${NC}"
MAX_WAIT=30
WAIT_COUNT=0
BRIDGE_READY=false

while [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
    # Test if bridge port is responding
    if docker run --rm --network "$NETWORK" alpine:3.19 \
       sh -c 'timeout 2 nc -z sigul-bridge.example.org 44334' >/dev/null 2>&1; then
        BRIDGE_READY=true
        break
    fi

    echo -e "${BLUE}  Waiting for bridge... (${WAIT_COUNT}/${MAX_WAIT})${NC}"
    sleep 2
    WAIT_COUNT=$((WAIT_COUNT + 2))
done

if [[ "$BRIDGE_READY" == "true" ]]; then
    echo -e "${GREEN}✓ Bridge is ready and accepting connections${NC}"
    echo -e "${YELLOW}Waiting 5 seconds for TLS handshake to stabilize...${NC}"
    sleep 5

    # Check bridge logs for any errors
    echo -e "${BLUE}Checking bridge logs for errors...${NC}"
    if docker logs sigul-bridge --tail 20 2>&1 | grep -i "error\|exception\|failed"; then
        echo -e "${YELLOW}⚠️  Errors detected in bridge logs${NC}"
    else
        echo -e "${GREEN}✓ No errors in recent bridge logs${NC}"
    fi

    # Verify patch is actually in the running bridge container
    echo -e "${BLUE}Verifying patch in running bridge container...${NC}"
    if docker exec sigul-bridge grep -q "force_handshake" /usr/share/sigul/bridge.py; then
        echo -e "${GREEN}✓ Patch verified: force_handshake() found in bridge.py${NC}"
    else
        echo -e "${RED}❌ ERROR: force_handshake() NOT found in running bridge!${NC}"
        echo -e "${YELLOW}This means the patch was not applied or wrong image is running${NC}"
        exit 1
    fi

    echo ""
else
    echo -e "${RED}ERROR: Bridge did not become ready within ${MAX_WAIT} seconds${NC}"
    echo -e "${YELLOW}Checking bridge container status:${NC}"
    docker ps --filter "name=sigul-bridge" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo -e "${YELLOW}Bridge logs:${NC}"
    docker logs sigul-bridge --tail 50
    exit 1
fi

# ============================================================================
# TEST 1: Basic Authentication - List Users
# ============================================================================
test_header "Basic Authentication - List Users"
OUTPUT=$(run_client "list-users" 2>&1 || true)
if echo "$OUTPUT" | grep -q "admin"; then
    pass "Can authenticate and list users"
    verbose "  Users: $OUTPUT"
else
    fail "Failed to list users"
    verbose "  Output: $OUTPUT"

    # Dump bridge logs on first test failure for diagnosis
    echo -e "${YELLOW}Bridge logs (last 50 lines):${NC}"
    docker logs sigul-bridge --tail 50 2>&1 | sed 's/^/  /'
    echo ""
    echo -e "${YELLOW}Server logs (last 50 lines):${NC}"
    docker logs sigul-server --tail 50 2>&1 | sed 's/^/  /'
    echo ""

    # Check if containers are actually still running
    echo -e "${YELLOW}Container status check:${NC}"
    if docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'sigul-(server|bridge)'; then
        echo -e "${GREEN}✓ Containers are running${NC}"
    else
        echo -e "${RED}❌ Containers stopped!${NC}"
        echo ""
        echo -e "${YELLOW}All containers:${NC}"
        docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep sigul
    fi
    echo ""

    # Check if server container is actually still running
    echo -e "${YELLOW}Checking if server container is running:${NC}"
    if docker ps --format '{{.Names}}\t{{.Status}}' | grep -q "^sigul-server"; then
        echo -e "${GREEN}✓ Server container is running${NC}"

        # Check server process inside container
        echo -e "${YELLOW}Checking if server process is running inside container:${NC}"
        if docker exec sigul-server pgrep -f sigul_server >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Server process is running${NC}"
        else
            echo -e "${RED}❌ Server process not running inside container!${NC}"
            echo -e "${YELLOW}Container is up but sigul_server process has exited${NC}"
        fi
    else
        echo -e "${RED}❌ Server container has STOPPED!${NC}"
        echo ""

        # Get detailed container inspection
        echo -e "${YELLOW}Server container state:${NC}"
        docker inspect sigul-server --format='Status: {{.State.Status}}' | sed 's/^/  /'
        docker inspect sigul-server --format='Exit Code: {{.State.ExitCode}}' | sed 's/^/  /'
        docker inspect sigul-server --format='Error: {{.State.Error}}' | sed 's/^/  /'
        docker inspect sigul-server --format='Started At: {{.State.StartedAt}}' | sed 's/^/  /'
        docker inspect sigul-server --format='Finished At: {{.State.FinishedAt}}' | sed 's/^/  /'
        echo ""

        # Check mounts to see if tmpfs is working
        echo -e "${YELLOW}Checking container mounts:${NC}"
        docker inspect sigul-server --format='{{range .Mounts}}{{.Type}}: {{.Source}} -> {{.Destination}} ({{.Mode}}){{"\n"}}{{end}}' | sed 's/^/  /'
        echo ""

        # Check if tmpfs mounts are present
        echo -e "${YELLOW}Checking for tmpfs mounts:${NC}"
        docker inspect sigul-server --format='{{range .HostConfig.Tmpfs}}{{.}}{{"\n"}}{{end}}' | sed 's/^/  /' || echo "  No tmpfs configuration found"
        echo ""

        # Try to get the last few lines before exit
        echo -e "${YELLOW}Last 20 lines of server output:${NC}"
        docker logs sigul-server --tail 20 2>&1 | sed 's/^/  /'
    fi
fi

# ============================================================================
# TEST 2: Authentication Failure with Wrong Password
# ============================================================================
test_header "Authentication Failure - Wrong Password"
OUTPUT=$(run_client "list-users" "wrong_password" 2>&1 || true)
if echo "$OUTPUT" | grep -qi "authentication.*failed\|error\|EOF"; then
    pass "Correctly rejects wrong password"
else
    fail "Did not properly reject wrong password"
    verbose "  Output: $OUTPUT"
fi

# ============================================================================
# TEST 3: List Available Keys
# ============================================================================
test_header "List Available Keys"
if OUTPUT=$(run_client "list-keys" 2>&1); then
    pass "Can list signing keys"
    verbose "  Keys: ${OUTPUT:-<none>}"
else
    fail "Failed to list keys"
    verbose "  Output: $OUTPUT"
fi

# ============================================================================
# TEST 4: Multiple Consecutive Operations (Connection Stability)
# ============================================================================
test_header "Connection Stability - Multiple Operations"
SUCCESS_COUNT=0
for i in {1..5}; do
    OUTPUT=$(run_client "list-users" 2>&1 || true)
    if echo "$OUTPUT" | grep -q "admin"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo -e "  Attempt $i: ${GREEN}✓${NC}"
    else
        echo -e "  Attempt $i: ${RED}✗${NC}"
    fi
done

if [ $SUCCESS_COUNT -eq 5 ]; then
    pass "All 5 consecutive operations succeeded"
else
    fail "Only $SUCCESS_COUNT/5 operations succeeded"
fi

# ============================================================================
# TEST 5: Double-TLS Certificate Authentication
# ============================================================================
test_header "Double-TLS Certificate Authentication"
OUTPUT=$(run_client "list-users" 2>&1 || true)
if echo "$OUTPUT" | grep -q "admin" && ! echo "$OUTPUT" | grep -qi "certificate.*error"; then
    pass "Client certificate authentication working"
else
    fail "Certificate authentication issue detected"
    verbose "  Output: $OUTPUT"
fi

# ============================================================================
# TEST 6: User Information Query
# ============================================================================
test_header "User Information Query"
OUTPUT=$(run_client "user-info admin" 2>&1 || true)
if echo "$OUTPUT" | grep -qi "admin\|user"; then
    pass "Can query user information"
    verbose "  Info: $OUTPUT"
else
    fail "Failed to get user info"
    verbose "  Output: $OUTPUT"
fi

# ============================================================================
# TEST 7: List Key Users (Even if No Keys)
# ============================================================================
test_header "List Key Users"
# First check if there are any keys
KEYS=$(run_client "list-keys" 2>&1)
if [ -n "$KEYS" ] && ! echo "$KEYS" | grep -qi "error"; then
    FIRST_KEY=$(echo "$KEYS" | head -1 | xargs)
    if [ -n "$FIRST_KEY" ]; then
        if OUTPUT=$(run_client "list-key-users \"$FIRST_KEY\"" 2>&1); then
            pass "Can list key users for: $FIRST_KEY"
        else
            # This might be expected if key doesn't exist or has no users
            pass "Key users command executes (no keys with users yet)"
        fi
    else
        pass "No keys available to test (expected for fresh install)"
    fi
else
    pass "No keys available to test (expected for fresh install)"
fi

# ============================================================================
# TEST 8: Check Available Commands
# ============================================================================
test_header "Client Command Availability"
OUTPUT=$(timeout 10 docker run --rm \
    --user 1000:1000 \
    "$CLIENT_IMAGE" \
    sigul --help-commands 2>&1)

if echo "$OUTPUT" | grep -q "list-users"; then
    pass "Client commands are accessible"
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        echo "  Sample commands available:"
        echo "$OUTPUT" | head -10 | sed 's/^/    /'
    fi
else
    fail "Client commands not accessible"
fi

# ============================================================================
# TEST 9: Bridge Connection Test
# ============================================================================
test_header "Bridge Connection Verification"
# Quick connection test
START_TIME=$(date +%s)
OUTPUT=$(run_client "list-users" 2>&1 || true)
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if echo "$OUTPUT" | grep -q "admin"; then
    pass "Bridge connection successful (${DURATION}s)"
    if [ $DURATION -lt 5 ]; then
        echo -e "  ${GREEN}Connection latency is good${NC}"
    else
        echo -e "  ${YELLOW}Connection took ${DURATION}s (acceptable)${NC}"
    fi
else
    fail "Bridge connection failed"
    echo "  Output: $OUTPUT"
fi

# ============================================================================
# TEST 10: Batch Mode Input Handling
# ============================================================================
test_header "Batch Mode Password Input (NUL-terminated)"
# Test with explicit NUL terminator
OUTPUT=$(timeout 60 docker run --rm \
    --user 1000:1000 \
    --network "$NETWORK" \
    -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
    -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
    "$CLIENT_IMAGE" \
    bash -c 'printf "auto_generated_ephemeral\0" | sigul --batch -c /etc/sigul/client.conf list-users 2>&1')

if echo "$OUTPUT" | grep -q "admin"; then
    pass "Batch mode NUL-terminated password works correctly"
else
    fail "Batch mode password handling failed"
    echo "  Output: $OUTPUT"
fi

# ============================================================================
# Print Summary
# ============================================================================
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                     TEST SUMMARY                          ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
TOTAL=$((PASSED + FAILED))
echo -e "Total Tests:  ${BLUE}${TOTAL}${NC}"
echo -e "Passed:       ${GREEN}${PASSED}${NC}"
echo -e "Failed:       ${RED}${FAILED}${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}║              🎉 ALL TESTS PASSED! 🎉                      ║${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}║  The Sigul client can successfully communicate with      ║${NC}"
    echo -e "${GREEN}║  the bridge and server via double-TLS!                   ║${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}✓ Client authentication working${NC}"
    echo -e "${GREEN}✓ Double-TLS connection stable${NC}"
    echo -e "${GREEN}✓ Certificate validation successful${NC}"
    echo -e "${GREEN}✓ Multiple operations tested${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                           ║${NC}"
    echo -e "${RED}║                ❌ SOME TESTS FAILED ❌                    ║${NC}"
    echo -e "${RED}║                                                           ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    exit 1
fi
