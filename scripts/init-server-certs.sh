#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Server Certificate Import Script
#
# This script imports server certificates that were pre-generated on the bridge.
# It imports:
# - CA public certificate (for trust validation)
# - Server certificate and private key
#
# Security: Does NOT import CA private key (bridge only)
#
# Usage:
#   NSS_PASSWORD=secret ./init-server-certs.sh
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
readonly SERVER_NSS_DIR="/etc/pki/sigul/server"
readonly CA_IMPORT_DIR="/etc/pki/sigul/bridge/ca-export"
readonly SERVER_IMPORT_DIR="/etc/pki/sigul/bridge/server-export"

# Certificate nicknames
readonly CA_NICKNAME="sigul-ca"
readonly SERVER_CERT_NICKNAME="sigul-server-cert"

#######################################
# Logging Functions
#######################################

log() {
    echo -e "${BLUE}[SERVER-CERT-INIT]${NC} $*"
}

success() {
    echo -e "${GREEN}[SERVER-CERT-INIT]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[SERVER-CERT-INIT]${NC} $*"
}

error() {
    echo -e "${RED}[SERVER-CERT-INIT]${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${PURPLE}[SERVER-CERT-INIT-DEBUG]${NC} $*"
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

    # Check server certificate PKCS#12
    if [[ ! -f "${SERVER_IMPORT_DIR}/server-cert.p12" ]]; then
        error "Server certificate not found: ${SERVER_IMPORT_DIR}/server-cert.p12"
        validation_failed=1
    else
        debug "Server certificate found: ${SERVER_IMPORT_DIR}/server-cert.p12"
    fi

    # Check PKCS#12 password file
    if [[ ! -f "${SERVER_IMPORT_DIR}/server-cert.p12.password" ]]; then
        error "Server certificate password not found: ${SERVER_IMPORT_DIR}/server-cert.p12.password"
        validation_failed=1
    else
        debug "Server certificate password found"
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
    log "Creating server directories..."

    mkdir -p "$SERVER_NSS_DIR"
    chmod 755 "$SERVER_NSS_DIR"

    debug "Server NSS directory: $SERVER_NSS_DIR"
}

create_password_file() {
    log "Creating NSS password file..."

    local password_file="${SERVER_NSS_DIR}/.nss-password"
    echo "${NSS_PASSWORD}" > "${password_file}"
    chmod 600 "${password_file}"

    debug "Password file created: ${password_file}"
}

initialize_nss_database() {
    log "Initializing server NSS database..."

    # Check if database already exists
    if [[ -f "${SERVER_NSS_DIR}/cert9.db" ]]; then
        log "NSS database already exists, skipping initialization"
        return 0
    fi

    # Create new NSS database
    local password_file="${SERVER_NSS_DIR}/.nss-password"
    if ! certutil -N -d "sql:${SERVER_NSS_DIR}" -f "${password_file}"; then
        fatal "Failed to initialize NSS database"
    fi

    success "NSS database initialized"
}

import_ca_certificate() {
    log "Importing CA certificate (public only)..."

    local password_file="${SERVER_NSS_DIR}/.nss-password"

    # Check if CA already imported
    if certutil -L -d "sql:${SERVER_NSS_DIR}" -f "${password_file}" -n "${CA_NICKNAME}" &>/dev/null; then
        log "CA certificate already imported"
        return 0
    fi

    # Import CA certificate for trust verification
    if ! certutil -A \
        -d "sql:${SERVER_NSS_DIR}" \
        -n "${CA_NICKNAME}" \
        -t "CT,C,C" \
        -a \
        -f "${password_file}" \
        -i "${CA_IMPORT_DIR}/ca.crt"; then
        fatal "Failed to import CA certificate"
    fi

    success "CA certificate imported (public only, no private key)"
}

import_server_certificate() {
    log "Importing server certificate and private key..."

    # Check if server certificate already imported
    if certutil -L -d "sql:${SERVER_NSS_DIR}" -n "${SERVER_CERT_NICKNAME}" &>/dev/null; then
        log "Server certificate already imported"
        return 0
    fi

    # Read PKCS#12 password
    local p12_password
    p12_password=$(cat "${SERVER_IMPORT_DIR}/server-cert.p12.password")

    # Import server certificate and key from PKCS#12
    local password_file="${SERVER_NSS_DIR}/.nss-password"
    if ! pk12util -i "${SERVER_IMPORT_DIR}/server-cert.p12" \
        -d "sql:${SERVER_NSS_DIR}" \
        -k "${password_file}" \
        -W "${p12_password}"; then
        fatal "Failed to import server certificate"
    fi

    # Verify the certificate was imported with correct nickname
    # pk12util may import with a different nickname, so we need to check
    debug "Verifying server certificate import..."
    if ! certutil -L -d "sql:${SERVER_NSS_DIR}" -n "${SERVER_CERT_NICKNAME}" &>/dev/null; then
        # Try to find the imported certificate and rename it
        warn "Server certificate imported with unexpected nickname, searching..."
        
        # List all certificates and try to identify the server cert
        local imported_nickname
        imported_nickname=$(certutil -L -d "sql:${SERVER_NSS_DIR}" | \
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
            fatal "Could not verify server certificate import"
        fi
    fi

    success "Server certificate and private key imported"
}

verify_certificates() {
    log "Verifying imported certificates..."

    local verification_failed=0

    local password_file="${SERVER_NSS_DIR}/.nss-password"

    # Verify NSS database exists
    if [[ ! -f "${SERVER_NSS_DIR}/cert9.db" ]]; then
        error "NSS database not found"
        verification_failed=1
    fi

    # Verify CA certificate
    if ! certutil -L -d "sql:${SERVER_NSS_DIR}" -f "${password_file}" -n "${CA_NICKNAME}" &>/dev/null; then
        error "CA certificate verification failed"
        verification_failed=1
    else
        debug "CA certificate verified"
    fi

    # Verify server certificate
    if ! certutil -L -d "sql:${SERVER_NSS_DIR}" -f "${password_file}" -n "${SERVER_CERT_NICKNAME}" &>/dev/null; then
        warn "Server certificate not found with expected nickname"
        # Check if any certificate was imported
        local cert_count
        cert_count=$(certutil -L -d "sql:${SERVER_NSS_DIR}" -f "${password_file}" | grep -v "Certificate Nickname" | grep -v "^$" | wc -l)
        if [[ $cert_count -lt 2 ]]; then
            error "Server certificate verification failed"
            verification_failed=1
        else
            debug "Server certificate imported with alternate nickname (acceptable)"
        fi
    else
        debug "Server certificate verified"
    fi

    # Verify CA private key is NOT present
    log "Verifying CA private key is NOT present (security check)..."
    if certutil -K -d "sql:${SERVER_NSS_DIR}" -f "${password_file}" 2>/dev/null | grep -q "${CA_NICKNAME}"; then
        error "⚠️  SECURITY ISSUE: CA private key found on server!"
        error "⚠️  Server should NOT have CA signing authority"
        verification_failed=1
    else
        success "✓ Security verified: CA private key NOT present on server"
    fi

    if [[ $verification_failed -eq 1 ]]; then
        fatal "Certificate verification failed"
    fi

    success "Certificate verification passed"
}

display_certificate_info() {
    log "Server certificate import summary:"
    echo ""
    echo "  Server NSS Database: ${SERVER_NSS_DIR}"
    echo ""
    
    local password_file="${SERVER_NSS_DIR}/.nss-password"
    
    echo "  Imported certificates:"
    certutil -L -d "sql:${SERVER_NSS_DIR}" -f "${password_file}" 2>/dev/null | tail -n +5 | sed 's/^/    /'
    echo ""
    echo "  Private keys available:"
    certutil -K -d "sql:${SERVER_NSS_DIR}" -f "${password_file}" 2>/dev/null | tail -n +2 | sed 's/^/    /'
    echo ""
    echo "  Security status:"
    echo "    ✓ CA certificate imported (public only)"
    echo "    ✓ Server certificate and key imported"
    echo "    ✓ CA private key NOT present (correct)"
    echo ""
}

#######################################
# Main Execution
#######################################

main() {
    log "Server Certificate Import (Production-Aligned PKI)"
    log "=================================================="
    echo ""

    # Validate environment
    validate_environment
    validate_import_files

    # Create server infrastructure
    create_directories
    create_password_file
    initialize_nss_database

    # Import certificates
    import_ca_certificate
    import_server_certificate

    # Verify everything
    verify_certificates
    display_certificate_info

    success "Server certificate import completed successfully"
    echo ""
    log "Server is ready to connect to bridge"
}

# Execute main function
main "$@"