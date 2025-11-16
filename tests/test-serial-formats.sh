#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Test Script: Verify certutil serial number format compatibility
#
# This script tests different serial number formats with certutil to determine
# which format works correctly and doesn't cause SEC_ERROR_REUSED_ISSUER_AND_SERIAL
#
# Tests:
# 1. Hex format with 0x prefix (current implementation)
# 2. Hex format without 0x prefix
# 3. Decimal format
# 4. Different serial lengths (4, 8, 16 bytes)
# 5. Timestamp-based serials
#
# Usage:
#   docker-compose run --rm sigul-bridge /workspace/tests/test-serial-formats.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[TEST]${NC} $*"; }
success() { echo -e "${GREEN}[TEST]${NC} $*"; }
error() { echo -e "${RED}[TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[TEST]${NC} $*"; }

TEST_DIR="/tmp/nss-serial-test-$$"
NSS_PASSWORD="test-password-$$"
NOISE_FILE="${TEST_DIR}/.noise"
PASSWORD_FILE="${TEST_DIR}/.password"

# Cleanup function
cleanup() {
    if [ -d "${TEST_DIR}" ]; then
        rm -rf "${TEST_DIR}"
        log "Cleaned up test directory"
    fi
}

trap cleanup EXIT

# Setup test environment
setup() {
    log "Setting up test environment..."
    mkdir -p "${TEST_DIR}"
    
    # Create password file
    echo "${NSS_PASSWORD}" > "${PASSWORD_FILE}"
    chmod 600 "${PASSWORD_FILE}"
    
    # Create noise file
    head -c 1024 /dev/urandom > "${NOISE_FILE}" 2>/dev/null
    chmod 600 "${NOISE_FILE}"
    
    # Initialize NSS database
    if ! certutil -N -d "sql:${TEST_DIR}" -f "${PASSWORD_FILE}" >/dev/null 2>&1; then
        error "Failed to initialize NSS database"
        exit 1
    fi
    
    success "Test environment ready: ${TEST_DIR}"
}

# Test function for auto-generated serials (no -m flag)
test_ca_auto_serial() {
    local ca_name="test-ca-auto"
    
    log "Testing CA certificate with AUTO-GENERATED serial (no -m flag)"
    
    # Try to create CA certificate WITHOUT -m flag
    local output
    if output=$(certutil -S \
        -n "${ca_name}" \
        -s "CN=Test CA Auto" \
        -x \
        -t "CT,C,C" \
        -k rsa \
        -g 2048 \
        -z "${NOISE_FILE}" \
        -Z SHA256 \
        -v 12 \
        -d "sql:${TEST_DIR}" \
        -f "${PASSWORD_FILE}" \
        --keyUsage certSigning,crlSigning \
        2>&1); then
        success "  ✓ CA creation succeeded (auto serial)"
        
        # Show the serial number that was auto-assigned
        log "  Inspecting certificate details..."
        certutil -L -n "${ca_name}" -d "sql:${TEST_DIR}" 2>&1 | grep -A 2 "Serial Number" | sed 's/^/    /'
        
        # Now try to create a component cert also with auto serial
        log "Testing component certificate with AUTO-GENERATED serial"
        local cert_name="test-cert-auto"
        
        if output=$(certutil -S \
            -n "${cert_name}" \
            -s "CN=test-auto.example.org" \
            -c "${ca_name}" \
            -t "u,u,u" \
            -k rsa \
            -g 2048 \
            -z "${NOISE_FILE}" \
            -Z SHA256 \
            -v 12 \
            -d "sql:${TEST_DIR}" \
            -f "${PASSWORD_FILE}" \
            --extKeyUsage serverAuth,clientAuth \
            --keyUsage digitalSignature,keyEncipherment \
            -8 "test-auto.example.org" \
            2>&1); then
            success "  ✓ Component cert creation succeeded (auto serial)"
            log "  Inspecting component certificate details..."
            certutil -L -n "${cert_name}" -d "sql:${TEST_DIR}" 2>&1 | grep -A 2 "Serial Number" | sed 's/^/    /'
            return 0
        else
            error "  ✗ Component cert creation failed (auto serial)"
            echo "${output}" | sed 's/^/    /'
            return 1
        fi
        
        return 0
    else
        error "  ✗ CA creation failed (auto serial)"
        echo "${output}" | sed 's/^/    /'
        return 1
    fi
}

# Test function for creating a CA with specific serial format
test_ca_serial() {
    local format="$1"
    local serial="$2"
    local description="$3"
    local ca_name="test-ca-${format}"
    
    log "Testing CA certificate: ${description}"
    log "  Format: ${format}"
    log "  Serial: ${serial}"
    
    # Try to create CA certificate
    local output
    if output=$(certutil -S \
        -n "${ca_name}" \
        -s "CN=Test CA ${format}" \
        -x \
        -t "CT,C,C" \
        -k rsa \
        -g 2048 \
        -z "${NOISE_FILE}" \
        -Z SHA256 \
        -v 12 \
        -m "${serial}" \
        -d "sql:${TEST_DIR}" \
        -f "${PASSWORD_FILE}" \
        --keyUsage certSigning,crlSigning \
        2>&1); then
        success "  ✓ CA creation succeeded"
        
        # Debug: Show the serial number that was actually assigned
        log "  Inspecting certificate details..."
        certutil -L -n "${ca_name}" -d "sql:${TEST_DIR}" 2>&1 | grep -A 2 "Serial Number" | sed 's/^/    /'
        
        # Debug: List all certificates and their serials in database
        log "  Current certificates in database:"
        certutil -L -d "sql:${TEST_DIR}" 2>&1 | sed 's/^/    /'
        
        return 0
    else
        error "  ✗ CA creation failed"
        echo "${output}" | sed 's/^/    /'
        return 1
    fi
}

# Test function for creating a component cert with specific serial
test_component_serial() {
    local format="$1"
    local serial="$2"
    local description="$3"
    local ca_name="$4"
    local cert_name="test-cert-${format}"
    
    log "Testing component certificate: ${description}"
    log "  Format: ${format}"
    log "  Serial: ${serial}"
    log "  CA: ${ca_name}"
    
    # Try to create component certificate
    local output
    if output=$(certutil -S \
        -n "${cert_name}" \
        -s "CN=test.example.org" \
        -c "${ca_name}" \
        -t "u,u,u" \
        -k rsa \
        -g 2048 \
        -z "${NOISE_FILE}" \
        -Z SHA256 \
        -v 12 \
        -m "${serial}" \
        -d "sql:${TEST_DIR}" \
        -f "${PASSWORD_FILE}" \
        --extKeyUsage serverAuth,clientAuth \
        --keyUsage digitalSignature,keyEncipherment \
        -8 "test.example.org" \
        2>&1); then
        success "  ✓ Component cert creation succeeded"
        return 0
    else
        error "  ✗ Component cert creation failed"
        echo "${output}" | sed 's/^/    /'
        return 1
    fi
}

# Generate test serials
generate_hex_serial_with_prefix() {
    local bytes="$1"
    echo "0x$(head -c ${bytes} /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

generate_hex_serial_without_prefix() {
    local bytes="$1"
    head -c ${bytes} /dev/urandom | od -An -tx1 | tr -d ' \n'
}

generate_decimal_serial() {
    local bytes="$1"
    # Generate hex then convert to decimal
    local hex
    hex=$(head -c ${bytes} /dev/urandom | od -An -tx1 | tr -d ' \n')
    echo $((16#${hex}))
}

generate_timestamp_serial() {
    # Unix timestamp + random 4 bytes
    local timestamp=$(date +%s)
    local random=$(head -c 4 /dev/urandom | od -An -tu4 | tr -d ' ')
    echo "${timestamp}${random}"
}

# Main test execution
main() {
    log "=== NSS Certutil Serial Number Format Test ==="
    echo ""
    
    log "Checking certutil version..."
    certutil -H 2>&1 | head -5 || true
    echo ""
    
    setup
    echo ""
    
    # Test 1: Current implementation (hex with 0x prefix, 4 bytes)
    log "Test 1: Hex with 0x prefix, 4 bytes (current implementation)"
    local serial1=$(generate_hex_serial_with_prefix 4)
    if test_ca_serial "hex-0x-4b" "${serial1}" "Hex with 0x prefix, 4 bytes" "test-ca-hex-0x-4b"; then
        # Try to create a second cert with same format but different serial
        local serial2=$(generate_hex_serial_with_prefix 4)
        test_component_serial "hex-0x-4b" "${serial2}" "Component cert with hex 0x, 4 bytes" "test-ca-hex-0x-4b" || true
    fi
    echo ""
    
    # Test 2: Hex without 0x prefix, 4 bytes
    log "Test 2: Hex without 0x prefix, 4 bytes"
    local serial3=$(generate_hex_serial_without_prefix 4)
    if test_ca_serial "hex-plain-4b" "${serial3}" "Hex without 0x prefix, 4 bytes" "test-ca-hex-plain-4b"; then
        local serial4=$(generate_hex_serial_without_prefix 4)
        test_component_serial "hex-plain-4b" "${serial4}" "Component cert with plain hex, 4 bytes" "test-ca-hex-plain-4b" || true
    fi
    echo ""
    
    # Test 3: Decimal format, 4 bytes
    log "Test 3: Decimal format, 4 bytes"
    local serial5=$(generate_decimal_serial 4)
    if test_ca_serial "decimal-4b" "${serial5}" "Decimal format, 4 bytes" "test-ca-decimal-4b"; then
        local serial6=$(generate_decimal_serial 4)
        test_component_serial "decimal-4b" "${serial6}" "Component cert with decimal, 4 bytes" "test-ca-decimal-4b" || true
    fi
    echo ""
    
    # Test 4: Hex with 0x prefix, 8 bytes (longer serial)
    log "Test 4: Hex with 0x prefix, 8 bytes"
    local serial7=$(generate_hex_serial_with_prefix 8)
    if test_ca_serial "hex-0x-8b" "${serial7}" "Hex with 0x prefix, 8 bytes" "test-ca-hex-0x-8b"; then
        local serial8=$(generate_hex_serial_with_prefix 8)
        test_component_serial "hex-0x-8b" "${serial8}" "Component cert with hex 0x, 8 bytes" "test-ca-hex-0x-8b" || true
    fi
    echo ""
    
    # Test 5: Hex with 0x prefix, 16 bytes (very long serial)
    log "Test 5: Hex with 0x prefix, 16 bytes"
    local serial9=$(generate_hex_serial_with_prefix 16)
    if test_ca_serial "hex-0x-16b" "${serial9}" "Hex with 0x prefix, 16 bytes" "test-ca-hex-0x-16b"; then
        local serial10=$(generate_hex_serial_with_prefix 16)
        test_component_serial "hex-0x-16b" "${serial10}" "Component cert with hex 0x, 16 bytes" "test-ca-hex-0x-16b" || true
    fi
    echo ""
    
    # Test 6: Timestamp-based serial (decimal)
    log "Test 6: Timestamp-based serial (decimal)"
    local serial11=$(generate_timestamp_serial)
    if test_ca_serial "timestamp" "${serial11}" "Timestamp-based decimal" "test-ca-timestamp"; then
        local serial12=$(generate_timestamp_serial)
        sleep 1  # Ensure different timestamp
        test_component_serial "timestamp" "${serial12}" "Component cert with timestamp serial" "test-ca-timestamp" || true
    fi
    echo ""
    
    # Test 7: Auto-generated serials (omit -m flag)
    log "Test 7: Auto-generated serials (omit -m flag entirely)"
    test_ca_auto_serial
    echo ""
    
    # List all certificates created
    # List all certificates created
    log "All certificates in database:"
    certutil -L -d "sql:${TEST_DIR}" || true
    echo ""
    
    # Show detailed info for each cert to see actual serials used
    log "Detailed certificate information:"
    for cert in $(certutil -L -d "sql:${TEST_DIR}" | tail -n +4 | awk '{print $1}'); do
        echo "--- Certificate: ${cert} ---"
        certutil -L -n "${cert}" -d "sql:${TEST_DIR}" 2>/dev/null | grep -A 2 "Serial Number" || true
        echo ""
    done
    
    success "=== Test Complete ==="
    log "Review the results above to determine which serial format works best"
}

main "$@"