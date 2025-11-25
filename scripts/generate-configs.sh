#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Configuration Generation Script
#
# This script generates sigul Sigul configuration files
# from templates, substituting environment-specific values.
#
# Usage:
#   NSS_PASSWORD=secret \
#   BRIDGE_FQDN=sigul-bridge.example.org \
#   SERVER_FQDN=sigul-server.example.org \
#   ./generate-configs.sh
#
# Environment Variables:
#   NSS_PASSWORD - NSS database password (required)
#   BRIDGE_FQDN - Bridge fully qualified domain name (default: sigul-bridge.example.org)
#   SERVER_FQDN - Server fully qualified domain name (default: sigul-server.example.org)
#   CLIENT_PORT - Bridge client port (default: 44334)
#   SERVER_PORT - Bridge server port (default: 44333)
#   BRIDGE_PORT - Server-to-bridge connection port (default: 44333)
#   TEMPLATE_DIR - Directory containing templates (default: ./configs)
#   OUTPUT_DIR - Directory for generated configs (default: ./configs)

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${BLUE}[CONFIG-GEN]${NC} $*"
}

success() {
    echo -e "${GREEN}[CONFIG-GEN]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[CONFIG-GEN]${NC} $*"
}

error() {
    echo -e "${RED}[CONFIG-GEN]${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

# Configuration with defaults
NSS_PASSWORD="${NSS_PASSWORD:-}"
BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}"
SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}"
CLIENT_PORT="${CLIENT_PORT:-44334}"
SERVER_PORT="${SERVER_PORT:-44333}"
BRIDGE_PORT="${BRIDGE_PORT:-44333}"
TEMPLATE_DIR="${TEMPLATE_DIR:-./configs}"
OUTPUT_DIR="${OUTPUT_DIR:-./configs}"

# Validate required variables
validate_environment() {
    log "Validating environment..."

    if [ -z "${NSS_PASSWORD}" ]; then
        fatal "NSS_PASSWORD must be set"
    fi

    if [ ${#NSS_PASSWORD} -lt 8 ]; then
        warn "NSS_PASSWORD should be at least 8 characters (current: ${#NSS_PASSWORD})"
    fi

    log "Environment validated"
}

# Check template files exist
check_templates() {
    log "Checking for template files..."

    if [ ! -f "${TEMPLATE_DIR}/bridge.conf.template" ]; then
        fatal "Bridge template not found: ${TEMPLATE_DIR}/bridge.conf.template"
    fi

    if [ ! -f "${TEMPLATE_DIR}/server.conf.template" ]; then
        fatal "Server template not found: ${TEMPLATE_DIR}/server.conf.template"
    fi

    success "Template files found"
}

# Create output directory
create_output_directory() {
    if [ ! -d "${OUTPUT_DIR}" ]; then
        log "Creating output directory: ${OUTPUT_DIR}"
        mkdir -p "${OUTPUT_DIR}"
    fi
}

# Generate bridge configuration
generate_bridge_config() {
    log "Generating bridge configuration..."

    local template="${TEMPLATE_DIR}/bridge.conf.template"
    local output="${OUTPUT_DIR}/bridge.conf"

    # Read template and substitute variables
    sed -e "s|\${NSS_PASSWORD}|${NSS_PASSWORD}|g" \
        -e "s|\${BRIDGE_FQDN}|${BRIDGE_FQDN}|g" \
        -e "s|\${CLIENT_PORT}|${CLIENT_PORT}|g" \
        -e "s|\${SERVER_PORT}|${SERVER_PORT}|g" \
        "${template}" > "${output}"

    # Set secure permissions
    chmod 600 "${output}"

    success "Bridge configuration generated: ${output}"
}

# Generate server configuration
generate_server_config() {
    log "Generating server configuration..."

    local template="${TEMPLATE_DIR}/server.conf.template"
    local output="${OUTPUT_DIR}/server.conf"

    # Read template and substitute variables
    sed -e "s|\${NSS_PASSWORD}|${NSS_PASSWORD}|g" \
        -e "s|\${SERVER_FQDN}|${SERVER_FQDN}|g" \
        -e "s|\${BRIDGE_FQDN}|${BRIDGE_FQDN}|g" \
        -e "s|\${BRIDGE_PORT}|${BRIDGE_PORT}|g" \
        "${template}" > "${output}"

    # Set secure permissions
    chmod 600 "${output}"

    success "Server configuration generated: ${output}"
}

# Verify generated configurations
verify_configurations() {
    log "Verifying generated configurations..."

    local bridge_conf="${OUTPUT_DIR}/bridge.conf"
    local server_conf="${OUTPUT_DIR}/server.conf"

    # Check files exist
    if [ ! -f "${bridge_conf}" ]; then
        error "Bridge configuration not generated"
        return 1
    fi

    if [ ! -f "${server_conf}" ]; then
        error "Server configuration not generated"
        return 1
    fi

    # Check NSS password is present (not template variable)
    if grep -q "\${NSS_PASSWORD}" "${bridge_conf}"; then
        error "Bridge config contains unsubstituted template variable"
        return 1
    fi

    if grep -q "\${NSS_PASSWORD}" "${server_conf}"; then
        error "Server config contains unsubstituted template variable"
        return 1
    fi

    # Verify NSS password is embedded
    if ! grep -q "nss-password: ${NSS_PASSWORD}" "${bridge_conf}"; then
        error "Bridge config does not contain NSS password"
        return 1
    fi

    if ! grep -q "nss-password: ${NSS_PASSWORD}" "${server_conf}"; then
        error "Server config does not contain NSS password"
        return 1
    fi

    # Check file permissions
    local bridge_perms
    bridge_perms=$(stat -c "%a" "${bridge_conf}" 2>/dev/null || stat -f "%Lp" "${bridge_conf}" 2>/dev/null)
    if [ "${bridge_perms}" != "600" ]; then
        warn "Bridge config permissions should be 600, found ${bridge_perms}"
    fi

    local server_perms
    server_perms=$(stat -c "%a" "${server_conf}" 2>/dev/null || stat -f "%Lp" "${server_conf}" 2>/dev/null)
    if [ "${server_perms}" != "600" ]; then
        warn "Server config permissions should be 600, found ${server_perms}"
    fi

    success "Configuration verification passed"
}

# Show summary
show_summary() {
    echo ""
    log "=== Configuration Generation Summary ==="
    log "Output directory: ${OUTPUT_DIR}"
    log "Files generated:"
    log "  - bridge.conf (permissions: 600)"
    log "  - server.conf (permissions: 600)"
    echo ""
    log "Configuration details:"
    log "  Bridge FQDN: ${BRIDGE_FQDN}"
    log "  Server FQDN: ${SERVER_FQDN}"
    log "  Client port: ${CLIENT_PORT}"
    log "  Server port: ${SERVER_PORT}"
    log "  Bridge port: ${BRIDGE_PORT}"
    echo ""
    log "NSS password length: ${#NSS_PASSWORD} characters"
    log "NSS password storage: Embedded in config files (production pattern)"
    echo ""
    success "Configuration generation complete!"
}

# Main execution
main() {
    log "=== Sigul Configuration Generation ==="
    log "Version: 1.0.0"
    echo ""

    validate_environment
    check_templates
    create_output_directory
    generate_bridge_config
    generate_server_config
    verify_configurations
    show_summary
}

# Run main function
main
