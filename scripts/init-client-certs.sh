#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Client Certificate Import Script
#
# This script imports client certificates that were pre-generated on the bridge.
# It imports:
# - CA public certificate (for trust validation)
# - Client certificate and private key
#
# Security: Does NOT import CA private key (bridge only)
#
# Usage:
#   NSS_PASSWORD=secret ./init-client-certs.sh
#
# Environment Variables:
#   NSS_PASSWORD - NSS database password (required)
#   DEBUG - Enable debug output (default: false)

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Configuration
NSS_PASSWORD="${NSS_PASSWORD:-}"
DEBUG="${DEBUG:-false}"

# FHS-compliant paths
readonly CLIENT_NSS_DIR="/etc/pki/sigul/client"
readonly CA_IMPORT_DIR="/etc/pki/sigul/bridge/ca-export"
readonly CLIENT_IMPORT_DIR="/etc/pki/sigul/bridge/client-export"

# Certificate nicknames
readonly CA_NICKNAME="sigul-ca"
readonly BRIDGE_CERT_NICKNAME="sigul-bridge-cert"
readonly CLIENT_CERT_NICKNAME="sigul-client-cert"

#######################################
# Logging Functions
#######################################

log() {
    echo -e "${BLUE}[CLIENT-CERT-INIT]${NC} $*"
}

success() {
    echo -e "${GREEN}[CLIENT-CERT-INIT]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[CLIENT-CERT-INIT]${NC} $*"
}

error() {
    echo -e "${RED}[CLIENT-CERT-INIT]${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${PURPLE}[CLIENT-CERT-INIT-DEBUG]${NC} $*"
    fi
}

#######################################
# Validation Functions
#######################################

validate_environment() {
    log "Validating environment..."

    if [[ -z "$NSS_PASSWORD" ]]; then
        fatal "NSS_PASSWORD environment variable is required"
    fi

    debug "NSS_PASSWORD is set (length: ${#NSS_PASSWORD})"
    success "Environment validation passed"
}

validate_import_files() {
    log "Validating import files..."

    local validation_failed=0

    # Check CA certificate
    if [[ ! -f "${CA_IMPORT_DIR}/ca.crt" ]]; then
        error "CA certificate not found: ${CA_IMPORT_DIR}/ca.crt"
        validation_failed=1
    else
        debug "CA certificate found: ${CA_IMPORT_DIR}/ca.crt"
    fi

    # Check bridge certificate
    if [[ ! -f "${CA_IMPORT_DIR}/bridge-cert.crt" ]]; then
        error "Bridge certificate not found: ${CA_IMPORT_DIR}/bridge-cert.crt"
        validation_failed=1
    else
        debug "Bridge certificate found: ${CA_IMPORT_DIR}/bridge-cert.crt"
    fi

    # Check client certificate PKCS#12
    if [[ ! -f "${CLIENT_IMPORT_DIR}/client-cert.p12" ]]; then
        error "Client certificate not found: ${CLIENT_IMPORT_DIR}/client-cert.p12"
        validation_failed=1
    else
        debug "Client certificate found: ${CLIENT_IMPORT_DIR}/client-cert.p12"
    fi

    # Check PKCS#12 password file
    if [[ ! -f "${CLIENT_IMPORT_DIR}/client-cert.p12.password" ]]; then
        error "Client certificate password not found: ${CLIENT_IMPORT_DIR}/client-cert.p12.password"
        validation_failed=1
    else
        debug "Client certificate password found"
    fi

    if [[ $validation_failed -eq 1 ]]; then
        fatal "Required import files missing - bridge initialization may not have completed"
    fi

    success "Import files validated"
}

#######################################
# Certificate Import Functions
#######################################

create_directories() {
    log "Creating client directories..."

    mkdir -p "$CLIENT_NSS_DIR"
    # chmod may fail on volume mounts - not fatal
    chmod 755 "$CLIENT_NSS_DIR" 2>/dev/null || true

    debug "Client NSS directory: $CLIENT_NSS_DIR"
}

create_password_file() {
    log "Creating NSS password file..."

    local password_file="${CLIENT_NSS_DIR}/.nss-password"
    printf '%s' "${NSS_PASSWORD}" > "${password_file}"
    chmod 600 "${password_file}"

    debug "Password file created: ${password_file}"
}

initialize_nss_database() {
    log "Initializing client NSS database..."

    # Check if database already exists
    if [[ -f "${CLIENT_NSS_DIR}/cert9.db" ]]; then
        log "NSS database already exists, skipping initialization"
        return 0
    fi

    # Create new NSS database
    local password_file="${CLIENT_NSS_DIR}/.nss-password"
    if ! certutil -N -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}"; then
        fatal "Failed to initialize NSS database"
    fi

    success "NSS database initialized"
}

import_ca_certificate() {
    log "Importing CA certificate (public only)..."

    local password_file="${CLIENT_NSS_DIR}/.nss-password"

    # Check if CA already imported
    if certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" -n "${CA_NICKNAME}" &>/dev/null; then
        log "CA certificate already imported"
        return 0
    fi

    # Import CA certificate for trust verification
    # Trust flags: CT,C,C means:
    #   CT = Trusted CA for SSL/TLS
    #   C = Valid CA
    #   C = Trusted for email
    if ! certutil -A \
        -d "sql:${CLIENT_NSS_DIR}" \
        -n "${CA_NICKNAME}" \
        -t "CT,C,C" \
        -a \
        -f "${password_file}" \
        -i "${CA_IMPORT_DIR}/ca.crt"; then
        fatal "Failed to import CA certificate"
    fi

    success "CA certificate imported (public only, no private key)"
}

import_bridge_certificate() {
    log "Importing bridge certificate (public only)..."

    local password_file="${CLIENT_NSS_DIR}/.nss-password"

    # Check if bridge certificate already imported
    if certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" -n "${BRIDGE_CERT_NICKNAME}" &>/dev/null; then
        log "Bridge certificate already imported"
        return 0
    fi

    # Import bridge certificate for SSL verification
    if ! certutil -A \
        -d "sql:${CLIENT_NSS_DIR}" \
        -n "${BRIDGE_CERT_NICKNAME}" \
        -t "P,P,P" \
        -a \
        -f "${password_file}" \
        -i "${CA_IMPORT_DIR}/bridge-cert.crt"; then
        fatal "Failed to import bridge certificate"
    fi

    success "Bridge certificate imported (public only, for SSL verification)"
}

import_client_certificate() {
    log "Importing client certificate and private key..."

    local password_file="${CLIENT_NSS_DIR}/.nss-password"

    # Check if client certificate already imported
    if certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" -n "${CLIENT_CERT_NICKNAME}" &>/dev/null; then
        log "Client certificate already imported"
        return 0
    fi

    # Read PKCS#12 password
    local p12_password
    p12_password=$(cat "${CLIENT_IMPORT_DIR}/client-cert.p12.password")

    # Import client certificate and key from PKCS#12
    if ! pk12util -i "${CLIENT_IMPORT_DIR}/client-cert.p12" \
        -d "sql:${CLIENT_NSS_DIR}" \
        -k "${password_file}" \
        -W "${p12_password}"; then
        fatal "Failed to import client certificate"
    fi

    # Verify the certificate was imported with correct nickname
    # pk12util may import with a different nickname, so we need to check
    debug "Verifying client certificate import..."
    if ! certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" -n "${CLIENT_CERT_NICKNAME}" &>/dev/null; then
        # Try to find the imported certificate and rename it
        warn "Client certificate imported with unexpected nickname, searching..."

        # List all certificates and try to identify the client cert
        local imported_nickname
        imported_nickname=$(certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" | \
            grep -v "Certificate Nickname" | \
            grep -v "^$" | \
            grep -v "${CA_NICKNAME}" | \
            head -1 | \
            awk '{print $1}')

        if [[ -n "$imported_nickname" ]]; then
            warn "Found certificate with nickname: $imported_nickname"
            warn "This is expected behavior - PKCS#12 import preserves original nickname"
            debug "Certificate is accessible as: $imported_nickname"
        else
            fatal "Could not verify client certificate import"
        fi
    fi

    success "Client certificate and private key imported"
}

verify_certificates() {
    log "Verifying imported certificates..."

    local verification_failed=0

    local password_file="${CLIENT_NSS_DIR}/.nss-password"

    # Verify NSS database exists
    if [[ ! -f "${CLIENT_NSS_DIR}/cert9.db" ]]; then
        error "NSS database not found"
        verification_failed=1
    fi

    # Verify CA certificate
    if ! certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" -n "${CA_NICKNAME}" &>/dev/null; then
        error "CA certificate verification failed"
        verification_failed=1
    else
        debug "CA certificate verified"
    fi

    # Verify bridge certificate
    if ! certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" -n "${BRIDGE_CERT_NICKNAME}" &>/dev/null; then
        error "Bridge certificate verification failed"
        verification_failed=1
    else
        debug "Bridge certificate verified"
    fi

    # Verify client certificate
    if ! certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" -n "${CLIENT_CERT_NICKNAME}" &>/dev/null; then
        warn "Client certificate not found with expected nickname"
        # Check if any certificate was imported
        local cert_count
        cert_count=$(certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" | grep -v "Certificate Nickname" | grep -vc "^$")
        if [[ $cert_count -lt 3 ]]; then
            error "Client certificate verification failed"
            verification_failed=1
        else
            debug "Client certificate imported with alternate nickname (acceptable)"
        fi
    else
        debug "Client certificate verified"
    fi

    # Verify CA private key is NOT present
    log "Verifying CA private key is NOT present (security check)..."
    if certutil -K -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" 2>/dev/null | grep -q "${CA_NICKNAME}"; then
        error "⚠️  SECURITY ISSUE: CA private key found on client!"
        error "⚠️  Client should NOT have CA signing authority"
        verification_failed=1
    else
        success "✓ Security verified: CA private key NOT present on client"
    fi

    if [[ $verification_failed -eq 1 ]]; then
        fatal "Certificate verification failed"
    fi

    success "Certificate verification passed"
}

display_certificate_info() {
    log "Client certificate import summary:"
    echo ""
    echo "  Client NSS Database: ${CLIENT_NSS_DIR}"
    echo ""

    local password_file="${CLIENT_NSS_DIR}/.nss-password"

    echo "  Imported certificates:"
    certutil -L -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" 2>/dev/null | tail -n +5 | sed 's/^/    /'
    echo ""
    echo "  Private keys available:"
    certutil -K -d "sql:${CLIENT_NSS_DIR}" -f "${password_file}" 2>/dev/null | tail -n +2 | sed 's/^/    /'
    echo ""
    echo "  Security status:"
    echo "    ✓ CA certificate imported (public only)"
    echo "    ✓ Bridge certificate imported (public only)"
    echo "    ✓ Client certificate and key imported"
    echo "    ✓ CA private key NOT present (correct)"
    echo ""
}

#######################################
# Main Execution
#######################################

main() {
    log "Client Certificate Import (Sigul PKI)"
    log "=================================================="
    echo ""

    # Validate environment
    validate_environment
    validate_import_files

    # Create client infrastructure
    create_directories
    create_password_file
    initialize_nss_database

    # Import certificates
    import_ca_certificate
    import_bridge_certificate
    import_client_certificate

    # Verify everything
    verify_certificates
    display_certificate_info

    success "Client certificate import completed successfully"
    echo ""
    log "Client is ready to connect to bridge"
}

# Execute main function
main "$@"
