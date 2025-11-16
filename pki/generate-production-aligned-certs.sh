#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Production-Aligned Certificate Generation Script
#
# This script generates NSS certificates with production-aligned attributes:
# - FQDN-based Common Names
# - Subject Alternative Names (SAN)
# - Extended Key Usage (serverAuth + clientAuth)
# - Modern cert9.db format
# - Proper trust flags
#
# Usage:
#   NSS_DB_DIR=/etc/pki/sigul/bridge \
#   NSS_PASSWORD=secret \
#   COMPONENT=bridge \
#   FQDN=sigul-bridge.example.org \
#   ./generate-production-aligned-certs.sh
#
# Environment Variables:
#   NSS_DB_DIR - NSS database directory (required)
#   NSS_PASSWORD - NSS database password (required)
#   COMPONENT - Component type: bridge, server, or client (required)
#   FQDN - Fully qualified domain name (default: ${COMPONENT}.example.org)
#   CA_SUBJECT - CA subject (default: CN=Sigul CA)
#   KEY_SIZE - RSA key size (default: 2048)
#   VALIDITY_MONTHS - Certificate validity in months (default: 120)
#   FORCE_CLEAN_DB - Force clean NSS database before generation (default: false)
#   DEBUG - Enable debug output (default: false)

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Debug flag
DEBUG="${DEBUG:-false}"

# Logging functions
log() {
    echo -e "${BLUE}[CERT-GEN]${NC} $*"
}

success() {
    echo -e "${GREEN}[CERT-GEN]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[CERT-GEN]${NC} $*"
}

error() {
    echo -e "${RED}[CERT-GEN]${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${PURPLE}[CERT-GEN-DEBUG]${NC} $*"
    fi
}

# Validate required environment variables
validate_environment() {
    local missing=0

    if [ -z "${NSS_DB_DIR:-}" ]; then
        error "NSS_DB_DIR must be set"
        missing=1
    fi

    if [ -z "${NSS_PASSWORD:-}" ]; then
        error "NSS_PASSWORD must be set"
        missing=1
    fi

    if [ -z "${COMPONENT:-}" ]; then
        error "COMPONENT must be set (bridge, server, or client)"
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        fatal "Missing required environment variables"
    fi

    # Validate component type
    case "${COMPONENT}" in
        bridge|server|client)
            log "Component type: ${COMPONENT}"
            ;;
        *)
            fatal "Invalid COMPONENT: ${COMPONENT} (must be bridge, server, or client)"
            ;;
    esac
}

# Configuration with defaults
setup_configuration() {
    # Set FQDN based on component if not provided
    FQDN="${FQDN:-sigul-${COMPONENT}.example.org}"
    CA_SUBJECT="${CA_SUBJECT:-CN=Sigul CA}"
    KEY_SIZE="${KEY_SIZE:-2048}"
    VALIDITY_MONTHS="${VALIDITY_MONTHS:-120}"
    FORCE_CLEAN_DB="${FORCE_CLEAN_DB:-false}"
    CA_NICKNAME="sigul-ca"
    CERT_NICKNAME="sigul-${COMPONENT}-cert"

    log "Configuration:"
    log "  NSS DB Directory: ${NSS_DB_DIR}"
    log "  Component: ${COMPONENT}"
    log "  FQDN: ${FQDN}"
    log "  CA Subject: ${CA_SUBJECT}"
    log "  Key Size: ${KEY_SIZE}"
    log "  Validity: ${VALIDITY_MONTHS} months"
    log "  Force Clean DB: ${FORCE_CLEAN_DB}"
    log "  Debug Mode: ${DEBUG}"
}

# Create NSS database directory
create_nss_directory() {
    log "Creating NSS database directory..."

    if [ ! -d "${NSS_DB_DIR}" ]; then
        mkdir -p "${NSS_DB_DIR}"
        log "Created directory: ${NSS_DB_DIR}"
    else
        log "Directory already exists: ${NSS_DB_DIR}"
    fi

    chmod 755 "${NSS_DB_DIR}"
}

# Create NSS password file
create_password_file() {
    log "Creating NSS password file..."

    NSS_PASSWORD_FILE="${NSS_DB_DIR}/.nss-password"
    echo "${NSS_PASSWORD}" > "${NSS_PASSWORD_FILE}"
    chmod 600 "${NSS_PASSWORD_FILE}"

    log "Password file created: ${NSS_PASSWORD_FILE}"
}

# Create noise file for non-interactive certutil
create_noise_file() {
    log "Creating noise file for entropy..."

    NOISE_FILE="${NSS_DB_DIR}/.noise"
    
    # Generate noise from /dev/urandom
    if ! head -c 1024 /dev/urandom > "${NOISE_FILE}" 2>/dev/null; then
        fatal "Failed to create noise file"
    fi
    
    chmod 600 "${NOISE_FILE}"
    log "Noise file created: ${NOISE_FILE}"
}

# Clean existing NSS database if requested
clean_nss_database() {
    if [ "${FORCE_CLEAN_DB}" != "true" ]; then
        return 0
    fi

    log "Force cleaning NSS database..."

    if [ -f "${NSS_DB_DIR}/cert9.db" ]; then
        rm -f "${NSS_DB_DIR}/cert9.db"
        debug "Removed: ${NSS_DB_DIR}/cert9.db"
    fi

    if [ -f "${NSS_DB_DIR}/key4.db" ]; then
        rm -f "${NSS_DB_DIR}/key4.db"
        debug "Removed: ${NSS_DB_DIR}/key4.db"
    fi

    if [ -f "${NSS_DB_DIR}/pkcs11.txt" ]; then
        rm -f "${NSS_DB_DIR}/pkcs11.txt"
        debug "Removed: ${NSS_DB_DIR}/pkcs11.txt"
    fi

    success "NSS database cleaned"
}

# Initialize NSS database
initialize_nss_database() {
    log "Initializing NSS database (cert9.db format)..."

    # Check if database already exists
    if [ -f "${NSS_DB_DIR}/cert9.db" ]; then
        debug "NSS database already exists"
        
        # List existing certificates for debugging
        if [[ "$DEBUG" == "true" ]]; then
            debug "Existing certificates in database:"
            certutil -L -d "sql:${NSS_DB_DIR}" 2>/dev/null || debug "Could not list certificates"
        fi
        
        warn "NSS database already exists, skipping initialization"
        return 0
    fi

    if ! certutil -N -d "sql:${NSS_DB_DIR}" -f "${NSS_PASSWORD_FILE}" >/dev/null 2>&1; then
        fatal "Failed to initialize NSS database"
    fi

    success "NSS database initialized: ${NSS_DB_DIR}"
}

# Check if CA certificate exists
ca_exists() {
    certutil -L -d "sql:${NSS_DB_DIR}" -n "${CA_NICKNAME}" >/dev/null 2>&1
}

# Generate CA certificate
generate_ca_certificate() {
    if ca_exists; then
        log "CA certificate already exists: ${CA_NICKNAME}"
        return 0
    fi

    log "Generating CA certificate..."

    # Note: Omitting -m flag to let certutil auto-generate unique serial numbers.
    # Manual serial specification via -m flag is broken in some certutil versions
    # (e.g., Rocky Linux 9), where all serials become 0, causing SEC_ERROR_REUSED_ISSUER_AND_SERIAL.
    # Auto-generated serials work correctly and ensure uniqueness.

    # Generate self-signed CA certificate with noise file for non-interactive mode
    if ! certutil -S \
        -n "${CA_NICKNAME}" \
        -s "${CA_SUBJECT}" \
        -x \
        -t "CT,C,C" \
        -k rsa \
        -g "${KEY_SIZE}" \
        -z "${NOISE_FILE}" \
        -Z SHA256 \
        -v "${VALIDITY_MONTHS}" \
        -d "sql:${NSS_DB_DIR}" \
        -f "${NSS_PASSWORD_FILE}" \
        --keyUsage certSigning,crlSigning \
        2 2>&1; then
        fatal "Failed to generate CA certificate"
    fi

    success "CA certificate generated: ${CA_NICKNAME}"
}

# Export CA certificate for sharing
export_ca_certificate() {
    local ca_export_dir="${NSS_DB_DIR}/../ca-export"
    local ca_cert_file="${ca_export_dir}/ca.crt"

    log "Exporting CA certificate..."

    mkdir -p "${ca_export_dir}"
    chmod 755 "${ca_export_dir}"

    if ! certutil -L \
        -d "sql:${NSS_DB_DIR}" \
        -n "${CA_NICKNAME}" \
        -a \
        > "${ca_cert_file}" 2>/dev/null; then
        warn "Failed to export CA certificate"
        return 1
    fi

    chmod 644 "${ca_cert_file}"
    success "CA certificate exported: ${ca_cert_file}"
}

# Import CA certificate (for server/client components)
import_ca_certificate() {
    local ca_import_dir="${NSS_DB_DIR}/../ca-import"
    local ca_cert_file="${ca_import_dir}/ca.crt"

    if ca_exists; then
        log "CA certificate already imported: ${CA_NICKNAME}"
        return 0
    fi

    # For bridge component, CA should already exist (we just generated it)
    if [ "${COMPONENT}" = "bridge" ]; then
        return 0
    fi

    log "Importing CA certificate from bridge..."

    # Wait for CA certificate to be available
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if [ -f "${ca_cert_file}" ] && [ -s "${ca_cert_file}" ]; then
            log "CA certificate found"
            break
        fi

        if [ $attempt -eq 1 ]; then
            log "Waiting for CA certificate from bridge..."
        fi

        sleep 2
        attempt=$((attempt + 1))
    done

    if [ ! -f "${ca_cert_file}" ] || [ ! -s "${ca_cert_file}" ]; then
        fatal "CA certificate not found: ${ca_cert_file}"
    fi

    # Import CA certificate with trust flags
    if ! certutil -A \
        -d "sql:${NSS_DB_DIR}" \
        -n "${CA_NICKNAME}" \
        -t "CT,C,C" \
        -i "${ca_cert_file}" \
        -f "${NSS_PASSWORD_FILE}" \
        2>/dev/null; then
        fatal "Failed to import CA certificate"
    fi

    success "CA certificate imported: ${CA_NICKNAME}"
}

# Check if component certificate exists
component_cert_exists() {
    certutil -L -d "sql:${NSS_DB_DIR}" -n "${CERT_NICKNAME}" >/dev/null 2>&1
}

# Generate component certificate with FQDN and SAN
generate_component_certificate() {
    if component_cert_exists; then
        log "Component certificate already exists: ${CERT_NICKNAME}"
        return 0
    fi

    log "Generating ${COMPONENT} certificate with FQDN and SAN..."

    # Note: Omitting -m flag to let certutil auto-generate unique serial numbers.
    # Manual serial specification via -m flag is broken in some certutil versions
    # (e.g., Rocky Linux 9), where all serials become 0, causing SEC_ERROR_REUSED_ISSUER_AND_SERIAL.
    # Auto-generated serials work correctly and ensure uniqueness.

    # Generate certificate with:
    # - FQDN as CN
    # - SAN extension with DNS name
    # - Extended Key Usage: serverAuth + clientAuth
    # - Key Usage: digitalSignature + keyEncipherment
    if ! certutil -S \
        -n "${CERT_NICKNAME}" \
        -s "CN=${FQDN}" \
        -c "${CA_NICKNAME}" \
        -t "u,u,u" \
        -k rsa \
        -g "${KEY_SIZE}" \
        -z "${NOISE_FILE}" \
        -Z SHA256 \
        -v "${VALIDITY_MONTHS}" \
        -d "sql:${NSS_DB_DIR}" \
        -f "${NSS_PASSWORD_FILE}" \
        --extKeyUsage serverAuth,clientAuth \
        --keyUsage digitalSignature,keyEncipherment \
        -8 "${FQDN}" \
        2>&1; then
        fatal "Failed to generate ${COMPONENT} certificate"
    fi

    success "${COMPONENT} certificate generated: ${CERT_NICKNAME}"
}

# List certificates in database
list_certificates() {
    log "Certificates in NSS database:"
    echo ""
    certutil -L -d "sql:${NSS_DB_DIR}" || true
    echo ""
}

# Verify certificate
verify_certificate() {
    log "Verifying ${COMPONENT} certificate..."

    # Verify certificate can be used for SSL server authentication
    if certutil -V \
        -n "${CERT_NICKNAME}" \
        -u V \
        -d "sql:${NSS_DB_DIR}" \
        -f "${NSS_PASSWORD_FILE}" \
        >/dev/null 2>&1; then
        success "Certificate verification passed"
    else
        warn "Certificate verification failed (may be expected in isolated environment)"
    fi
}

# Display certificate details
show_certificate_details() {
    log "Certificate details:"
    echo ""
    certutil -L -n "${CERT_NICKNAME}" -d "sql:${NSS_DB_DIR}" 2>/dev/null || true
    echo ""
}

# Cleanup temporary files
cleanup() {
    if [ -f "${NSS_PASSWORD_FILE}" ]; then
        rm -f "${NSS_PASSWORD_FILE}"
        log "Cleaned up password file"
    fi
    
    if [ -f "${NOISE_FILE}" ]; then
        rm -f "${NOISE_FILE}"
        log "Cleaned up noise file"
    fi
}

# Main execution
main() {
    log "=== Production-Aligned Certificate Generation ==="
    log "Script version: 1.0.0"
    echo ""

    # Validate and setup
    validate_environment
    setup_configuration

    # Create NSS infrastructure
    create_nss_directory
    create_password_file
    create_noise_file

    # Clean database if requested
    clean_nss_database

    # Initialize NSS database if needed
    initialize_nss_database

    # Generate or import CA
    if [ "${COMPONENT}" = "bridge" ]; then
        generate_ca_certificate
        export_ca_certificate
    else
        import_ca_certificate
    fi

    # Generate component certificate
    generate_component_certificate

    # Verification
    list_certificates
    verify_certificate
    show_certificate_details

    # Cleanup
    cleanup

    echo ""
    success "=== Certificate generation complete ==="
    log "Component: ${COMPONENT}"
    log "FQDN: ${FQDN}"
    log "NSS Database: ${NSS_DB_DIR}"
    log "Database Format: cert9.db (modern)"
    log "Certificates:"
    log "  - CA: ${CA_NICKNAME} (trust: CT,C,C)"
    log "  - Component: ${CERT_NICKNAME} (trust: u,u,u)"
    echo ""
}

# Run main function
main