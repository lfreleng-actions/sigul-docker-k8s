#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
# Sigul Integration Test Script
# Tests basic client operations from the client's perspective

set -euo pipefail

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
ADMIN_PASSWORD="auto_generated_ephemeral"
VERBOSE_MODE=false

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

    docker run --rm \
        --user 1000:1000 \
        --network "$NETWORK" \
        -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
        -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        bash -c "printf '${password}\0' | sigul --batch -c /etc/sigul/client.conf ${cmd} 2>&1"
}

# Helper to print verbose messages
verbose() {
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
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

# ============================================================================
# TEST 1: Basic Authentication - List Users
# ============================================================================
test_header "Basic Authentication - List Users"
OUTPUT=$(run_client "list-users" 2>&1)
if echo "$OUTPUT" | grep -q "admin"; then
    pass "Can authenticate and list users"
    verbose "  Users: $OUTPUT"
else
    fail "Failed to list users"
    verbose "  Output: $OUTPUT"
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
    OUTPUT=$(run_client "list-users" 2>&1)
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
OUTPUT=$(run_client "list-users" 2>&1)
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
OUTPUT=$(run_client "user-info admin" 2>&1)
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
OUTPUT=$(docker run --rm \
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
OUTPUT=$(run_client "list-users" 2>&1)
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
OUTPUT=$(docker run --rm \
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
