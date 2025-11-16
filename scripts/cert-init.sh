#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Smart Certificate Initialization for Sigul Container Stack
#
# This script provides intelligent certificate initialization that handles
# multiple deployment scenarios:
# - CI Testing: Fresh volumes, auto-generate certificates
# - Production First Deploy: Fresh volumes, auto-generate certificates
# - Production Restart: Existing volumes, skip regeneration
# - Volume Restore: Restored volumes, skip regeneration
# - Disaster Recovery: Force regeneration when needed
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
#   CA_VALIDITY_MONTHS  - CA certificate validity in months (default: 120)
#   CERT_VALIDITY_MONTHS- Component cert validity in months (default: 120)
#   DEBUG               - Enable debug output (default: false)

set -euo pipefail

# Script version
readonly SCRIPT_VERSION="1.0.0"

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
CA_VALIDITY_MONTHS="${CA_VALIDITY_MONTHS:-120}"
CERT_VALIDITY_MONTHS="${CERT_VALIDITY_MONTHS:-120}"
DEBUG="${DEBUG:-false}"

# FHS-compliant paths
readonly BRIDGE_NSS_DIR="/etc/pki/sigul/bridge"
readonly SERVER_NSS_DIR="/etc/pki/sigul/server"
readonly BRIDGE_CONFIG_DIR="/etc/sigul"
readonly SERVER_CONFIG_DIR="/etc/sigul"

# Certificate nicknames (standardized)
readonly CA_NICKNAME="sigul-ca"
readonly BRIDGE_CERT_NICKNAME="sigul-bridge-cert"
readonly SERVER_CERT_NICKNAME="sigul-server-cert"

# State tracking
INITIALIZATION_NEEDED=false
BRIDGE_CERTS_EXIST=false
SERVER_CERTS_EXIST=false

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

validate_directories() {
    log "Validating directory structure..."

    # Check if NSS directories exist
    for dir in "$BRIDGE_NSS_DIR" "$SERVER_NSS_DIR"; do
        if [[ ! -d "$dir" ]]; then
            warn "NSS directory does not exist: $dir"
            debug "Creating directory: $dir"
            mkdir -p "$dir"
            chmod 755 "$dir"
        fi
        debug "NSS directory exists: $dir"
    done

    # Check if config directories exist
    for dir in "$BRIDGE_CONFIG_DIR" "$SERVER_CONFIG_DIR"; do
        if [[ ! -d "$dir" ]]; then
            warn "Config directory does not exist: $dir"
            debug "Creating directory: $dir"
            mkdir -p "$dir"
            chmod 755 "$dir"
        fi
        debug "Config directory exists: $dir"
    done

    success "Directory structure validated"
}

#######################################
# Certificate State Detection
#######################################

check_nss_database_exists() {
    local nss_dir="$1"
    local component="$2"

    debug "Checking NSS database: $nss_dir"

    if [[ ! -f "$nss_dir/cert9.db" ]]; then
        debug "NSS database not found: $nss_dir/cert9.db"
        return 1
    fi

    if [[ ! -f "$nss_dir/key4.db" ]]; then
        debug "NSS key database not found: $nss_dir/key4.db"
        return 1
    fi

    debug "NSS database files exist for $component"
    return 0
}

check_certificate_exists() {
    local nss_dir="$1"
    local cert_nickname="$2"
    local component="$3"

    debug "Checking certificate '$cert_nickname' in $nss_dir"

    # Check if certificate exists in NSS database
    if ! certutil -L -d "sql:$nss_dir" -n "$cert_nickname" &>/dev/null; then
        debug "Certificate '$cert_nickname' not found for $component"
        return 1
    fi

    debug "Certificate '$cert_nickname' exists for $component"
    return 0
}

check_ca_certificate_exists() {
    local nss_dir="$1"
    local component="$2"

    debug "Checking CA certificate in $nss_dir"

    # Check if CA certificate exists in NSS database
    if ! certutil -L -d "sql:$nss_dir" -n "$CA_NICKNAME" &>/dev/null; then
        debug "CA certificate not found for $component"
        return 1
    fi

    debug "CA certificate exists for $component"
    return 0
}

detect_certificate_state() {
    log "Detecting certificate state..."

    # Check bridge certificates
    if check_nss_database_exists "$BRIDGE_NSS_DIR" "bridge" && \
       check_ca_certificate_exists "$BRIDGE_NSS_DIR" "bridge" && \
       check_certificate_exists "$BRIDGE_NSS_DIR" "$BRIDGE_CERT_NICKNAME" "bridge"; then
        BRIDGE_CERTS_EXIST=true
        success "Bridge certificates exist and are valid"
    else
        BRIDGE_CERTS_EXIST=false
        warn "Bridge certificates missing or incomplete"
    fi

    # Check server certificates
    if check_nss_database_exists "$SERVER_NSS_DIR" "server" && \
       check_ca_certificate_exists "$SERVER_NSS_DIR" "server" && \
       check_certificate_exists "$SERVER_NSS_DIR" "$SERVER_CERT_NICKNAME" "server"; then
        SERVER_CERTS_EXIST=true
        success "Server certificates exist and are valid"
    else
        SERVER_CERTS_EXIST=false
        warn "Server certificates missing or incomplete"
    fi

    # Determine if initialization is needed
    if [[ "$BRIDGE_CERTS_EXIST" == "true" ]] && [[ "$SERVER_CERTS_EXIST" == "true" ]]; then
        INITIALIZATION_NEEDED=false
        log "All certificates exist - initialization not needed"
    else
        INITIALIZATION_NEEDED=true
        log "Certificates missing - initialization needed"
    fi
}

#######################################
# Certificate Generation
#######################################

generate_certificates() {
    log "Starting certificate generation..."

    # Use production-aligned certificate generation script
    if [[ -x "/usr/local/bin/generate-production-aligned-certs.sh" ]]; then
        local cert_gen_script="/usr/local/bin/generate-production-aligned-certs.sh"
    elif [[ -x "/workspace/pki/generate-production-aligned-certs.sh" ]]; then
        local cert_gen_script="/workspace/pki/generate-production-aligned-certs.sh"
    else
        fatal "Certificate generation script not found"
    fi

    debug "Using certificate generation script: $cert_gen_script"

    # Generate bridge certificates (includes CA)
    log "Generating bridge certificates..."
    if NSS_DB_DIR="$BRIDGE_NSS_DIR" \
       NSS_PASSWORD="$NSS_PASSWORD" \
       COMPONENT="bridge" \
       FQDN="$BRIDGE_FQDN" \
       CA_SUBJECT="CN=Sigul CA" \
       VALIDITY_MONTHS="$CERT_VALIDITY_MONTHS" \
       "$cert_gen_script"; then
        success "Bridge certificates generated successfully"
    else
        fatal "Failed to generate bridge certificates"
    fi

    # Copy CA certificate and private key from bridge export to server import location
    log "Sharing CA certificate and private key from bridge to server..."
    local ca_export_path="/etc/pki/sigul/bridge/../ca-export/ca.crt"
    local ca_p12_export_path="/etc/pki/sigul/bridge/../ca-export/ca.p12"
    local ca_p12_password_export_path="/etc/pki/sigul/bridge/../ca-export/ca-p12-password"
    local ca_import_dir="/etc/pki/sigul/server/../ca-import"
    local ca_import_path="$ca_import_dir/ca.crt"
    local ca_p12_import_path="$ca_import_dir/ca.p12"
    local ca_p12_password_import_path="$ca_import_dir/ca-p12-password"

    if [[ ! -f "$ca_export_path" ]]; then
        error "Bridge CA certificate not found at: $ca_export_path"
        fatal "CA certificate export failed"
    fi

    if [[ ! -f "$ca_p12_export_path" ]]; then
        error "Bridge CA PKCS#12 file not found at: $ca_p12_export_path"
        fatal "CA PKCS#12 export failed"
    fi

    debug "Creating CA import directory: $ca_import_dir"
    mkdir -p "$ca_import_dir"
    chmod 700 "$ca_import_dir"

    debug "Copying CA certificate from bridge export to server import"
    if cp "$ca_export_path" "$ca_import_path"; then
        chmod 644 "$ca_import_path"
        success "CA certificate shared: bridge → server"
        debug "CA certificate available at: $ca_import_path"
    else
        fatal "Failed to copy CA certificate for server"
    fi

    debug "Copying CA PKCS#12 file from bridge export to server import"
    if cp "$ca_p12_export_path" "$ca_p12_import_path"; then
        chmod 600 "$ca_p12_import_path"
        debug "CA PKCS#12 file available at: $ca_p12_import_path"
    else
        fatal "Failed to copy CA PKCS#12 file for server"
    fi

    debug "Copying CA PKCS#12 password from bridge export to server import"
    if cp "$ca_p12_password_export_path" "$ca_p12_password_import_path"; then
        chmod 600 "$ca_p12_password_import_path"
        success "CA with private key shared: bridge → server"
        debug "CA PKCS#12 password available at: $ca_p12_password_import_path"
    else
        fatal "Failed to copy CA PKCS#12 password for server"
    fi

    # Generate server certificates (will import CA)
    log "Generating server certificates..."
    if NSS_DB_DIR="$SERVER_NSS_DIR" \
       NSS_PASSWORD="$NSS_PASSWORD" \
       COMPONENT="server" \
       FQDN="$SERVER_FQDN" \
       CA_SUBJECT="CN=Sigul CA" \
       VALIDITY_MONTHS="$CERT_VALIDITY_MONTHS" \
       "$cert_gen_script"; then
        success "Server certificates generated successfully"
    else
        fatal "Failed to generate server certificates"
    fi

    success "All certificates generated successfully"
}

verify_generated_certificates() {
    log "Verifying generated certificates..."

    local verification_failed=0

    # Verify bridge certificates
    if ! check_nss_database_exists "$BRIDGE_NSS_DIR" "bridge" || \
       ! check_ca_certificate_exists "$BRIDGE_NSS_DIR" "bridge" || \
       ! check_certificate_exists "$BRIDGE_NSS_DIR" "$BRIDGE_CERT_NICKNAME" "bridge"; then
        error "Bridge certificate verification failed"
        verification_failed=1
    else
        debug "Bridge certificates verified"
    fi

    # Verify server certificates
    if ! check_nss_database_exists "$SERVER_NSS_DIR" "server" || \
       ! check_ca_certificate_exists "$SERVER_NSS_DIR" "server" || \
       ! check_certificate_exists "$SERVER_NSS_DIR" "$SERVER_CERT_NICKNAME" "server"; then
        error "Server certificate verification failed"
        verification_failed=1
    else
        debug "Server certificates verified"
    fi

    if [[ $verification_failed -eq 1 ]]; then
        fatal "Certificate verification failed"
    fi

    success "Certificate verification passed"
}

#######################################
# Configuration Generation
#######################################

generate_bridge_config() {
    local config_file="$BRIDGE_CONFIG_DIR/bridge.conf"

    debug "Generating bridge configuration: $config_file"

    # Always generate fresh config to ensure correct values
    if [[ -f "$config_file" ]]; then
        debug "Bridge config exists, regenerating with current values"
    fi

    cat > "$config_file" << EOF
# Sigul Bridge Configuration (Production-Aligned)
# Auto-generated by cert-init.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

[bridge]
server-listen-port: 44333
client-listen-port: 44334

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
bridge-cert-nickname: $BRIDGE_CERT_NICKNAME
nss-dir: $BRIDGE_NSS_DIR
nss-password: $NSS_PASSWORD
nss-min-tls: tls1.2

[gnupg]
gnupg-bin: /usr/bin/gpg2
gnupg-key-type: RSA
gnupg-key-length: 4096
gnupg-key-usage: sign

# Bridge CA certificate for client/server authentication
bridge-ca-cert-nickname: $CA_NICKNAME
EOF

    chmod 644 "$config_file"
    success "Bridge configuration generated: $config_file"
}

generate_server_config() {
    local config_file="$SERVER_CONFIG_DIR/server.conf"

    debug "Generating server configuration: $config_file"

    # Always generate fresh config to ensure correct values
    if [[ -f "$config_file" ]]; then
        debug "Server config exists, regenerating with current values"
    fi

    cat > "$config_file" << EOF
# Sigul Server Configuration (Production-Aligned)
# Auto-generated by cert-init.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

[server]
bridge-hostname: $BRIDGE_FQDN
bridge-port: 44333

[database]
database-path: /var/lib/sigul/server.sqlite

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
server-cert-nickname: $SERVER_CERT_NICKNAME
nss-dir: $SERVER_NSS_DIR
nss-password: $NSS_PASSWORD
nss-min-tls: tls1.2

[gnupg]
gnupg-bin: /usr/bin/gpg2
gnupg-key-type: RSA
gnupg-key-length: 4096
gnupg-key-usage: sign

# Server CA certificate for bridge authentication
server-ca-cert-nickname: $CA_NICKNAME
EOF

    chmod 644 "$config_file"
    success "Server configuration generated: $config_file"
}

generate_configurations() {
    log "Generating configuration files..."

    generate_bridge_config
    generate_server_config

    success "Configuration files generated"
}

#######################################
# Mode Handlers
#######################################

handle_auto_mode() {
    log "Running in AUTO mode (smart detection)"

    detect_certificate_state

    if [[ "$INITIALIZATION_NEEDED" == "false" ]]; then
        success "✅ Certificates already exist - skipping initialization"
        success "Bridge: ✓ | Server: ✓"
        log "Mode: AUTO → SKIP (certificates present)"
        return 0
    else
        warn "🔧 Certificates missing or incomplete - initializing"
        log "Bridge: $([ "$BRIDGE_CERTS_EXIST" == "true" ] && echo "✓" || echo "✗") | Server: $([ "$SERVER_CERTS_EXIST" == "true" ] && echo "✓" || echo "✗")"
        log "Mode: AUTO → INITIALIZE (certificates missing)"

        generate_certificates
        verify_generated_certificates
        generate_configurations

        success "✅ Certificate initialization complete"
        return 0
    fi
}

handle_force_mode() {
    warn "⚠️  Running in FORCE mode (regenerating ALL certificates)"
    warn "⚠️  This will break existing trust chains!"
    warn "⚠️  Only use this for disaster recovery"

    log "Forcing certificate regeneration..."

    # Remove existing NSS databases
    log "Removing existing NSS databases..."
    rm -rf "$BRIDGE_NSS_DIR"/*.db 2>/dev/null || true
    rm -rf "$SERVER_NSS_DIR"/*.db 2>/dev/null || true

    generate_certificates
    verify_generated_certificates
    generate_configurations

    success "✅ Forced certificate regeneration complete"
    warn "⚠️  All components must be restarted with new certificates"
    return 0
}

handle_skip_mode() {
    log "Running in SKIP mode (no initialization)"
    success "⏭️  Skipping certificate initialization"
    log "Assuming certificates exist or will be provided externally"
    return 0
}

#######################################
# Main Execution
#######################################

print_banner() {
    log "=========================================="
    log "Sigul Certificate Initialization v${SCRIPT_VERSION}"
    log "=========================================="
    log "Mode: ${CERT_INIT_MODE^^}"
    log "Bridge FQDN: $BRIDGE_FQDN"
    log "Server FQDN: $SERVER_FQDN"
    log "Bridge NSS: $BRIDGE_NSS_DIR"
    log "Server NSS: $SERVER_NSS_DIR"
    log "=========================================="
}

print_summary() {
    log "=========================================="
    success "Certificate Initialization Complete"
    log "=========================================="
    log "Mode used: ${CERT_INIT_MODE^^}"
    log "Status: SUCCESS"
    log "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "=========================================="
}

main() {
    print_banner

    # Validate environment
    validate_environment
    validate_directories

    # Execute based on mode
    case "$CERT_INIT_MODE" in
        auto)
            handle_auto_mode
            ;;
        force)
            handle_force_mode
            ;;
        skip)
            handle_skip_mode
            ;;
        *)
            fatal "Invalid mode: $CERT_INIT_MODE"
            ;;
    esac

    print_summary
    exit 0
}

# Execute main function
main "$@"