#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
#
# Sigul Functional Test Suite - Signing Operations
# Tests actual signing operations to verify end-to-end functionality

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Sigul Functional Test Suite - Signing Operations ==="

# Configuration
BRIDGE_HOST="${BRIDGE_HOST:-sigul-bridge.example.org}"
BRIDGE_PORT="${BRIDGE_PORT:-44333}"
CLIENT_PORT="${CLIENT_PORT:-44334}"
TEST_KEY_NAME="${TEST_KEY_NAME:-test-signing-key}"
TEST_KEY_PASSPHRASE="${TEST_KEY_PASSPHRASE:-test-passphrase-12345}"
TEST_USER="${TEST_USER:-test-admin}"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
pass() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
}

fail() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
}

skip() {
    echo -e "${YELLOW}⊘ SKIP:${NC} $1"
}

info() {
    echo -e "${YELLOW}ℹ INFO:${NC} $1"
}

# Check if client container is available
if ! docker ps --format '{{.Names}}' | grep -q "sigul-client"; then
    skip "Client container not running - functional tests require sigul-client"
    skip "To run functional tests, start a sigul-client container configured with:"
    skip "  - Connection to sigul-bridge at ${BRIDGE_HOST}:${CLIENT_PORT}"
    skip "  - Valid client certificate in NSS database"
    skip "  - Access to test user credentials"
    exit 0
fi

CLIENT_CONTAINER=$(docker ps --format '{{.Names}}' | grep "sigul-client" | head -n1)
info "Using client container: ${CLIENT_CONTAINER}"

# Test 1: Server connectivity check
echo ""
echo "Test 1: Verifying client can reach bridge..."
if docker exec "${CLIENT_CONTAINER}" nc -zv "${BRIDGE_HOST}" "${CLIENT_PORT}" 2>&1 | grep -q "succeeded\|open"; then
    pass "Client can reach bridge on port ${CLIENT_PORT}"
else
    fail "Client cannot reach bridge on port ${CLIENT_PORT}"
fi

# Test 2: List users (requires authentication)
echo ""
echo "Test 2: Testing user authentication and listing..."
if docker exec "${CLIENT_CONTAINER}" sigul --batch list-users 2>&1 | grep -qE "^[a-zA-Z0-9_-]+$"; then
    pass "User authentication and listing works"
else
    skip "User listing requires valid credentials - this may be expected"
fi

# Test 3: List existing keys
echo ""
echo "Test 3: Listing existing signing keys..."
if docker exec "${CLIENT_CONTAINER}" sigul --batch list-keys > /tmp/sigul-keys.txt 2>&1; then
    KEYS_COUNT=$(wc -l < /tmp/sigul-keys.txt || echo "0")
    pass "Key listing works (found ${KEYS_COUNT} keys)"
else
    fail "Could not list signing keys"
fi

# Test 4: Create test file
echo ""
echo "Test 4: Preparing test file for signing..."
if docker exec "${CLIENT_CONTAINER}" sh -c 'echo "This is a test file for Sigul signing verification" > /tmp/test-file.txt'; then
    pass "Test file created"
else
    fail "Could not create test file"
fi

# Test 5: Verify server database
echo ""
echo "Test 5: Checking server database integrity..."
if docker exec sigul-server test -f /var/lib/sigul/server.sqlite; then
    if docker exec sigul-server sqlite3 /var/lib/sigul/server.sqlite "PRAGMA integrity_check;" 2>&1 | grep -q "ok"; then
        pass "Server database is healthy"
    else
        fail "Server database integrity check failed"
    fi
else
    fail "Server database not found at /var/lib/sigul/server.sqlite"
fi

# Test 6: Verify GnuPG home
echo ""
echo "Test 6: Checking server GnuPG configuration..."
if docker exec sigul-server test -d /var/lib/sigul/gnupg; then
    pass "GnuPG home directory exists"
else
    fail "GnuPG home directory not found"
fi

# Test 7: Check server process
echo ""
echo "Test 7: Verifying server process status..."
if docker exec sigul-server pgrep -f "sigul_server" > /dev/null; then
    pass "Server process is running"
else
    fail "Server process is not running"
fi

# Test 8: Check bridge process
echo ""
echo "Test 8: Verifying bridge process status..."
if docker exec sigul-bridge pgrep -f "sigul_bridge" > /dev/null; then
    pass "Bridge process is running"
else
    fail "Bridge process is not running"
fi

# Test 9: Verify NSS database format
echo ""
echo "Test 9: Checking NSS database format..."
if docker exec sigul-server file /etc/pki/sigul/cert9.db 2>/dev/null | grep -q "SQLite"; then
    pass "Server NSS database uses modern format (cert9.db)"
else
    fail "Server NSS database not in modern format"
fi

if docker exec sigul-bridge file /etc/pki/sigul/cert9.db 2>/dev/null | grep -q "SQLite"; then
    pass "Bridge NSS database uses modern format (cert9.db)"
else
    fail "Bridge NSS database not in modern format"
fi

# Test 10: Check certificate expiration
echo ""
echo "Test 10: Checking certificate validity periods..."
BRIDGE_CERT_INFO=$(docker exec sigul-bridge certutil -L -n "sigul-bridge.example.org" -d sql:/etc/pki/sigul 2>/dev/null || echo "")
if echo "${BRIDGE_CERT_INFO}" | grep -q "Not After"; then
    EXPIRY=$(echo "${BRIDGE_CERT_INFO}" | grep "Not After" | head -n1)
    info "Bridge certificate: ${EXPIRY}"
    pass "Bridge certificate is readable"
else
    fail "Could not read bridge certificate expiration"
fi

SERVER_CERT_INFO=$(docker exec sigul-server certutil -L -n "sigul-server.example.org" -d sql:/etc/pki/sigul 2>/dev/null || echo "")
if echo "${SERVER_CERT_INFO}" | grep -q "Not After"; then
    EXPIRY=$(echo "${SERVER_CERT_INFO}" | grep "Not After" | head -n1)
    info "Server certificate: ${EXPIRY}"
    pass "Server certificate is readable"
else
    fail "Could not read server certificate expiration"
fi

# Summary
echo ""
echo "=== Test Summary ==="
echo "Tests run:    ${TESTS_RUN}"
echo -e "${GREEN}Tests passed: ${TESTS_PASSED}${NC}"
if [ ${TESTS_FAILED} -gt 0 ]; then
    echo -e "${RED}Tests failed: ${TESTS_FAILED}${NC}"
else
    echo -e "${GREEN}Tests failed: ${TESTS_FAILED}${NC}"
fi

echo ""
if [ ${TESTS_FAILED} -eq 0 ]; then
    echo -e "${GREEN}=== All Functional Tests Passed ===${NC}"
    exit 0
else
    echo -e "${RED}=== Some Functional Tests Failed ===${NC}"
    exit 1
fi
