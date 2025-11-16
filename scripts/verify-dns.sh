#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# DNS Resolution Verification Script
#
# This script verifies that DNS resolution is working correctly for Sigul components.
# It checks hostname configuration, FQDN resolution, and network connectivity.
#
# Usage:
#   ./verify-dns.sh [component]
#
# Arguments:
#   component    Component to check (bridge|server) - default: server

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Default component
COMPONENT="${1:-server}"

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] DNS-VERIFY:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SUCCESS:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

# Validate component argument
validate_component() {
    case "$COMPONENT" in
        bridge|server)
            log "Validating DNS for component: $COMPONENT"
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

# Verify hostname configuration
verify_hostname() {
    log "Verifying hostname configuration..."

    local hostname
    hostname=$(docker exec "sigul-${COMPONENT}" hostname)
    local expected_hostname="sigul-${COMPONENT}.example.org"

    echo "  Container hostname: ${hostname}"
    echo "  Expected hostname:  ${expected_hostname}"

    if [ "${hostname}" = "${expected_hostname}" ]; then
        success "Hostname matches expected FQDN"
    else
        warn "Hostname mismatch detected"
        warn "  Expected: ${expected_hostname}"
        warn "  Got:      ${hostname}"
    fi
}

# Verify self-resolution
verify_self_resolution() {
    log "Verifying self-resolution..."

    local expected_hostname="sigul-${COMPONENT}.example.org"

    if docker exec "sigul-${COMPONENT}" getent hosts "${expected_hostname}" &>/dev/null; then
        local resolved
        resolved=$(docker exec "sigul-${COMPONENT}" getent hosts "${expected_hostname}")
        echo "  ${resolved}"
        success "Self-resolution successful"
    else
        error "Failed to resolve own FQDN: ${expected_hostname}"
        return 1
    fi
}

# Verify bridge resolution from server
verify_bridge_resolution() {
    if [ "${COMPONENT}" != "server" ]; then
        return 0
    fi

    log "Verifying bridge resolution from server..."

    if docker exec sigul-server getent hosts sigul-bridge.example.org &>/dev/null; then
        local resolved
        resolved=$(docker exec sigul-server getent hosts sigul-bridge.example.org)
        echo "  ${resolved}"
        success "Bridge resolution successful"
    else
        error "Failed to resolve bridge FQDN from server"
        return 1
    fi
}

# Test connectivity to bridge
verify_bridge_connectivity() {
    if [ "${COMPONENT}" != "server" ]; then
        return 0
    fi

    log "Testing connectivity to bridge..."

    if docker exec sigul-server nc -zv sigul-bridge.example.org 44333 2>&1 | grep -q "succeeded\|open"; then
        success "Bridge connectivity verified"
    else
        error "Cannot connect to bridge on port 44333"
        return 1
    fi
}

# Show /etc/hosts entries
show_hosts_file() {
    log "Showing /etc/hosts entries..."

    echo ""
    docker exec "sigul-${COMPONENT}" cat /etc/hosts | grep -v "^#" | grep -v "^$" | while read -r line; do
        echo "  ${line}"
    done
    echo ""
}

# Verify Docker DNS resolution
verify_docker_dns() {
    log "Verifying Docker DNS resolution..."

    local expected_hostname="sigul-${COMPONENT}.example.org"

    # Try nslookup (may not be available in all images)
    if docker exec "sigul-${COMPONENT}" which nslookup &>/dev/null; then
        echo ""
        docker exec "sigul-${COMPONENT}" nslookup "${expected_hostname}" 2>/dev/null || true
        echo ""
    else
        warn "nslookup not available in container (this is OK)"
    fi

    success "Docker DNS check completed"
}

# Verify short name resolution
verify_short_name() {
    log "Verifying short name resolution..."

    local short_name="sigul-${COMPONENT}"

    if docker exec "sigul-${COMPONENT}" getent hosts "${short_name}" &>/dev/null; then
        local resolved
        resolved=$(docker exec "sigul-${COMPONENT}" getent hosts "${short_name}")
        echo "  ${resolved}"
        success "Short name resolution successful"
    else
        warn "Short name resolution failed (may be OK if FQDN resolution works)"
    fi
}

# Verify network aliases
verify_network_aliases() {
    log "Verifying network aliases..."

    local container_id
    container_id=$(docker ps --filter "name=sigul-${COMPONENT}" --format "{{.ID}}")

    if [ -z "$container_id" ]; then
        error "Could not find container ID"
        return 1
    fi

    local aliases
    aliases=$(docker inspect "$container_id" \
        | jq -r '.[0].NetworkSettings.Networks.*.Aliases[]' 2>/dev/null || echo "")

    if [ -n "$aliases" ]; then
        echo "  Network aliases:"
        echo "$aliases" | while read -r alias; do
            echo "    - ${alias}"
        done
        success "Network aliases configured"
    else
        warn "No network aliases found"
    fi
}

# Check expected IP address
verify_static_ip() {
    log "Verifying static IP assignment..."

    local container_ip
    container_ip=$(docker inspect "sigul-${COMPONENT}" \
        | jq -r '.[0].NetworkSettings.Networks.*.IPAddress' 2>/dev/null)

    local expected_ip=""
    case "$COMPONENT" in
        bridge) expected_ip="172.20.0.2" ;;
        server) expected_ip="172.20.0.3" ;;
    esac

    echo "  Container IP:  ${container_ip}"
    echo "  Expected IP:   ${expected_ip}"

    if [ "${container_ip}" = "${expected_ip}" ]; then
        success "Static IP correctly assigned"
    else
        warn "IP address mismatch (dynamic assignment may be in use)"
    fi
}

# Run all verification checks
run_verification() {
    echo ""
    log "=== DNS Resolution Verification for ${COMPONENT} ==="
    echo ""

    local failed=false

    # Run checks
    check_container_running || failed=true
    echo ""

    verify_hostname || failed=true
    echo ""

    verify_self_resolution || failed=true
    echo ""

    verify_short_name || failed=true
    echo ""

    if [ "${COMPONENT}" = "server" ]; then
        verify_bridge_resolution || failed=true
        echo ""

        verify_bridge_connectivity || failed=true
        echo ""
    fi

    show_hosts_file

    verify_docker_dns || failed=true
    echo ""

    verify_network_aliases || failed=true
    echo ""

    verify_static_ip || failed=true
    echo ""

    # Summary
    if [ "$failed" = false ]; then
        success "=== DNS Verification Complete - All Checks Passed ==="
        return 0
    else
        error "=== DNS Verification Complete - Some Checks Failed ==="
        return 1
    fi
}

# Main function
main() {
    validate_component
    run_verification
}

# Execute main function
main "$@"
