#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Smart Certificate Initialization for Sigul Container Stack
# Pre-generates ALL certificates on the bridge during initialization
#
# This script implements proper PKI architecture where:
# - Bridge acts as the Certificate Authority
# - Bridge pre-generates certificates for: bridge, server, and client(s)
# - Only CA public certificate is distributed to other components
# - Client and server receive their own certificates WITHOUT CA private key
#
# Modes:
#   auto  - Smart detection: generate only if missing (default)
#   force - Force regeneration (DANGEROUS in production!)
#   skip  - Skip initialization entirely
#
# Usage:
#   CERT_INIT_MODE=auto ./cert-init.sh
#
# Environment Variables:
#   CERT_INIT_MODE      - Initialization mode: auto, force, skip (default: auto)
#   NSS_PASSWORD        - NSS database password (required)
#   BRIDGE_FQDN         - Bridge FQDN (default: sigul-bridge.example.org)
#   SERVER_FQDN         - Server FQDN (default: sigul-server.example.org)
#   CLIENT_FQDN         - Client FQDN (default: sigul-client.example.org)
#   CA_VALIDITY_MONTHS  - CA certificate validity in months (default: 120)
#   CERT_VALIDITY_MONTHS- Component cert validity in months (default: 120)
#   DEBUG               - Enable debug output (default: false)

set -euo pipefail

# Script version
readonly SCRIPT_VERSION="2.0.0"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Configuration with defaults
CERT_INIT_MODE="${CERT_INIT_MODE:-auto}"
NSS_PASSWORD="${NSS_PASSWORD:-}"
BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}"
SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}"
CLIENT_FQDN="${CLIENT_FQDN:-sigul-client.example.org}"
CA_VALIDITY_MONTHS="${CA_VALIDITY_MONTHS:-120}"
CERT_VALIDITY_MONTHS="${CERT_VALIDITY_MONTHS:-120}"
DEBUG="${DEBUG:-false}"

# FHS-compliant paths
readonly BRIDGE_NSS_DIR="/etc/pki/sigul/bridge"
readonly SERVER_NSS_DIR="/etc/pki/sigul/server"
readonly CLIENT_NSS_DIR="/etc/pki/sigul/client"
readonly SHARED_CONFIG_DIR="/etc/sigul"

# Export directories for certificate distribution (inside bridge NSS volume)
readonly CA_EXPORT_DIR="${BRIDGE_NSS_DIR}/ca-export"
readonly SERVER_EXPORT_DIR="${BRIDGE_NSS_DIR}/server-export"
readonly CLIENT_EXPORT_DIR="${BRIDGE_NSS_DIR}/client-export"

# Certificate nicknames (standardized)
readonly CA_NICKNAME="sigul-ca"
readonly BRIDGE_CERT_NICKNAME="sigul-bridge-cert"
readonly SERVER_CERT_NICKNAME="sigul-server-cert"
readonly CLIENT_CERT_NICKNAME="sigul-client-cert"

# Certificate generation parameters
readonly KEY_SIZE=2048
readonly CA_SERIAL=1
readonly CERT_SERIAL_BRIDGE=2
readonly CERT_SERIAL_SERVER=3
readonly CERT_SERIAL_CLIENT=4

# State tracking
INITIALIZATION_NEEDED=false
BRIDGE_CERTS_EXIST=false

#######################################
# Logging Functions
#######################################

log() {
    echo -e "${BLUE}[CERT-INIT]${NC} $*"
}

success() {
    echo -e "${GREEN}[CERT-INIT]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[CERT-INIT]${NC} $*"
}

error() {
    echo -e "${RED}[CERT-INIT]${NC} $*"
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${PURPLE}[CERT-INIT-DEBUG]${NC} $*"
    fi
}

fatal() {
    error "$*"
    exit 1
}

#######################################
# Validation Functions
#######################################

validate_environment() {
    log "Validating environment variables..."

    local validation_failed=0

    # Validate NSS password
    if [[ -z "$NSS_PASSWORD" ]]; then
        error "NSS_PASSWORD environment variable is required"
        validation_failed=1
    else
        debug "NSS_PASSWORD is set (length: ${#NSS_PASSWORD})"
    fi

    # Validate FQDNs
    if [[ -z "$BRIDGE_FQDN" ]]; then
        error "BRIDGE_FQDN environment variable is required"
        validation_failed=1
    else
        debug "BRIDGE_FQDN: $BRIDGE_FQDN"
    fi

    if [[ -z "$SERVER_FQDN" ]]; then
        error "SERVER_FQDN environment variable is required"
        validation_failed=1
    else
        debug "SERVER_FQDN: $SERVER_FQDN"
    fi

    if [[ -z "$CLIENT_FQDN" ]]; then
        error "CLIENT_FQDN environment variable is required"
        validation_failed=1
    else
        debug "CLIENT_FQDN: $CLIENT_FQDN"
    fi

    # Validate mode
    case "$CERT_INIT_MODE" in
        auto|force|skip)
            debug "CERT_INIT_MODE: $CERT_INIT_MODE"
            ;;
        *)
            error "Invalid CERT_INIT_MODE: $CERT_INIT_MODE"
            error "Valid modes: auto, force, skip"
            validation_failed=1
            ;;
    esac

    if [[ $validation_failed -eq 1 ]]; then
        fatal "Environment validation failed"
    fi

    success "Environment validation passed"
}

check_nss_database_exists() {
    local nss_dir="$1"
    local component="$2"

    debug "Checking NSS database at $nss_dir for $component"

    # Check for modern NSS format (cert9.db)
    if [[ ! -f "$nss_dir/cert9.db" ]] || [[ ! -f "$nss_dir/key4.db" ]]; then
        debug "NSS database files missing for $component"
        return 1
    fi

    debug "NSS database files exist for $component"
    return 0
}

check_certificate_exists() {
    local nss_dir="$1"
    local cert_nickname="$2"
    local component="$3"

    debug "Checking certificate '$cert_nickname' in $nss_dir for $component"

    # Check if certificate exists in NSS database
    if ! certutil -L -d "sql:$nss_dir" -n "$cert_nickname" &>/dev/null; then
        debug "Certificate '$cert_nickname' not found for $component"
        return 1
    fi

    debug "Certificate '$cert_nickname' exists for $component"
    return 0
}

detect_certificate_state() {
    log "Detecting certificate state on bridge..."

    # Check if bridge has ALL required certificates
    if check_nss_database_exists "$BRIDGE_NSS_DIR" "bridge" && \
       check_certificate_exists "$BRIDGE_NSS_DIR" "$CA_NICKNAME" "bridge" && \
       check_certificate_exists "$BRIDGE_NSS_DIR" "$BRIDGE_CERT_NICKNAME" "bridge" && \
       check_certificate_exists "$BRIDGE_NSS_DIR" "$SERVER_CERT_NICKNAME" "bridge" && \
       check_certificate_exists "$BRIDGE_NSS_DIR" "$CLIENT_CERT_NICKNAME" "bridge"; then
        BRIDGE_CERTS_EXIST=true
        success "All certificates exist on bridge (CA, bridge, server, client)"
        INITIALIZATION_NEEDED=false
    else
        BRIDGE_CERTS_EXIST=false
        warn "Certificates missing on bridge - initialization needed"
        INITIALIZATION_NEEDED=true
    fi
}

#######################################
# Certificate Generation Functions
#######################################

create_directories() {
    log "Creating certificate directories..."

    # Create NSS directories
    mkdir -p "$BRIDGE_NSS_DIR"
    mkdir -p "$SERVER_NSS_DIR"
    mkdir -p "$CLIENT_NSS_DIR"
    
    # Create export directories
    mkdir -p "$CA_EXPORT_DIR"
    mkdir -p "$SERVER_EXPORT_DIR"
    mkdir -p "$CLIENT_EXPORT_DIR"
    
    # Create shared config directory
    mkdir -p "$SHARED_CONFIG_DIR"

    # Set permissions
    chmod 755 "$BRIDGE_NSS_DIR" "$SERVER_NSS_DIR" "$CLIENT_NSS_DIR"
    chmod 755 "$CA_EXPORT_DIR" "$SERVER_EXPORT_DIR" "$CLIENT_EXPORT_DIR"
    chmod 755 "$SHARED_CONFIG_DIR"

    success "Directories created"
}

create_password_file() {
    log "Creating NSS password file..."

    local password_file="${BRIDGE_NSS_DIR}/.nss-password"
    echo "${NSS_PASSWORD}" > "${password_file}"
    chmod 600 "${password_file}"

    debug "Password file created: ${password_file}"
}

create_noise_file() {
    log "Creating noise file for entropy..."

    local noise_file="${BRIDGE_NSS_DIR}/.noise"
    head -c 1024 /dev/urandom > "${noise_file}" 2>/dev/null || fatal "Failed to create noise file"
    chmod 600 "${noise_file}"

    debug "Noise file created: ${noise_file}"
}

initialize_nss_database() {
    log "Initializing NSS database on bridge..."

    # Check if database already exists
    if [[ -f "${BRIDGE_NSS_DIR}/cert9.db" ]]; then
        if [[ "$CERT_INIT_MODE" == "force" ]]; then
            warn "Force mode: removing existing NSS database"
            rm -f "${BRIDGE_NSS_DIR}/cert9.db" "${BRIDGE_NSS_DIR}/key4.db" "${BRIDGE_NSS_DIR}/pkcs11.txt"
        else
            log "NSS database already exists"
            return 0
        fi
    fi

    # Create new NSS database
    local password_file="${BRIDGE_NSS_DIR}/.nss-password"
    if ! certutil -N -d "sql:${BRIDGE_NSS_DIR}" -f "${password_file}"; then
        fatal "Failed to initialize NSS database"
    fi

    success "NSS database initialized"
}

generate_ca_certificate() {
    log "Generating Certificate Authority (CA)..."

    local password_file="${BRIDGE_NSS_DIR}/.nss-password"
    local noise_file="${BRIDGE_NSS_DIR}/.noise"

    # Calculate validity in days
    local validity_days=$((CA_VALIDITY_MONTHS * 30))

    # Generate CA certificate
    if ! certutil -S \
        -d "sql:${BRIDGE_NSS_DIR}" \
        -n "${CA_NICKNAME}" \
        -s "CN=Sigul CA,O=Sigul Infrastructure,OU=Certificate Authority" \
        -t "CT,C,C" \
        -x \
        -m "${CA_SERIAL}" \
        -v "${validity_days}" \
        -g "${KEY_SIZE}" \
        -z "${noise_file}" \
        -f "${password_file}" \
        --keyUsage certSigning,crlSigning \
        -2 <<EOF
y
-1
y
EOF
    then
        fatal "Failed to generate CA certificate"
    fi

    success "CA certificate generated: ${CA_NICKNAME}"
}

generate_component_certificate() {
    local component="$1"
    local fqdn="$2"
    local cert_nickname="$3"
    local serial="$4"

    log "Generating ${component} certificate for ${fqdn}..."

    local password_file="${BRIDGE_NSS_DIR}/.nss-password"
    local noise_file="${BRIDGE_NSS_DIR}/.noise"
    local validity_days=$((CERT_VALIDITY_MONTHS * 30))

    # Generate certificate request and sign it with CA
    # Note: No -2 flag for non-CA certificates (basic constraints not needed)
    if ! certutil -S \
        -d "sql:${BRIDGE_NSS_DIR}" \
        -n "${cert_nickname}" \
        -s "CN=${fqdn},O=Sigul Infrastructure,OU=${component}" \
        -c "${CA_NICKNAME}" \
        -t "u,u,u" \
        -m "${serial}" \
        -v "${validity_days}" \
        -g "${KEY_SIZE}" \
        -z "${noise_file}" \
        -f "${password_file}" \
        --keyUsage digitalSignature,keyEncipherment \
        --extKeyUsage serverAuth,clientAuth \
        -8 "${fqdn}"; then
        fatal "Failed to generate ${component} certificate"
    fi

    success "${component} certificate generated: ${cert_nickname}"
}

export_ca_certificate() {
    log "Exporting CA public certificate..."

    # Export CA certificate (public only)
    if ! certutil -L \
        -d "sql:${BRIDGE_NSS_DIR}" \
        -n "${CA_NICKNAME}" \
        -a > "${CA_EXPORT_DIR}/ca.crt"; then
        fatal "Failed to export CA certificate"
    fi

    chmod 644 "${CA_EXPORT_DIR}/ca.crt"
    success "CA certificate exported to ${CA_EXPORT_DIR}/ca.crt"
}

export_server_certificate() {
    log "Exporting server certificate and private key..."

    local password_file="${BRIDGE_NSS_DIR}/.nss-password"
    local p12_file="${SERVER_EXPORT_DIR}/server-cert.p12"
    local cert_file="${SERVER_EXPORT_DIR}/server-cert.crt"

    # Export server certificate and key as PKCS#12
    if ! pk12util -o "${p12_file}" \
        -d "sql:${BRIDGE_NSS_DIR}" \
        -n "${SERVER_CERT_NICKNAME}" \
        -k "${password_file}" \
        -W "${NSS_PASSWORD}"; then
        fatal "Failed to export server certificate to PKCS#12"
    fi

    chmod 600 "${p12_file}"

    # Also export just the certificate in PEM format
    if ! certutil -L \
        -d "sql:${BRIDGE_NSS_DIR}" \
        -n "${SERVER_CERT_NICKNAME}" \
        -a > "${cert_file}"; then
        fatal "Failed to export server certificate"
    fi

    chmod 644 "${cert_file}"

    # Save the PKCS#12 password
    echo "${NSS_PASSWORD}" > "${SERVER_EXPORT_DIR}/server-cert.p12.password"
    chmod 600 "${SERVER_EXPORT_DIR}/server-cert.p12.password"

    success "Server certificate exported to ${SERVER_EXPORT_DIR}/"
}

export_client_certificate() {
    log "Exporting client certificate and private key..."

    local password_file="${BRIDGE_NSS_DIR}/.nss-password"
    local p12_file="${CLIENT_EXPORT_DIR}/client-cert.p12"
    local cert_file="${CLIENT_EXPORT_DIR}/client-cert.crt"

    # Export client certificate and key as PKCS#12
    if ! pk12util -o "${p12_file}" \
        -d "sql:${BRIDGE_NSS_DIR}" \
        -n "${CLIENT_CERT_NICKNAME}" \
        -k "${password_file}" \
        -W "${NSS_PASSWORD}"; then
        fatal "Failed to export client certificate to PKCS#12"
    fi

    chmod 600 "${p12_file}"

    # Also export just the certificate in PEM format
    if ! certutil -L \
        -d "sql:${BRIDGE_NSS_DIR}" \
        -n "${CLIENT_CERT_NICKNAME}" \
        -a > "${cert_file}"; then
        fatal "Failed to export client certificate"
    fi

    chmod 644 "${cert_file}"

    # Save the PKCS#12 password
    echo "${NSS_PASSWORD}" > "${CLIENT_EXPORT_DIR}/client-cert.p12.password"
    chmod 600 "${CLIENT_EXPORT_DIR}/client-cert.p12.password"

    success "Client certificate exported to ${CLIENT_EXPORT_DIR}/"
}

generate_bridge_config() {
    log "Generating bridge configuration..."

    local config_file="${SHARED_CONFIG_DIR}/bridge.conf"
    
    # Create config directory if needed
    mkdir -p "${SHARED_CONFIG_DIR}"
    chmod 755 "${SHARED_CONFIG_DIR}"

    # Generate configuration
    cat > "${config_file}" << EOF
# Sigul Bridge Configuration
# Auto-generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# This bridge acts as the Certificate Authority and pre-generates
# all certificates for the infrastructure.

[bridge]
server-listen-port: 44333
client-listen-port: 44334

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
# Bridge certificate for TLS
bridge-cert-nickname: ${BRIDGE_CERT_NICKNAME}
# CA certificate for validating client/server connections
bridge-ca-cert-nickname: ${CA_NICKNAME}
# NSS database location
nss-dir: ${BRIDGE_NSS_DIR}
nss-password: ${NSS_PASSWORD}
nss-min-tls: tls1.2

[gnupg]
gnupg-bin: /usr/bin/gpg2
gnupg-key-type: RSA
gnupg-key-length: 4096
gnupg-key-usage: sign

# Security notes:
# - Bridge is the Certificate Authority (has CA private key)
# - Bridge pre-generates certificates for server and client
# - Only CA public certificate is distributed to other components
EOF

    chmod 644 "${config_file}"
    success "Bridge configuration generated: ${config_file}"
}

generate_server_config() {
    log "Generating server configuration..."

    local config_file="${SHARED_CONFIG_DIR}/server.conf"
    
    # Create config directory if needed
    mkdir -p "${SHARED_CONFIG_DIR}"
    chmod 755 "${SHARED_CONFIG_DIR}"

    # Generate configuration
    cat > "${config_file}" << EOF
# Sigul Server Configuration
# Auto-generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# This server imports pre-generated certificates from bridge.
# Server does NOT have CA private key (security best practice).

[server]
bridge-hostname: ${BRIDGE_FQDN}
bridge-port: 44333

[database]
database-path: /var/lib/sigul/server/server.sqlite

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
# Server certificate for TLS
server-cert-nickname: ${SERVER_CERT_NICKNAME}
# CA certificate for validating bridge connections (public only)
server-ca-cert-nickname: ${CA_NICKNAME}
# NSS database location
nss-dir: ${SERVER_NSS_DIR}
nss-password: ${NSS_PASSWORD}
nss-min-tls: tls1.2

[gnupg]
gnupg-bin: /usr/bin/gpg2
gnupg-key-type: RSA
gnupg-key-length: 4096
gnupg-key-usage: sign

# Security notes:
# - Server imports pre-generated certificate from bridge
# - Server has CA public certificate only (for validation)
# - Server does NOT have CA private key
# - Server cannot sign new certificates
EOF

    chmod 644 "${config_file}"
    success "Server configuration generated: ${config_file}"
}

generate_all_certificates() {
    log "Starting comprehensive certificate generation..."

    create_directories
    create_password_file
    create_noise_file
    initialize_nss_database

    # Generate CA certificate
    generate_ca_certificate

    # Generate component certificates (all signed by CA)
    generate_component_certificate "bridge" "$BRIDGE_FQDN" "$BRIDGE_CERT_NICKNAME" "$CERT_SERIAL_BRIDGE"
    generate_component_certificate "server" "$SERVER_FQDN" "$SERVER_CERT_NICKNAME" "$CERT_SERIAL_SERVER"
    generate_component_certificate "client" "$CLIENT_FQDN" "$CLIENT_CERT_NICKNAME" "$CERT_SERIAL_CLIENT"

    # Export certificates for distribution
    export_ca_certificate
    export_server_certificate
    export_client_certificate

    # Generate configurations
    generate_bridge_config
    generate_server_config

    success "All certificates and configurations generated successfully"
}

#######################################
# Verification Functions
#######################################

verify_generated_certificates() {
    log "Verifying generated certificates..."

    local verification_failed=0

    # Verify bridge NSS database
    if ! check_nss_database_exists "$BRIDGE_NSS_DIR" "bridge"; then
        error "Bridge NSS database verification failed"
        verification_failed=1
    fi

    # Verify all certificates in bridge database
    for cert in "$CA_NICKNAME" "$BRIDGE_CERT_NICKNAME" "$SERVER_CERT_NICKNAME" "$CLIENT_CERT_NICKNAME"; do
        if ! check_certificate_exists "$BRIDGE_NSS_DIR" "$cert" "bridge"; then
            error "Certificate '$cert' verification failed"
            verification_failed=1
        else
            debug "Certificate '$cert' verified"
        fi
    done

    # Verify exported files
    local required_files=(
        "${CA_EXPORT_DIR}/ca.crt"
        "${SERVER_EXPORT_DIR}/server-cert.p12"
        "${SERVER_EXPORT_DIR}/server-cert.crt"
        "${SERVER_EXPORT_DIR}/server-cert.p12.password"
        "${CLIENT_EXPORT_DIR}/client-cert.p12"
        "${CLIENT_EXPORT_DIR}/client-cert.crt"
        "${CLIENT_EXPORT_DIR}/client-cert.p12.password"
    )

    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            error "Required export file missing: $file"
            verification_failed=1
        else
            debug "Export file exists: $file"
        fi
    done

    if [[ $verification_failed -eq 1 ]]; then
        fatal "Certificate verification failed"
    fi

    success "Certificate verification passed"
}

display_certificate_info() {
    log "Certificate generation summary:"
    echo ""
    echo "  Bridge NSS Database: ${BRIDGE_NSS_DIR}"
    echo "  Certificates generated:"
    echo "    - CA Certificate: ${CA_NICKNAME}"
    echo "    - Bridge Certificate: ${BRIDGE_CERT_NICKNAME} (${BRIDGE_FQDN})"
    echo "    - Server Certificate: ${SERVER_CERT_NICKNAME} (${SERVER_FQDN})"
    echo "    - Client Certificate: ${CLIENT_CERT_NICKNAME} (${CLIENT_FQDN})"
    echo ""
    echo "  Exported files:"
    echo "    CA (public only):      ${CA_EXPORT_DIR}/ca.crt"
    echo "    Server cert + key:     ${SERVER_EXPORT_DIR}/server-cert.p12"
    echo "    Client cert + key:     ${CLIENT_EXPORT_DIR}/client-cert.p12"
    echo ""
    echo "  Generated configurations:"
    echo "    Bridge config:         ${SHARED_CONFIG_DIR}/bridge.conf"
    echo "    Server config:         ${SHARED_CONFIG_DIR}/server.conf"
    echo ""
    echo "  Security notes:"
    echo "    ✓ CA private key remains ONLY on bridge"
    echo "    ✓ Server receives only its certificate + CA public cert"
    echo "    ✓ Client receives only its certificate + CA public cert"
    echo "    ✓ No component except bridge can sign certificates"
    echo ""
}

#######################################
# Main Execution
#######################################

main() {
    log "Sigul Certificate Initialization (v${SCRIPT_VERSION})"
    log "==========================================="
    log "Mode: ${CERT_INIT_MODE}"
    log ""

    # Validate environment
    validate_environment

    # Handle skip mode
    if [[ "$CERT_INIT_MODE" == "skip" ]]; then
        warn "SKIP mode: Certificate initialization skipped"
        exit 0
    fi

    # Detect existing certificate state
    detect_certificate_state

    # Handle force mode
    if [[ "$CERT_INIT_MODE" == "force" ]]; then
        warn "FORCE mode: Regenerating all certificates"
        INITIALIZATION_NEEDED=true
    fi

    # Generate certificates if needed
    if [[ "$INITIALIZATION_NEEDED" == "true" ]]; then
        log "Certificate initialization required"
        generate_all_certificates
        verify_generated_certificates
        display_certificate_info
        success "Certificate initialization completed successfully"
    else
        log "Certificates already exist and are valid"
        log "Use CERT_INIT_MODE=force to regenerate"
        display_certificate_info
        success "Certificate initialization skipped (certificates exist)"
    fi

    log ""
    log "Certificate initialization complete"
}

# Execute main function
main "$@"