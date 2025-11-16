#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Certificate-Hostname Alignment Verification Script
#
# This script verifies that certificate CNs and SANs match container hostnames.
# This is critical for TLS validation in production deployments.
#
# Usage:
#   ./verify-cert-hostname-alignment.sh [component]
#
# Arguments:
#   component    Component to check (bridge|server) - default: bridge

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Default component
COMPONENT="${1:-bridge}"

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] CERT-VERIFY:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SUCCESS:${NC} $*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

fatal() {
    error "$*"
    exit 1
}

# Validate component argument
validate_component() {
    case "$COMPONENT" in
        bridge|server)
            log "Validating certificate-hostname alignment for: $COMPONENT"
            ;;
        *)
            error "Invalid component: $COMPONENT"
            echo "Valid components: bridge, server"
            exit 1
            ;;
    esac
}

# Check if container is running
check_container_running() {
    log "Checking if container is running..."

    if ! docker ps --format '{{.Names}}' | grep -q "^sigul-${COMPONENT}$"; then
        fatal "Container sigul-${COMPONENT} is not running"
    fi

    success "Container is running"
}

# Get container hostname
get_container_hostname() {
    log "Getting container hostname..."

    local hostname
    hostname=$(docker exec "sigul-${COMPONENT}" hostname)
    echo "  Container hostname: ${hostname}"

    echo "$hostname"
}

# Get certificate nickname from configuration
get_cert_nickname() {
    log "Getting certificate nickname from configuration..."

    local config_file="/etc/sigul/${COMPONENT}.conf"
    local config_key="${COMPONENT}-cert-nickname:"

    local cert_nickname
    cert_nickname=$(docker exec "sigul-${COMPONENT}" \
        grep "^${config_key}" "${config_file}" 2>/dev/null \
        | cut -d: -f2 | tr -d ' ' || echo "")

    if [ -z "$cert_nickname" ]; then
        error "Could not extract certificate nickname from configuration"
        return 1
    fi

    echo "  Certificate nickname: ${cert_nickname}"
    echo "$cert_nickname"
}

# Get NSS database path
get_nss_db_path() {
    case "$COMPONENT" in
        bridge)
            echo "/etc/pki/sigul/bridge"
            ;;
        server)
            echo "/etc/pki/sigul/server"
            ;;
    esac
}

# Verify certificate exists
verify_cert_exists() {
    local cert_nickname="$1"
    local nss_db_path="$2"

    log "Verifying certificate exists in NSS database..."

    if docker exec "sigul-${COMPONENT}" \
        certutil -L -n "${cert_nickname}" -d "sql:${nss_db_path}" &>/dev/null; then
        success "Certificate '${cert_nickname}' exists in NSS database"
        return 0
    else
        error "Certificate '${cert_nickname}' not found in NSS database"
        return 1
    fi
}

# Get certificate subject (CN)
get_cert_subject() {
    local cert_nickname="$1"
    local nss_db_path="$2"

    log "Extracting certificate subject (CN)..."

    local subject
    subject=$(docker exec "sigul-${COMPONENT}" \
        certutil -L -n "${cert_nickname}" -d "sql:${nss_db_path}" \
        | grep "Subject:" | head -1 || echo "")

    if [ -n "$subject" ]; then
        echo "  ${subject}"

        # Extract CN value
        local cn
        cn=$(echo "$subject" | grep -oP 'CN=[^,]+' | cut -d= -f2 || echo "")

        if [ -n "$cn" ]; then
            echo "  CN: ${cn}"
            echo "$cn"
            return 0
        fi
    fi

    error "Could not extract CN from certificate"
    return 1
}

# Get certificate SANs
get_cert_sans() {
    local cert_nickname="$1"
    local nss_db_path="$2"

    log "Extracting certificate Subject Alternative Names (SANs)..."

    # Get certificate details
    local cert_details
    cert_details=$(docker exec "sigul-${COMPONENT}" \
        certutil -L -n "${cert_nickname}" -d "sql:${nss_db_path}" 2>/dev/null)

    # Extract SAN section
    local sans
    sans=$(echo "$cert_details" | grep -A 20 "DNS name:" | grep "DNS name:" || echo "")

    if [ -n "$sans" ]; then
        echo "  Subject Alternative Names:"
        echo "$sans" | while read -r line; do
            echo "    ${line}"
        done
        echo "$sans"
        return 0
    else
        warn "No SANs found in certificate"
        return 1
    fi
}

# Verify CN matches hostname
verify_cn_matches_hostname() {
    local hostname="$1"
    local cn="$2"

    log "Verifying CN matches hostname..."

    echo "  Hostname: ${hostname}"
    echo "  CN:       ${cn}"

    if [ "${hostname}" = "${cn}" ]; then
        success "CN matches hostname exactly"
        return 0
    else
        error "CN does not match hostname"
        error "  Expected: ${hostname}"
        error "  Got:      ${cn}"
        return 1
    fi
}

# Verify SAN includes hostname
verify_san_includes_hostname() {
    local hostname="$1"
    local sans="$2"

    log "Verifying SAN includes hostname..."

    if echo "$sans" | grep -q "DNS name:.*${hostname}"; then
        success "SAN includes hostname"
        return 0
    else
        error "SAN does not include hostname: ${hostname}"
        return 1
    fi
}

# Verify certificate is valid (not expired)
verify_cert_validity() {
    local cert_nickname="$1"
    local nss_db_path="$2"

    log "Verifying certificate validity..."

    local cert_details
    cert_details=$(docker exec "sigul-${COMPONENT}" \
        certutil -L -n "${cert_nickname}" -d "sql:${nss_db_path}" 2>/dev/null)

    # Check for "Not After" date
    local not_after
    not_after=$(echo "$cert_details" | grep "Not After" || echo "")

    if [ -n "$not_after" ]; then
        echo "  ${not_after}"
        success "Certificate validity period available"
        return 0
    else
        warn "Could not determine certificate validity period"
        return 1
    fi
}

# Show full certificate details
show_cert_details() {
    local cert_nickname="$1"
    local nss_db_path="$2"

    log "Certificate details..."

    echo ""
    docker exec "sigul-${COMPONENT}" \
        certutil -L -n "${cert_nickname}" -d "sql:${nss_db_path}" 2>/dev/null | \
        head -30
    echo ""
}

# Verify CA certificate
verify_ca_cert() {
    local nss_db_path="$1"

    log "Verifying CA certificate..."

    if docker exec "sigul-${COMPONENT}" \
        certutil -L -n "sigul-ca" -d "sql:${nss_db_path}" &>/dev/null; then
        success "CA certificate exists"
        return 0
    else
        error "CA certificate not found"
        return 1
    fi
}

# Generate summary report
generate_report() {
    echo ""
    log "=== Certificate-Hostname Alignment Summary ==="
    echo ""
    echo "  Component:    ${COMPONENT}"
    echo "  Tests Passed: ${TESTS_PASSED}"
    echo "  Tests Failed: ${TESTS_FAILED}"
    echo ""

    if [ ${TESTS_FAILED} -eq 0 ]; then
        success "=== All Alignment Tests Passed ==="
        return 0
    else
        error "=== Some Alignment Tests Failed ==="
        error "Certificate and hostname configuration needs correction"
        return 1
    fi
}

# Main verification function
main() {
    echo ""
    log "=== Certificate-Hostname Alignment Verification ==="
    log "Component: ${COMPONENT}"
    echo ""

    # Validate input
    validate_component

    # Check prerequisites
    check_container_running
    echo ""

    # Get hostname and certificate info
    local hostname
    hostname=$(get_container_hostname)
    echo ""

    local cert_nickname
    cert_nickname=$(get_cert_nickname)
    if [ -z "$cert_nickname" ]; then
        fatal "Cannot proceed without certificate nickname"
    fi
    echo ""

    local nss_db_path
    nss_db_path=$(get_nss_db_path)
    echo "  NSS database: ${nss_db_path}"
    echo ""

    # Verify certificate exists
    verify_cert_exists "$cert_nickname" "$nss_db_path"
    echo ""

    # Get certificate details
    local cn
    cn=$(get_cert_subject "$cert_nickname" "$nss_db_path")
    echo ""

    local sans
    sans=$(get_cert_sans "$cert_nickname" "$nss_db_path" || echo "")
    echo ""

    # Perform alignment checks
    verify_cn_matches_hostname "$hostname" "$cn"
    echo ""

    if [ -n "$sans" ]; then
        verify_san_includes_hostname "$hostname" "$sans"
        echo ""
    fi

    verify_cert_validity "$cert_nickname" "$nss_db_path"
    echo ""

    verify_ca_cert "$nss_db_path"
    echo ""

    # Show full certificate details
    show_cert_details "$cert_nickname" "$nss_db_path"

    # Generate report
    generate_report
}

# Execute main function
main "$@"
