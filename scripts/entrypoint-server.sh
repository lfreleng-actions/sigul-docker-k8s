#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Server Entrypoint - Production-Aligned
#
# This script provides a simplified, production-aligned entrypoint for the Sigul server.
# It matches the direct invocation pattern used in production deployments.
#
# Production Pattern:
#   /usr/sbin/sigul_server -c /etc/sigul/server.conf
#
# Key Design Principles:
# - Minimal wrapper logic
# - Direct service invocation matching production
# - Fast startup with only essential validation
# - Clear, actionable error messages
# - Wait for bridge availability before starting

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# FHS-compliant paths
readonly CONFIG_FILE="/etc/sigul/server.conf"
readonly NSS_DIR="/etc/pki/sigul/server"
readonly DATA_DIR="/var/lib/sigul"
readonly SERVER_DATA_DIR="/var/lib/sigul/server"
readonly GNUPG_DIR="$SERVER_DATA_DIR/gnupg"

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] SERVER:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SERVER:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] SERVER:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] SERVER:${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

#######################################
# Bridge Availability Check
#######################################

wait_for_bridge() {
    log "Checking bridge availability..."

    # Extract bridge hostname and port from configuration
    local bridge_hostname bridge_port

    if ! bridge_hostname=$(grep "^bridge-hostname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        fatal "Cannot extract bridge-hostname from configuration"
    fi

    if ! bridge_port=$(grep "^bridge-port:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        fatal "Cannot extract bridge-port from configuration"
    fi

    if [ -z "$bridge_hostname" ]; then
        fatal "Bridge hostname not configured in $CONFIG_FILE"
    fi

    if [ -z "$bridge_port" ]; then
        fatal "Bridge port not configured in $CONFIG_FILE"
    fi

    log "Waiting for bridge at ${bridge_hostname}:${bridge_port}..."

    local max_wait=60
    local elapsed=0

    while ! nc -z "$bridge_hostname" "$bridge_port" 2>/dev/null; do
        if [ $elapsed -ge $max_wait ]; then
            error "Bridge not available after ${max_wait} seconds"
            error "Bridge hostname: $bridge_hostname"
            error "Bridge port: $bridge_port"
            fatal "Cannot connect to bridge"
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    success "Bridge is available at ${bridge_hostname}:${bridge_port}"
}

#######################################
# Pre-flight Validation
#######################################

validate_configuration() {
    log "Validating server configuration..."

    # Check configuration file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        fatal "Configuration not found at $CONFIG_FILE"
    fi

    # Verify configuration is readable
    if [ ! -r "$CONFIG_FILE" ]; then
        fatal "Configuration file $CONFIG_FILE is not readable"
    fi

    success "Configuration file validated"
}

validate_nss_database() {
    log "Validating NSS database..."

    # Check NSS directory exists
    if [ ! -d "$NSS_DIR" ]; then
        fatal "NSS database directory not found at $NSS_DIR"
    fi

    # Check for cert9.db (modern NSS format)
    if [ ! -f "$NSS_DIR/cert9.db" ]; then
        error "NSS database not found at $NSS_DIR/cert9.db"
        error ""
        error "This typically means the cert-init container did not run successfully."
        error "Please check:"
        error "  1. The cert-init container completed successfully"
        error "  2. Environment variable NSS_PASSWORD is set"
        error "  3. Volumes are properly mounted"
        error ""
        error "To force certificate regeneration, use:"
        error "  CERT_INIT_MODE=force docker compose up"
        fatal "Cannot start server without certificates"
    fi

    success "NSS database validated"
}

validate_certificate() {
    log "Validating server certificate..."

    # Extract certificate nickname from configuration
    local cert_nickname
    if ! cert_nickname=$(grep "^server-cert-nickname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        fatal "Cannot extract server-cert-nickname from configuration"
    fi

    if [ -z "$cert_nickname" ]; then
        fatal "Server certificate nickname not configured in $CONFIG_FILE"
    fi

    # Verify certificate exists in NSS database
    if ! certutil -L -d "sql:$NSS_DIR" -n "$cert_nickname" &>/dev/null; then
        error "Certificate '$cert_nickname' not found in NSS database"
        error ""
        error "Available certificates in database:"
        certutil -L -d "sql:$NSS_DIR" | tail -n +4 | awk '{print "  - " $1}' 2>/dev/null || echo "  (none)"
        error ""
        error "This suggests the cert-init container ran but certificate generation failed."
        error "Try regenerating certificates with:"
        error "  CERT_INIT_MODE=force docker compose up"
        fatal "Required certificate missing"
    fi

    success "Server certificate '$cert_nickname' validated"
}

validate_ca_certificate() {
    log "Validating CA certificate..."

    # Extract CA nickname from configuration
    local ca_nickname
    if ! ca_nickname=$(grep "^server-ca-cert-nickname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        warn "Cannot extract server-ca-cert-nickname from configuration, assuming 'sigul-ca'"
        ca_nickname="sigul-ca"
    fi

    if [ -z "$ca_nickname" ]; then
        ca_nickname="sigul-ca"
    fi

    # Verify CA certificate exists in NSS database
    if ! certutil -L -d "sql:$NSS_DIR" -n "$ca_nickname" &>/dev/null; then
        error "CA certificate '$ca_nickname' not found in NSS database"
        error ""
        error "The CA certificate is essential for TLS trust between components."
        error "This suggests incomplete certificate initialization."
        error "Try regenerating certificates with:"
        error "  CERT_INIT_MODE=force docker compose up"
        fatal "CA certificate is required for TLS trust"
    fi

    success "CA certificate '$ca_nickname' validated"
}

initialize_gnupg_directory() {
    log "Initializing GnuPG directory..."

    if [ ! -d "$GNUPG_DIR" ]; then
        log "Creating GnuPG directory at $GNUPG_DIR"
        mkdir -p "$GNUPG_DIR"
        chmod 700 "$GNUPG_DIR"
        success "GnuPG directory created"
    else
        log "GnuPG directory already exists"
    fi
}

initialize_directories() {
    log "Initializing runtime directories..."

    # Ensure data directory exists
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR"
        chmod 755 "$DATA_DIR"
    fi

    # Ensure server data directory exists
    if [ ! -d "$SERVER_DATA_DIR" ]; then
        log "Creating server data directory at $SERVER_DATA_DIR"
        mkdir -p "$SERVER_DATA_DIR"
        chmod 755 "$SERVER_DATA_DIR"
    fi

    success "Runtime directories initialized"
}

initialize_database() {
    log "Initializing database..."

    # Extract database path from configuration
    local db_path
    if ! db_path=$(grep "^database-path:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        warn "Cannot extract database-path from configuration, using default"
        db_path="/var/lib/sigul/server.sqlite"
    fi

    if [ -z "$db_path" ]; then
        warn "Database path not configured, using default"
        db_path="/var/lib/sigul/server.sqlite"
    fi

    log "Database path: $db_path"

    # Ensure database directory exists
    local db_dir
    db_dir=$(dirname "$db_path")
    if [ ! -d "$db_dir" ]; then
        log "Creating database directory at $db_dir"
        mkdir -p "$db_dir"
        chmod 755 "$db_dir"
    fi

    # Create empty database file if it doesn't exist
    # Sigul will initialize the schema on first run
    if [ ! -f "$db_path" ]; then
        log "Creating database file at $db_path"
        touch "$db_path"
        chmod 644 "$db_path"
        success "Database file created (schema will be initialized by Sigul)"
    else
        log "Database file already exists"
    fi
}

#######################################
# Service Startup
#######################################

start_server_service() {
    log "Starting Sigul Server service..."
    log "Command: /usr/sbin/sigul_server -c $CONFIG_FILE"
    log "Configuration: $CONFIG_FILE"

    success "Server initialized successfully"

    # Execute server service with production-aligned command
    # Using exec to replace shell process with server process
    exec /usr/sbin/sigul_server \
        -c "$CONFIG_FILE"
}

#######################################
# Main Entrypoint
#######################################

main() {
    log "Sigul Server Entrypoint (Production-Aligned)"
    log "============================================="

    # Run pre-flight validation
    validate_configuration
    validate_nss_database
    validate_certificate
    validate_ca_certificate

    # Wait for bridge to be available
    wait_for_bridge

    # Initialize required directories
    initialize_gnupg_directory
    initialize_directories
    initialize_database

    # Start the service
    start_server_service
}

# Execute main function
main "$@"
