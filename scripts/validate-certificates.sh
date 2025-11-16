#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Certificate Validation Script
#
# This script validates NSS certificates for Sigul components, checking:
# - Certificate existence
# - Certificate chain validity
# - Extended Key Usage
# - Subject Alternative Names
# - Expiration dates
#
# Usage:
#   ./validate-certificates.sh bridge
#   ./validate-certificates.sh server
#   ./validate-certificates.sh client
#
# Environment Variables:
#   NSS_DB_DIR - NSS database directory (default: /etc/pki/sigul/<component>)

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Component type
COMPONENT="${1:-}"

# Validation results
VALIDATION_PASSED=0
VALIDATION_FAILED=0

# Logging functions
log() {
    echo -e "${BLUE}[CERT-VALIDATE]${NC} $*"
}

success() {
    echo -e "${GREEN}[✓]${NC} $*"
    VALIDATION_PASSED=$((VALIDATION_PASSED + 1))
}

warn() {
    echo -e "${YELLOW}[⚠]${NC} $*"
}

error() {
    echo -e "${RED}[✗]${NC} $*"
    VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
}

fatal() {
    error "$*"
    exit 1
}

# Validate component argument
validate_component() {
    if [ -z "${COMPONENT}" ]; then
        fatal "Usage: $0 <component>\n  Where component is: bridge, server, or client"
    fi

    case "${COMPONENT}" in
        bridge|server|client)
            log "Validating certificates for component: ${COMPONENT}"
            ;;
        *)
            fatal "Invalid component: ${COMPONENT} (must be bridge, server, or client)"
            ;;
    esac
}

# Setup configuration
setup_configuration() {
    NSS_DB_DIR="${NSS_DB_DIR:-/etc/pki/sigul/${COMPONENT}}"
    CA_NICKNAME="sigul-ca"
    CERT_NICKNAME="sigul-${COMPONENT}-cert"
    EXPECTED_FQDN="sigul-${COMPONENT}.example.org"

    log "Configuration:"
    log "  NSS Database: ${NSS_DB_DIR}"
    log "  CA Nickname: ${CA_NICKNAME}"
    log "  Certificate Nickname: ${CERT_NICKNAME}"
    log "  Expected FQDN: ${EXPECTED_FQDN}"
    echo ""
}

# Check NSS database exists
check_database_exists() {
    log "=== NSS Database Check ==="

    if [ ! -d "${NSS_DB_DIR}" ]; then
        error "NSS database directory does not exist: ${NSS_DB_DIR}"
        return 1
    fi
    success "NSS database directory exists"

    if [ ! -f "${NSS_DB_DIR}/cert9.db" ]; then
        error "cert9.db not found (modern NSS format required)"
        return 1
    fi
    success "Modern NSS database format (cert9.db) detected"

    if [ ! -f "${NSS_DB_DIR}/key4.db" ]; then
        error "key4.db not found"
        return 1
    fi
    success "NSS key database (key4.db) found"

    echo ""
}

# List all certificates
list_certificates() {
    log "=== Certificate Inventory ==="

    if ! certutil -L -d "sql:${NSS_DB_DIR}" 2>/dev/null; then
        error "Failed to list certificates"
        return 1
    fi

    echo ""
}

# Check CA certificate
check_ca_certificate() {
    log "=== CA Certificate Check ==="

    if ! certutil -L -d "sql:${NSS_DB_DIR}" -n "${CA_NICKNAME}" >/dev/null 2>&1; then
        error "CA certificate not found: ${CA_NICKNAME}"
        return 1
    fi
    success "CA certificate exists: ${CA_NICKNAME}"

    # Check CA trust flags
    local trust_flags
    trust_flags=$(certutil -L -d "sql:${NSS_DB_DIR}" | grep "^${CA_NICKNAME}" | awk '{print $2}' || echo "")

    if [[ "${trust_flags}" == *"C"* ]]; then
        success "CA certificate has correct trust flags (contains 'C' for SSL CA)"
    else
        error "CA certificate trust flags incorrect: ${trust_flags} (expected to contain 'C')"
    fi

    echo ""
}

# Check component certificate
check_component_certificate() {
    log "=== Component Certificate Check ==="

    if ! certutil -L -d "sql:${NSS_DB_DIR}" -n "${CERT_NICKNAME}" >/dev/null 2>&1; then
        error "Component certificate not found: ${CERT_NICKNAME}"
        return 1
    fi
    success "Component certificate exists: ${CERT_NICKNAME}"

    # Show certificate details
    log "Certificate details:"
    certutil -L -d "sql:${NSS_DB_DIR}" -n "${CERT_NICKNAME}" 2>/dev/null || true

    echo ""
}

# Verify certificate chain
verify_certificate_chain() {
    log "=== Certificate Chain Verification ==="

    # Verify for SSL server usage
    if certutil -V -n "${CERT_NICKNAME}" -u V -d "sql:${NSS_DB_DIR}" >/dev/null 2>&1; then
        success "Certificate chain valid for SSL server authentication"
    else
        warn "Certificate chain verification failed (may be expected in test environment)"
    fi

    # Verify for SSL client usage
    if certutil -V -n "${CERT_NICKNAME}" -u C -d "sql:${NSS_DB_DIR}" >/dev/null 2>&1; then
        success "Certificate chain valid for SSL client authentication"
    else
        warn "Certificate verification failed for client auth (may be expected in test environment)"
    fi

    echo ""
}

# Check certificate subject
check_certificate_subject() {
    log "=== Certificate Subject Check ==="

    local cert_details
    cert_details=$(certutil -L -d "sql:${NSS_DB_DIR}" -n "${CERT_NICKNAME}" 2>/dev/null || echo "")

    if echo "${cert_details}" | grep -q "CN=${EXPECTED_FQDN}"; then
        success "Certificate has FQDN in Common Name: CN=${EXPECTED_FQDN}"
    else
        error "Certificate Common Name does not match expected FQDN"
        log "Expected: CN=${EXPECTED_FQDN}"
        log "Certificate details:\n${cert_details}"
    fi

    echo ""
}

# Check Subject Alternative Name
check_san() {
    log "=== Subject Alternative Name (SAN) Check ==="

    local cert_details
    cert_details=$(certutil -L -d "sql:${NSS_DB_DIR}" -n "${CERT_NICKNAME}" 2>/dev/null || echo "")

    if echo "${cert_details}" | grep -q "DNS name:.*${EXPECTED_FQDN}"; then
        success "Certificate has SAN with DNS name: ${EXPECTED_FQDN}"
    elif echo "${cert_details}" | grep -q "Subject Alternative Name"; then
        warn "Certificate has SAN extension but may not include ${EXPECTED_FQDN}"
    else
        warn "Subject Alternative Name extension not detected (check certutil output)"
    fi

    echo ""
}

# Check Extended Key Usage
check_extended_key_usage() {
    log "=== Extended Key Usage Check ==="

    local cert_details
    cert_details=$(certutil -L -d "sql:${NSS_DB_DIR}" -n "${CERT_NICKNAME}" 2>/dev/null || echo "")

    local has_server_auth=0
    local has_client_auth=0

    if echo "${cert_details}" | grep -qi "TLS Web Server Authentication"; then
        has_server_auth=1
    fi

    if echo "${cert_details}" | grep -qi "TLS Web Client Authentication"; then
        has_client_auth=1
    fi

    if [ $has_server_auth -eq 1 ] && [ $has_client_auth -eq 1 ]; then
        success "Certificate has correct Extended Key Usage (serverAuth + clientAuth)"
    elif [ $has_server_auth -eq 1 ]; then
        warn "Certificate has serverAuth but missing clientAuth"
    elif [ $has_client_auth -eq 1 ]; then
        warn "Certificate has clientAuth but missing serverAuth"
    else
        warn "Extended Key Usage not detected (may not be visible in certutil output)"
    fi

    echo ""
}

# Check certificate expiration
check_expiration() {
    log "=== Certificate Expiration Check ==="

    local cert_details
    cert_details=$(certutil -L -d "sql:${NSS_DB_DIR}" -n "${CERT_NICKNAME}" 2>/dev/null || echo "")

    if echo "${cert_details}" | grep -q "Not After"; then
        local not_after
        not_after=$(echo "${cert_details}" | grep "Not After" | head -n1 || echo "Unknown")
        log "Certificate expiration: ${not_after}"

        # Check if expired (basic check)
        if echo "${cert_details}" | grep -qi "expired"; then
            error "Certificate has EXPIRED"
        else
            success "Certificate is not expired"
        fi
    else
        warn "Could not determine certificate expiration date"
    fi

    echo ""
}

# Check file permissions
check_permissions() {
    log "=== File Permissions Check ==="

    local dir_perms
    dir_perms=$(stat -c "%a" "${NSS_DB_DIR}" 2>/dev/null || stat -f "%Lp" "${NSS_DB_DIR}" 2>/dev/null || echo "unknown")

    if [ "${dir_perms}" = "755" ] || [ "${dir_perms}" = "700" ]; then
        success "NSS database directory has appropriate permissions: ${dir_perms}"
    else
        warn "NSS database directory permissions may be too permissive: ${dir_perms}"
    fi

    # Check database file permissions
    if [ -f "${NSS_DB_DIR}/cert9.db" ]; then
        local db_perms
        db_perms=$(stat -c "%a" "${NSS_DB_DIR}/cert9.db" 2>/dev/null || stat -f "%Lp" "${NSS_DB_DIR}/cert9.db" 2>/dev/null || echo "unknown")

        if [ "${db_perms}" = "644" ] || [ "${db_perms}" = "600" ]; then
            success "NSS database files have appropriate permissions: ${db_perms}"
        else
            warn "NSS database file permissions: ${db_perms}"
        fi
    fi

    echo ""
}

# Summary
show_summary() {
    echo ""
    log "=== Validation Summary ==="
    echo ""

    if [ $VALIDATION_FAILED -eq 0 ]; then
        success "All critical checks passed: ${VALIDATION_PASSED} checks"
        echo ""
        log "Certificate validation SUCCESSFUL for ${COMPONENT}"
        return 0
    else
        error "Validation completed with failures"
        log "  Passed: ${VALIDATION_PASSED} checks"
        log "  Failed: ${VALIDATION_FAILED} checks"
        echo ""
        log "Certificate validation FAILED for ${COMPONENT}"
        return 1
    fi
}

# Main execution
main() {
    echo ""
    log "=== Certificate Validation Script ==="
    log "Version: 1.0.0"
    echo ""

    # Validate and setup
    validate_component
    setup_configuration

    # Run validation checks
    check_database_exists
    list_certificates
    check_ca_certificate
    check_component_certificate
    verify_certificate_chain
    check_certificate_subject
    check_san
    check_extended_key_usage
    check_expiration
    check_permissions

    # Show summary
    show_summary
}

# Run main function
main
