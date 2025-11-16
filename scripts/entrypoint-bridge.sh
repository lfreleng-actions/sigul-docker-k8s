#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Bridge Entrypoint - Production-Aligned
#
# This script provides a simplified, production-aligned entrypoint for the Sigul bridge.
# It matches the direct invocation pattern used in production deployments.
#
# Production Pattern:
#   /usr/sbin/sigul_bridge
#
# Key Design Principles:
# - Minimal wrapper logic
# - Direct service invocation matching production
# - Fast startup with only essential validation
# - Clear, actionable error messages

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# FHS-compliant paths
readonly CONFIG_FILE="/etc/sigul/bridge.conf"
readonly NSS_DIR="/etc/pki/sigul/bridge"

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] BRIDGE:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] BRIDGE:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] BRIDGE:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] BRIDGE:${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

#######################################
# Pre-flight Validation
#######################################

validate_configuration() {
    log "Validating bridge configuration..."

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
        fatal "Cannot start bridge without certificates"
    fi

    success "NSS database validated"
}

validate_certificate() {
    log "Validating bridge certificate..."

    # Extract certificate nickname from configuration
    local cert_nickname
    if ! cert_nickname=$(grep "^bridge-cert-nickname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        fatal "Cannot extract bridge-cert-nickname from configuration"
    fi

    if [ -z "$cert_nickname" ]; then
        fatal "Bridge certificate nickname not configured in $CONFIG_FILE"
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

    success "Bridge certificate '$cert_nickname' validated"
}

validate_ca_certificate() {
    log "Validating CA certificate..."

    # Extract CA nickname from configuration
    local ca_nickname
    if ! ca_nickname=$(grep "^bridge-ca-cert-nickname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        warn "Cannot extract bridge-ca-cert-nickname from configuration, assuming 'sigul-ca'"
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

#######################################
# Service Startup
#######################################

start_bridge_service() {
    log "Starting Sigul Bridge service..."
    log "Command: /usr/sbin/sigul_bridge"
    log "Configuration: $CONFIG_FILE"

    success "Bridge initialized successfully"

    # Execute bridge service with production-aligned command
    # Using exec to replace shell process with bridge process
    exec /usr/sbin/sigul_bridge
}

#######################################
# Main Entrypoint
#######################################

main() {
    log "Sigul Bridge Entrypoint (Production-Aligned)"
    log "=============================================="

    # Run pre-flight validation
    validate_configuration
    validate_nss_database
    validate_certificate
    validate_ca_certificate

    # Start the service
    start_bridge_service
}

# Execute main function
main "$@"
