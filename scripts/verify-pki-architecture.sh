#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# PKI Architecture Verification Script
#
# This script verifies that the Sigul PKI architecture is correctly implemented:
# - Bridge has CA private key
# - Server does NOT have CA private key
# - Client does NOT have CA private key
# - All components have required certificates
#
# Usage:
#   ./verify-pki-architecture.sh

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging functions
log() {
    echo -e "${BLUE}[PKI-VERIFY]${NC} $*"
}

success() {
    echo -e "${GREEN}✓${NC} $*"
    ((PASSED_TESTS++))
    ((TOTAL_TESTS++))
}

fail() {
    echo -e "${RED}✗${NC} $*"
    ((FAILED_TESTS++))
    ((TOTAL_TESTS++))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $*"
}

section() {
    echo ""
    echo -e "${BOLD}=== $* ===${NC}"
    echo ""
}

# Check if container exists and is running
check_container() {
    local container="$1"

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        warn "Container '${container}' is not running"
        return 1
    fi
    return 0
}

# Check if certificate exists in NSS database
check_cert_exists() {
    local container="$1"
    local nss_dir="$2"
    local cert_nickname="$3"

    if docker exec "${container}" certutil -L -d "sql:${nss_dir}" -n "${cert_nickname}" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if private key exists in NSS database
check_private_key_exists() {
    local container="$1"
    local nss_dir="$2"
    local cert_nickname="$3"

    if docker exec "${container}" certutil -K -d "sql:${nss_dir}" 2>/dev/null | grep -q "${cert_nickname}"; then
        return 0
    else
        return 1
    fi
}

# Verify bridge PKI
verify_bridge_pki() {
    section "Bridge PKI Verification"

    local container="sigul-bridge"
    local nss_dir="/etc/pki/sigul/bridge"

    if ! check_container "${container}"; then
        fail "Bridge container not running"
        return
    fi

    # Check CA certificate exists
    if check_cert_exists "${container}" "${nss_dir}" "sigul-ca"; then
        success "Bridge has CA certificate"
    else
        fail "Bridge missing CA certificate"
    fi

    # Check CA private key exists (REQUIRED for bridge)
    if check_private_key_exists "${container}" "${nss_dir}" "sigul-ca"; then
        success "Bridge has CA private key (correct - bridge is CA)"
    else
        fail "Bridge missing CA private key (required for signing)"
    fi

    # Check bridge certificate exists
    if check_cert_exists "${container}" "${nss_dir}" "sigul-bridge-cert"; then
        success "Bridge has its own certificate"
    else
        fail "Bridge missing its own certificate"
    fi

    # Check bridge private key exists
    if check_private_key_exists "${container}" "${nss_dir}" "sigul-bridge-cert"; then
        success "Bridge has its own private key"
    else
        fail "Bridge missing its own private key"
    fi

    # Check if export directories exist
    if docker exec "${container}" test -f /etc/pki/sigul/ca-export/ca.crt; then
        success "CA certificate exported for distribution"
    else
        fail "CA certificate not exported"
    fi

    if docker exec "${container}" test -f /etc/pki/sigul/server-export/server-cert.p12; then
        success "Server certificate exported for distribution"
    else
        fail "Server certificate not exported"
    fi

    if docker exec "${container}" test -f /etc/pki/sigul/client-export/client-cert.p12; then
        success "Client certificate exported for distribution"
    else
        fail "Client certificate not exported"
    fi
}

# Verify server PKI
verify_server_pki() {
    section "Server PKI Verification"

    local container="sigul-server"
    local nss_dir="/etc/pki/sigul/server"

    if ! check_container "${container}"; then
        fail "Server container not running"
        return
    fi

    # Check CA certificate exists (public only)
    if check_cert_exists "${container}" "${nss_dir}" "sigul-ca"; then
        success "Server has CA certificate (for validation)"
    else
        fail "Server missing CA certificate"
    fi

    # Check CA private key does NOT exist (SECURITY CRITICAL)
    if check_private_key_exists "${container}" "${nss_dir}" "sigul-ca"; then
        fail "⚠️  SECURITY ISSUE: Server has CA private key (should NOT have)"
    else
        success "Server does NOT have CA private key (correct)"
    fi

    # Check server certificate exists
    if check_cert_exists "${container}" "${nss_dir}" "sigul-server-cert"; then
        success "Server has its own certificate"
    else
        fail "Server missing its own certificate"
    fi

    # Check server private key exists
    if check_private_key_exists "${container}" "${nss_dir}" "sigul-server-cert"; then
        success "Server has its own private key"
    else
        fail "Server missing its own private key"
    fi
}

# Verify client PKI
verify_client_pki() {
    section "Client PKI Verification"

    local container="sigul-client-test"
    local nss_dir="/etc/pki/sigul/client"

    if ! check_container "${container}"; then
        warn "Client container not running (may be in 'testing' profile)"
        return
    fi

    # Check CA certificate exists (public only)
    if check_cert_exists "${container}" "${nss_dir}" "sigul-ca"; then
        success "Client has CA certificate (for validation)"
    else
        fail "Client missing CA certificate"
    fi

    # Check CA private key does NOT exist (SECURITY CRITICAL)
    if check_private_key_exists "${container}" "${nss_dir}" "sigul-ca"; then
        fail "⚠️  SECURITY ISSUE: Client has CA private key (should NOT have)"
    else
        success "Client does NOT have CA private key (correct)"
    fi

    # Check client certificate exists
    if check_cert_exists "${container}" "${nss_dir}" "sigul-client-cert"; then
        success "Client has its own certificate"
    else
        fail "Client missing its own certificate"
    fi

    # Check client private key exists
    if check_private_key_exists "${container}" "${nss_dir}" "sigul-client-cert"; then
        success "Client has its own private key"
    else
        fail "Client missing its own private key"
    fi
}

# Verify configurations
verify_configurations() {
    section "Configuration File Verification"

    # Check bridge configuration
    if docker exec sigul-bridge test -f /etc/sigul/bridge.conf; then
        success "Bridge configuration exists"

        # Check for CA nickname in config
        if docker exec sigul-bridge grep -q "bridge-ca-cert-nickname: sigul-ca" /etc/sigul/bridge.conf; then
            success "Bridge configuration includes CA certificate nickname"
        else
            fail "Bridge configuration missing CA certificate nickname"
        fi
    else
        fail "Bridge configuration missing"
    fi

    # Check server configuration
    if docker exec sigul-server test -f /etc/sigul/server.conf 2>/dev/null; then
        success "Server configuration exists"

        # Check for CA nickname in config
        if docker exec sigul-server grep -q "server-ca-cert-nickname: sigul-ca" /etc/sigul/server.conf; then
            success "Server configuration includes CA certificate nickname"
        else
            fail "Server configuration missing CA certificate nickname"
        fi
    else
        fail "Server configuration missing"
    fi
}

# Display detailed certificate information
display_certificate_info() {
    section "Detailed Certificate Information"

    echo -e "${BOLD}Bridge Certificates:${NC}"
    docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge 2>/dev/null || echo "  Unable to list certificates"
    echo ""

    echo -e "${BOLD}Bridge Private Keys:${NC}"
    docker exec sigul-bridge certutil -K -d sql:/etc/pki/sigul/bridge 2>/dev/null || echo "  Unable to list keys"
    echo ""

    echo -e "${BOLD}Server Certificates:${NC}"
    docker exec sigul-server certutil -L -d sql:/etc/pki/sigul/server 2>/dev/null || echo "  Unable to list certificates"
    echo ""

    echo -e "${BOLD}Server Private Keys:${NC}"
    docker exec sigul-server certutil -K -d sql:/etc/pki/sigul/server 2>/dev/null || echo "  Unable to list keys"
    echo ""

    if check_container "sigul-client-test"; then
        echo -e "${BOLD}Client Certificates:${NC}"
        docker exec sigul-client-test certutil -L -d sql:/etc/pki/sigul/client 2>/dev/null || echo "  Unable to list certificates"
        echo ""

        echo -e "${BOLD}Client Private Keys:${NC}"
        docker exec sigul-client-test certutil -K -d sql:/etc/pki/sigul/client 2>/dev/null || echo "  Unable to list keys"
        echo ""
    fi
}

# Print summary
print_summary() {
    section "Verification Summary"

    echo "Total tests: ${TOTAL_TESTS}"
    echo -e "Passed: ${GREEN}${PASSED_TESTS}${NC}"
    echo -e "Failed: ${RED}${FAILED_TESTS}${NC}"
    echo ""

    if [[ ${FAILED_TESTS} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✓ All PKI architecture tests passed!${NC}"
        echo ""
        echo "The Sigul PKI architecture is correctly implemented:"
        echo "  • Bridge is the Certificate Authority"
        echo "  • Bridge has CA private key (signing authority)"
        echo "  • Server has CA public certificate only"
        echo "  • Client has CA public certificate only"
        echo "  • All components have their own certificates"
        echo ""
        return 0
    else
        echo -e "${RED}${BOLD}✗ PKI architecture verification failed${NC}"
        echo ""
        echo "Issues detected with the PKI architecture."
        echo "Please review the failed tests above and consult PKI_ARCHITECTURE.md"
        echo ""
        return 1
    fi
}

# Main execution
main() {
    echo -e "${BOLD}"
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║   Sigul PKI Architecture Verification Script          ║"
    echo "║   Version 2.0.0                                        ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log "Starting PKI architecture verification..."
    echo ""

    # Run verification tests
    verify_bridge_pki
    verify_server_pki
    verify_client_pki
    verify_configurations

    # Display detailed information
    display_certificate_info

    # Print summary and exit
    print_summary
}

# Execute main function
main "$@"
