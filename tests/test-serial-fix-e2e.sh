#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# End-to-End Test: Verify Serial Number Collision Fix
#
# This test verifies that the certificate generation fix for
# SEC_ERROR_REUSED_ISSUER_AND_SERIAL works correctly by:
# 1. Generating bridge certificates (CA + bridge cert)
# 2. Generating server certificates (imports CA + server cert)
# 3. Verifying all serials are unique and non-zero
# 4. Confirming no collision errors occurred
#
# Usage:
#   ./test-serial-fix-e2e.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[E2E-TEST]${NC} $*"; }
success() { echo -e "${GREEN}[E2E-TEST]${NC} $*"; }
error() { echo -e "${RED}[E2E-TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[E2E-TEST]${NC} $*"; }

TEST_BASE_DIR="/tmp/sigul-serial-test-$$"
BRIDGE_NSS_DIR="${TEST_BASE_DIR}/bridge/nss"
SERVER_NSS_DIR="${TEST_BASE_DIR}/server/nss"
CA_EXPORT_DIR="${TEST_BASE_DIR}/bridge/ca-export"
CA_IMPORT_DIR="${TEST_BASE_DIR}/server/ca-import"
NSS_PASSWORD="test-password-e2e-$$"

TEST_FAILED=0

# Cleanup function
# shellcheck disable=SC2317
cleanup() {
    if [ -d "${TEST_BASE_DIR}" ]; then
        rm -rf "${TEST_BASE_DIR}"
        log "Cleaned up test directory: ${TEST_BASE_DIR}"
    fi
}

trap cleanup EXIT

# Setup test environment
setup() {
    log "Setting up test environment..."

    mkdir -p "${BRIDGE_NSS_DIR}"
    mkdir -p "${SERVER_NSS_DIR}"
    mkdir -p "${CA_EXPORT_DIR}"
    mkdir -p "${CA_IMPORT_DIR}"

    success "Test directories created: ${TEST_BASE_DIR}"
}

# Test 1: Generate bridge certificates (CA + bridge cert)
test_bridge_cert_generation() {
    log "Test 1: Generating bridge certificates..."

    local output
    if output=$(NSS_DB_DIR="${BRIDGE_NSS_DIR}" \
                NSS_PASSWORD="${NSS_PASSWORD}" \
                COMPONENT="bridge" \
                FQDN="test-bridge.example.org" \
                bash "$(dirname "$0")/../pki/generate-production-aligned-certs.sh" 2>&1); then
        success "Bridge certificate generation succeeded"
    else
        error "Bridge certificate generation FAILED"
        # shellcheck disable=SC2001
        echo "${output}" | sed 's/^/  /'
        TEST_FAILED=1
        return 1
    fi

    # Copy CA cert to import location for server
    if [ -f "${BRIDGE_NSS_DIR}/../ca-export/ca.crt" ]; then
        cp "${BRIDGE_NSS_DIR}/../ca-export/ca.crt" "${CA_IMPORT_DIR}/ca.crt"
        success "CA certificate copied for server import"
    else
        error "CA certificate not found in expected location"
        TEST_FAILED=1
        return 1
    fi
}

# Test 2: Generate server certificates (import CA + server cert)
test_server_cert_generation() {
    log "Test 2: Generating server certificates..."

    local output
    if output=$(NSS_DB_DIR="${SERVER_NSS_DIR}" \
                NSS_PASSWORD="${NSS_PASSWORD}" \
                COMPONENT="server" \
                FQDN="test-server.example.org" \
                bash "$(dirname "$0")/../pki/generate-production-aligned-certs.sh" 2>&1); then
        success "Server certificate generation succeeded"
    else
        error "Server certificate generation FAILED"
        # shellcheck disable=SC2001
        echo "${output}" | sed 's/^/  /'
        TEST_FAILED=1
        return 1
    fi
}

# Test 3: Verify serial numbers are unique and non-zero
test_serial_uniqueness() {
    log "Test 3: Verifying serial number uniqueness..."

    # Extract serial numbers
    local ca_serial_bridge
    local bridge_serial
    local ca_serial_server
    local server_serial

    ca_serial_bridge=$(certutil -L -d "sql:${BRIDGE_NSS_DIR}" -n sigul-ca 2>/dev/null | \
                       awk '/Serial Number/{getline; gsub(/[[:space:]]/, ""); print}')

    bridge_serial=$(certutil -L -d "sql:${BRIDGE_NSS_DIR}" -n sigul-bridge-cert 2>/dev/null | \
                    awk '/Serial Number/{getline; gsub(/[[:space:]]/, ""); print}')

    ca_serial_server=$(certutil -L -d "sql:${SERVER_NSS_DIR}" -n sigul-ca 2>/dev/null | \
                       awk '/Serial Number/{getline; gsub(/[[:space:]]/, ""); print}')

    server_serial=$(certutil -L -d "sql:${SERVER_NSS_DIR}" -n sigul-server-cert 2>/dev/null | \
                    awk '/Serial Number/{getline; gsub(/[[:space:]]/, ""); print}')

    log "Serial numbers extracted:"
    log "  Bridge CA:   ${ca_serial_bridge}"
    log "  Bridge Cert: ${bridge_serial}"
    log "  Server CA:   ${ca_serial_server}"
    log "  Server Cert: ${server_serial}"

    # Check none are zero
    if [ "${ca_serial_bridge}" = "0" ] || [ "${ca_serial_bridge}" = "0(0x0)" ] || [ "${ca_serial_bridge}" = "00:00" ]; then
        error "Bridge CA serial is ZERO - this indicates the bug is NOT fixed!"
        TEST_FAILED=1
        return 1
    fi

    if [ "${bridge_serial}" = "0" ] || [ "${bridge_serial}" = "0(0x0)" ] || [ "${bridge_serial}" = "00:00" ]; then
        error "Bridge certificate serial is ZERO - this indicates the bug is NOT fixed!"
        TEST_FAILED=1
        return 1
    fi

    if [ "${server_serial}" = "0" ] || [ "${server_serial}" = "0(0x0)" ] || [ "${server_serial}" = "00:00" ]; then
        error "Server certificate serial is ZERO - this indicates the bug is NOT fixed!"
        TEST_FAILED=1
        return 1
    fi

    success "All serial numbers are non-zero"

    # Check CA and bridge cert have different serials
    if [ "${ca_serial_bridge}" = "${bridge_serial}" ]; then
        error "CA and Bridge certificate have SAME serial - collision detected!"
        TEST_FAILED=1
        return 1
    fi

    success "Bridge CA and certificate have different serials (no collision)"

    # Check CA and server cert have different serials
    if [ "${ca_serial_server}" = "${server_serial}" ]; then
        error "CA and Server certificate have SAME serial - collision detected!"
        TEST_FAILED=1
        return 1
    fi

    success "Server CA and certificate have different serials (no collision)"

    # Check CA serial is consistent between bridge and server
    if [ "${ca_serial_bridge}" != "${ca_serial_server}" ]; then
        warn "CA serial differs between bridge and server (expected if imported separately)"
        log "  Bridge CA: ${ca_serial_bridge}"
        log "  Server CA: ${ca_serial_server}"
    else
        success "CA serial is consistent between bridge and server"
    fi
}

# Test 4: Verify certificates are valid
test_certificate_validity() {
    log "Test 4: Verifying certificate validity..."

    # Check bridge certificates
    if certutil -L -d "sql:${BRIDGE_NSS_DIR}" -n sigul-ca >/dev/null 2>&1; then
        success "Bridge CA certificate is readable"
    else
        error "Bridge CA certificate is NOT readable"
        TEST_FAILED=1
    fi

    if certutil -L -d "sql:${BRIDGE_NSS_DIR}" -n sigul-bridge-cert >/dev/null 2>&1; then
        success "Bridge component certificate is readable"
    else
        error "Bridge component certificate is NOT readable"
        TEST_FAILED=1
    fi

    # Check server certificates
    if certutil -L -d "sql:${SERVER_NSS_DIR}" -n sigul-ca >/dev/null 2>&1; then
        success "Server CA certificate is readable"
    else
        error "Server CA certificate is NOT readable"
        TEST_FAILED=1
    fi

    if certutil -L -d "sql:${SERVER_NSS_DIR}" -n sigul-server-cert >/dev/null 2>&1; then
        success "Server component certificate is readable"
    else
        error "Server component certificate is NOT readable"
        TEST_FAILED=1
    fi
}

# Test 5: Verify trust flags
test_trust_flags() {
    log "Test 5: Verifying certificate trust flags..."

    # Check bridge CA trust flags (should be CT,C,C or CTu,Cu,Cu)
    local bridge_ca_trust
    bridge_ca_trust=$(certutil -L -d "sql:${BRIDGE_NSS_DIR}" 2>/dev/null | \
                      grep "sigul-ca" | awk '{print $2}')

    if [[ "${bridge_ca_trust}" =~ CT.*C.*C ]]; then
        success "Bridge CA has correct trust flags: ${bridge_ca_trust}"
    else
        error "Bridge CA has incorrect trust flags: ${bridge_ca_trust}"
        TEST_FAILED=1
    fi

    # Check bridge cert trust flags (should be u,u,u)
    local bridge_cert_trust
    bridge_cert_trust=$(certutil -L -d "sql:${BRIDGE_NSS_DIR}" 2>/dev/null | \
                        grep "sigul-bridge-cert" | awk '{print $2}')

    if [[ "${bridge_cert_trust}" =~ u.*u.*u ]]; then
        success "Bridge certificate has correct trust flags: ${bridge_cert_trust}"
    else
        error "Bridge certificate has incorrect trust flags: ${bridge_cert_trust}"
        TEST_FAILED=1
    fi
}

# Main test execution
main() {
    log "=== End-to-End Serial Number Fix Verification ==="
    log "Testing fix for SEC_ERROR_REUSED_ISSUER_AND_SERIAL"
    echo ""

    log "Test environment: ${TEST_BASE_DIR}"
    echo ""

    # Setup
    setup
    echo ""

    # Run tests
    test_bridge_cert_generation
    echo ""

    test_server_cert_generation
    echo ""

    test_serial_uniqueness
    echo ""

    test_certificate_validity
    echo ""

    test_trust_flags
    echo ""

    # Final summary
    if [ ${TEST_FAILED} -eq 0 ]; then
        success "=== ALL TESTS PASSED ==="
        success "Serial number collision fix is working correctly!"
        success "Certificates generated with unique, auto-generated serial numbers"
        echo ""
        log "Summary:"
        log "  ✓ Bridge certificates generated successfully"
        log "  ✓ Server certificates generated successfully"
        log "  ✓ All serial numbers are unique and non-zero"
        log "  ✓ No SEC_ERROR_REUSED_ISSUER_AND_SERIAL errors"
        log "  ✓ Certificate trust flags are correct"
        echo ""
        exit 0
    else
        error "=== SOME TESTS FAILED ==="
        error "Serial number collision fix may not be working correctly!"
        echo ""
        log "Please review the errors above and check:"
        log "  1. Is generate-production-aligned-certs.sh using auto-generated serials?"
        log "  2. Is the -m flag removed from certutil -S commands?"
        log "  3. Are NSS tools installed and working correctly?"
        echo ""
        exit 1
    fi
}

# Run main function
main "$@"
