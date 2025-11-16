#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Configuration Validation Script
#
# This script validates Sigul configuration files for correctness,
# checking syntax, required sections, and production alignment.
#
# Usage:
#   ./validate-configs.sh bridge
#   ./validate-configs.sh server
#   CONFIG_FILE=/path/to/config.conf ./validate-configs.sh bridge
#
# Arguments:
#   component - Component type: bridge or server
#
# Environment Variables:
#   CONFIG_FILE - Path to configuration file (default: /etc/sigul/<component>.conf)

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
VALIDATION_WARNINGS=0

# Logging functions
log() {
    echo -e "${BLUE}[CONFIG-VALIDATE]${NC} $*"
}

success() {
    echo -e "${GREEN}[✓]${NC} $*"
    VALIDATION_PASSED=$((VALIDATION_PASSED + 1))
}

warn() {
    echo -e "${YELLOW}[⚠]${NC} $*"
    VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
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
        fatal "Usage: $0 <component>\n  Where component is: bridge or server"
    fi

    case "${COMPONENT}" in
        bridge|server)
            log "Validating configuration for component: ${COMPONENT}"
            ;;
        *)
            fatal "Invalid component: ${COMPONENT} (must be bridge or server)"
            ;;
    esac
}

# Setup configuration
setup_configuration() {
    CONFIG_FILE="${CONFIG_FILE:-/etc/sigul/${COMPONENT}.conf}"

    log "Configuration:"
    log "  Component: ${COMPONENT}"
    log "  Config file: ${CONFIG_FILE}"
    echo ""
}

# Check file exists
check_file_exists() {
    log "=== File Existence Check ==="

    if [ ! -f "${CONFIG_FILE}" ]; then
        error "Configuration file not found: ${CONFIG_FILE}"
        return 1
    fi
    success "Configuration file exists"

    if [ ! -r "${CONFIG_FILE}" ]; then
        error "Configuration file is not readable"
        return 1
    fi
    success "Configuration file is readable"

    echo ""
}

# Check file permissions
check_file_permissions() {
    log "=== File Permissions Check ==="

    local perms
    perms=$(stat -c "%a" "${CONFIG_FILE}" 2>/dev/null || stat -f "%Lp" "${CONFIG_FILE}" 2>/dev/null || echo "unknown")

    if [ "${perms}" = "600" ]; then
        success "Configuration file has secure permissions: ${perms}"
    elif [ "${perms}" = "400" ]; then
        success "Configuration file has read-only permissions: ${perms}"
    else
        warn "Configuration file permissions may be too permissive: ${perms} (recommended: 600)"
    fi

    # Check ownership
    local owner
    owner=$(stat -c "%U:%G" "${CONFIG_FILE}" 2>/dev/null || stat -f "%Su:%Sg" "${CONFIG_FILE}" 2>/dev/null || echo "unknown")

    if [ "${owner}" = "sigul:sigul" ]; then
        success "Configuration file has correct ownership: ${owner}"
    else
        warn "Configuration file ownership should be sigul:sigul, found: ${owner}"
    fi

    echo ""
}

# Check configuration syntax
check_syntax() {
    log "=== Configuration Syntax Check ==="

    # Use Python to parse INI format
    if command -v python3 >/dev/null 2>&1; then
        if python3 << EOF
import configparser
import sys

try:
    config = configparser.ConfigParser()
    config.read('${CONFIG_FILE}')
    print(f"Configuration syntax valid: {len(config.sections())} sections found")
    sys.exit(0)
except Exception as e:
    print(f"Configuration parsing failed: {e}")
    sys.exit(1)
EOF
        then
            success "Configuration syntax is valid"
        else
            error "Configuration syntax validation failed"
            return 1
        fi
    else
        warn "Python3 not available, skipping syntax validation"
    fi

    echo ""
}

# Check required sections
check_required_sections() {
    log "=== Required Sections Check ==="

    local required_sections
    if [ "${COMPONENT}" = "bridge" ]; then
        required_sections=("bridge" "koji" "daemon" "nss")
    else
        required_sections=("server" "database" "gnupg" "daemon" "nss")
    fi

    for section in "${required_sections[@]}"; do
        if grep -q "^\[${section}\]" "${CONFIG_FILE}"; then
            success "Section found: [${section}]"
        else
            error "Required section missing: [${section}]"
        fi
    done

    echo ""
}

# Check NSS configuration
check_nss_configuration() {
    log "=== NSS Configuration Check ==="

    # Check nss-dir
    if grep -q "^nss-dir:" "${CONFIG_FILE}"; then
        local nss_dir
        nss_dir=$(grep "^nss-dir:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "NSS directory configured: ${nss_dir}"

        # Check if using FHS-compliant path
        if [ "${nss_dir}" = "/etc/pki/sigul" ]; then
            success "NSS directory uses FHS-compliant path"
        else
            warn "NSS directory not using FHS path /etc/pki/sigul: ${nss_dir}"
        fi
    else
        error "NSS directory (nss-dir) not configured"
    fi

    # Check nss-password (production pattern: embedded in config)
    if grep -q "^nss-password:" "${CONFIG_FILE}"; then
        success "NSS password embedded in config (production pattern)"

        local password_length
        password_length=$(grep "^nss-password:" "${CONFIG_FILE}" | cut -d: -f2- | xargs | wc -c)
        if [ "${password_length}" -gt 8 ]; then
            success "NSS password has sufficient length"
        else
            warn "NSS password may be too short"
        fi
    else
        error "NSS password (nss-password) not configured"
    fi

    # Check TLS version constraints
    if grep -q "^nss-min-tls:" "${CONFIG_FILE}"; then
        local min_tls
        min_tls=$(grep "^nss-min-tls:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Minimum TLS version configured: ${min_tls}"

        if [ "${min_tls}" = "tls1.2" ] || [ "${min_tls}" = "tls1.3" ]; then
            success "Using modern TLS version (1.2+)"
        else
            warn "TLS version may be outdated: ${min_tls}"
        fi
    else
        warn "Minimum TLS version (nss-min-tls) not configured"
    fi

    echo ""
}

# Check bridge-specific configuration
check_bridge_configuration() {
    log "=== Bridge Configuration Check ==="

    # Check certificate nickname
    if grep -q "^bridge-cert-nickname:" "${CONFIG_FILE}"; then
        local cert_nickname
        cert_nickname=$(grep "^bridge-cert-nickname:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Bridge certificate nickname configured: ${cert_nickname}"

        # Check if FQDN format
        if [[ "${cert_nickname}" == *.* ]]; then
            success "Certificate nickname uses FQDN format (production pattern)"
        else
            warn "Certificate nickname should use FQDN format: ${cert_nickname}"
        fi
    else
        error "Bridge certificate nickname (bridge-cert-nickname) not configured"
    fi

    # Check ports
    if grep -q "^client-listen-port:" "${CONFIG_FILE}"; then
        local client_port
        client_port=$(grep "^client-listen-port:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Client port configured: ${client_port}"
    else
        error "Client port (client-listen-port) not configured"
    fi

    if grep -q "^server-listen-port:" "${CONFIG_FILE}"; then
        local server_port
        server_port=$(grep "^server-listen-port:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Server port configured: ${server_port}"
    else
        error "Server port (server-listen-port) not configured"
    fi

    echo ""
}

# Check server-specific configuration
check_server_configuration() {
    log "=== Server Configuration Check ==="

    # Check certificate nickname
    if grep -q "^server-cert-nickname:" "${CONFIG_FILE}"; then
        local cert_nickname
        cert_nickname=$(grep "^server-cert-nickname:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Server certificate nickname configured: ${cert_nickname}"

        # Check if FQDN format
        if [[ "${cert_nickname}" == *.* ]]; then
            success "Certificate nickname uses FQDN format (production pattern)"
        else
            warn "Certificate nickname should use FQDN format: ${cert_nickname}"
        fi
    else
        error "Server certificate nickname (server-cert-nickname) not configured"
    fi

    # Check bridge connection
    if grep -q "^bridge-hostname:" "${CONFIG_FILE}"; then
        local bridge_hostname
        bridge_hostname=$(grep "^bridge-hostname:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Bridge hostname configured: ${bridge_hostname}"
    else
        error "Bridge hostname (bridge-hostname) not configured"
    fi

    if grep -q "^bridge-port:" "${CONFIG_FILE}"; then
        local bridge_port
        bridge_port=$(grep "^bridge-port:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Bridge port configured: ${bridge_port}"
    else
        error "Bridge port (bridge-port) not configured"
    fi

    # Check database path
    if grep -q "^database-path:" "${CONFIG_FILE}"; then
        local db_path
        db_path=$(grep "^database-path:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Database path configured: ${db_path}"

        # Check if using FHS-compliant path
        if [[ "${db_path}" == /var/lib/sigul/* ]]; then
            success "Database path uses FHS-compliant location"
        else
            warn "Database path not using FHS location /var/lib/sigul/: ${db_path}"
        fi
    else
        error "Database path (database-path) not configured"
    fi

    # Check GnuPG home
    if grep -q "^gnupg-home:" "${CONFIG_FILE}"; then
        local gnupg_home
        gnupg_home=$(grep "^gnupg-home:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "GnuPG home configured: ${gnupg_home}"

        # Check if using FHS-compliant path
        if [[ "${gnupg_home}" == /var/lib/sigul/* ]]; then
            success "GnuPG home uses FHS-compliant location"
        else
            warn "GnuPG home not using FHS location /var/lib/sigul/: ${gnupg_home}"
        fi
    else
        error "GnuPG home (gnupg-home) not configured"
    fi

    echo ""
}

# Check daemon configuration
check_daemon_configuration() {
    log "=== Daemon Configuration Check ==="

    # Check unix user
    if grep -q "^unix-user:" "${CONFIG_FILE}"; then
        local unix_user
        unix_user=$(grep "^unix-user:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Unix user configured: ${unix_user}"

        if [ "${unix_user}" = "sigul" ]; then
            success "Using production user: sigul"
        else
            warn "Unix user should be 'sigul', found: ${unix_user}"
        fi
    else
        error "Unix user (unix-user) not configured"
    fi

    # Check unix group
    if grep -q "^unix-group:" "${CONFIG_FILE}"; then
        local unix_group
        unix_group=$(grep "^unix-group:" "${CONFIG_FILE}" | cut -d: -f2- | xargs)
        success "Unix group configured: ${unix_group}"

        if [ "${unix_group}" = "sigul" ]; then
            success "Using production group: sigul"
        else
            warn "Unix group should be 'sigul', found: ${unix_group}"
        fi
    else
        error "Unix group (unix-group) not configured"
    fi

    echo ""
}

# Show summary
show_summary() {
    echo ""
    log "=== Validation Summary ==="
    echo ""

    log "Results:"
    log "  Passed: ${VALIDATION_PASSED} checks"
    log "  Warnings: ${VALIDATION_WARNINGS} checks"
    log "  Failed: ${VALIDATION_FAILED} checks"
    echo ""

    if [ $VALIDATION_FAILED -eq 0 ]; then
        if [ $VALIDATION_WARNINGS -eq 0 ]; then
            success "Configuration validation PASSED with no warnings"
            return 0
        else
            success "Configuration validation PASSED with ${VALIDATION_WARNINGS} warnings"
            return 0
        fi
    else
        error "Configuration validation FAILED with ${VALIDATION_FAILED} errors"
        return 1
    fi
}

# Main execution
main() {
    echo ""
    log "=== Configuration Validation Script ==="
    log "Version: 1.0.0"
    echo ""

    # Validate and setup
    validate_component
    setup_configuration

    # Run validation checks
    check_file_exists
    check_file_permissions
    check_syntax
    check_required_sections
    check_nss_configuration

    # Component-specific checks
    if [ "${COMPONENT}" = "bridge" ]; then
        check_bridge_configuration
    else
        check_server_configuration
    fi

    check_daemon_configuration

    # Show summary
    show_summary
}

# Run main function
main
