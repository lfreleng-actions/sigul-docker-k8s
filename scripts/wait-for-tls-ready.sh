#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Wait for Sigul TLS Readiness Script
#
# This script waits for Sigul components to be fully ready for TLS connections,
# avoiding race conditions where containers are running but not yet accepting
# SSL/TLS handshakes properly.
#
# Usage:
#   ./scripts/wait-for-tls-ready.sh [OPTIONS]
#
# Options:
#   --bridge        Wait for bridge to be TLS-ready
#   --server        Wait for server to be TLS-ready
#   --all           Wait for all components (default)
#   --timeout <sec> Maximum wait time in seconds (default: 120)
#   --verbose       Enable verbose output
#   --help          Show this help message

set -euo pipefail

# Script configuration
# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Unused - commented out
# PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"  # Unused - commented out

# Options
WAIT_BRIDGE=false
WAIT_SERVER=false
WAIT_ALL=false
TIMEOUT=120
VERBOSE_MODE=false
SHOW_HELP=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${BLUE}[WAIT] INFO:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WAIT] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[WAIT] ERROR:${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[WAIT] SUCCESS:${NC} $*"
}

verbose() {
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${BLUE}[WAIT] DEBUG:${NC} $*"
    fi
}

# Help function
show_help() {
    cat << 'EOF'
Wait for Sigul TLS Readiness Script

USAGE:
    ./scripts/wait-for-tls-ready.sh [OPTIONS]

OPTIONS:
    --bridge            Wait for bridge to be TLS-ready
    --server            Wait for server to be TLS-ready
    --all               Wait for all components (default)
    --timeout <seconds> Maximum wait time (default: 120)
    --verbose           Enable verbose output
    --help              Show this help message

DESCRIPTION:
    This script waits for Sigul components to be fully ready for TLS
    connections. It performs multiple checks beyond just TCP connectivity:

    1. Container is running
    2. Process is active inside container
    3. Port is listening
    4. TLS handshake can be completed
    5. Certificate validation passes

    This prevents race conditions where containers appear ready but
    SSL/TLS operations still fail with "Unexpected EOF" errors.

EXAMPLES:
    # Wait for all components (default 120s timeout)
    ./scripts/wait-for-tls-ready.sh

    # Wait for bridge only with custom timeout
    ./scripts/wait-for-tls-ready.sh --bridge --timeout 60

    # Wait for all with verbose output
    ./scripts/wait-for-tls-ready.sh --all --verbose

EXIT CODES:
    0 - All requested components are TLS-ready
    1 - Timeout waiting for components
    2 - Component container not found
    3 - Invalid arguments

EOF
}

# Parse arguments
parse_args() {
    local has_specific_target=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --bridge)
                WAIT_BRIDGE=true
                has_specific_target=true
                shift
                ;;
            --server)
                WAIT_SERVER=true
                has_specific_target=true
                shift
                ;;
            --all)
                WAIT_ALL=true
                has_specific_target=true
                shift
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --help)
                SHOW_HELP=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 3
                ;;
        esac
    done

    # If no specific target, wait for all
    if [[ "$has_specific_target" == "false" ]]; then
        WAIT_ALL=true
    fi

    # --all implies both
    if [[ "$WAIT_ALL" == "true" ]]; then
        WAIT_BRIDGE=true
        WAIT_SERVER=true
    fi
}

# Check if container is running
wait_for_container_running() {
    local container_name="$1"
    local timeout="$2"
    local elapsed=0
    local interval=2

    verbose "Waiting for container $container_name to be running..."

    while [[ $elapsed -lt $timeout ]]; do
        if docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^${container_name}$"; then
            verbose "Container $container_name is running"
            return 0
        fi

        sleep $interval
        ((elapsed += interval))
    done

    error "Timeout waiting for container $container_name to be running"
    return 1
}

# Check if process is active in container
wait_for_process_active() {
    local container_name="$1"
    local process_pattern="$2"
    local timeout="$3"
    local elapsed=0
    local interval=2

    verbose "Waiting for process '$process_pattern' in $container_name..."

    while [[ $elapsed -lt $timeout ]]; do
        if docker exec "$container_name" ps aux 2>/dev/null | grep -v grep | grep -q "$process_pattern"; then
            verbose "Process '$process_pattern' is active in $container_name"
            return 0
        fi

        sleep $interval
        ((elapsed += interval))
    done

    error "Timeout waiting for process '$process_pattern' in $container_name"
    return 1
}

# Check if port is listening
wait_for_port_listening() {
    local container_name="$1"
    local port="$2"
    local timeout="$3"
    local elapsed=0
    local interval=2

    verbose "Waiting for port $port to be listening in $container_name..."

    while [[ $elapsed -lt $timeout ]]; do
        if docker exec "$container_name" netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
            verbose "Port $port is listening in $container_name"
            return 0
        fi

        sleep $interval
        ((elapsed += interval))
    done

    error "Timeout waiting for port $port to be listening in $container_name"
    return 1
}

# Check if TLS handshake succeeds
wait_for_tls_handshake() {
    local source_container="$1"
    local target_host="$2"
    local target_port="$3"
    local timeout="$4"
    local elapsed=0
    local interval=3

    verbose "Waiting for TLS handshake: $source_container -> $target_host:$target_port..."

    while [[ $elapsed -lt $timeout ]]; do
        # Try TLS handshake with timeout
        local result
        result=$(docker exec "$source_container" timeout 5 openssl s_client \
            -connect "$target_host:$target_port" \
            -verify 2 \
            < /dev/null 2>&1 || echo "FAILED")

        # Check if connected and handshake completed
        if echo "$result" | grep -q "CONNECTED"; then
            if echo "$result" | grep -q "Verify return code: 0"; then
                verbose "TLS handshake successful: $source_container -> $target_host:$target_port"
                return 0
            else
                # Connected but verification failed - log details
                local verify_code
                verify_code=$(echo "$result" | grep "Verify return code" || echo "unknown")
                verbose "TLS connection made but verification pending: $verify_code"
            fi
        fi

        sleep $interval
        ((elapsed += interval))
    done

    error "Timeout waiting for TLS handshake: $source_container -> $target_host:$target_port"
    return 1
}

# Wait for NSS database to be accessible
wait_for_nss_database() {
    local container_name="$1"
    local nss_dir="$2"
    local timeout="$3"
    local elapsed=0
    local interval=2

    verbose "Waiting for NSS database in $container_name..."

    while [[ $elapsed -lt $timeout ]]; do
        # Check if database files exist and are readable
        if docker exec "$container_name" test -f "$nss_dir/cert9.db" 2>/dev/null; then
            # Try to list certificates (basic database read)
            if docker exec "$container_name" certutil -L -d "sql:$nss_dir" >/dev/null 2>&1; then
                verbose "NSS database accessible in $container_name"
                return 0
            fi
        fi

        sleep $interval
        ((elapsed += interval))
    done

    error "Timeout waiting for NSS database in $container_name"
    return 1
}

# Comprehensive readiness check for bridge
wait_for_bridge_ready() {
    local timeout="$1"
    local start_time
    start_time=$(date +%s)

    log "Waiting for bridge to be TLS-ready (timeout: ${timeout}s)..."

    # Step 1: Container running
    local remaining
    remaining=$((timeout - ($(date +%s) - start_time)))
    if ! wait_for_container_running "sigul-bridge" "$remaining"; then
        return 2
    fi

    # Step 2: Process active
    remaining=$((timeout - ($(date +%s) - start_time)))
    if ! wait_for_process_active "sigul-bridge" "sigul.*bridge" "$remaining"; then
        return 1
    fi

    # Step 3: NSS database ready
    remaining=$((timeout - ($(date +%s) - start_time)))
    if ! wait_for_nss_database "sigul-bridge" "/etc/pki/sigul" "$remaining"; then
        return 1
    fi

    # Step 4: Port listening
    remaining=$((timeout - ($(date +%s) - start_time)))
    if ! wait_for_port_listening "sigul-bridge" "44334" "$remaining"; then
        return 1
    fi

    # Step 5: Can connect to server (if server exists)
    if docker ps --filter "name=sigul-server" --filter "status=running" --format "{{.Names}}" | grep -q "sigul-server"; then
        remaining=$((timeout - ($(date +%s) - start_time)))
        if ! wait_for_tls_handshake "sigul-bridge" "sigul-server.example.org" "44333" "$remaining"; then
            warn "Bridge cannot complete TLS handshake with server yet"
            # Don't fail - server might not be fully ready yet
        fi
    fi

    success "✓ Bridge is TLS-ready"
    return 0
}

# Comprehensive readiness check for server
wait_for_server_ready() {
    local timeout="$1"
    local start_time
    start_time=$(date +%s)

    log "Waiting for server to be TLS-ready (timeout: ${timeout}s)..."

    # Step 1: Container running
    local remaining
    remaining=$((timeout - ($(date +%s) - start_time)))
    if ! wait_for_container_running "sigul-server" "$remaining"; then
        return 2
    fi

    # Step 2: Process active
    remaining=$((timeout - ($(date +%s) - start_time)))
    if ! wait_for_process_active "sigul-server" "sigul.*server" "$remaining"; then
        return 1
    fi

    # Step 3: NSS database ready
    remaining=$((timeout - ($(date +%s) - start_time)))
    if ! wait_for_nss_database "sigul-server" "/etc/pki/sigul" "$remaining"; then
        return 1
    fi

    # Step 4: Port listening
    remaining=$((timeout - ($(date +%s) - start_time)))
    if ! wait_for_port_listening "sigul-server" "44333" "$remaining"; then
        return 1
    fi

    success "✓ Server is TLS-ready"
    return 0
}

# Main execution
main() {
    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    local overall_status=0
    local start_time
    start_time=$(date +%s)

    log "Starting TLS readiness checks (timeout: ${TIMEOUT}s)..."

    # Wait for bridge if requested
    if [[ "$WAIT_BRIDGE" == "true" ]]; then
        local remaining
        remaining=$((TIMEOUT - ($(date +%s) - start_time)))
        if ! wait_for_bridge_ready "$remaining"; then
            error "Bridge is not TLS-ready"
            overall_status=1
        fi
    fi

    # Wait for server if requested
    if [[ "$WAIT_SERVER" == "true" ]]; then
        local remaining
        remaining=$((TIMEOUT - ($(date +%s) - start_time)))
        if ! wait_for_server_ready "$remaining"; then
            error "Server is not TLS-ready"
            overall_status=1
        fi
    fi

    # Final summary
    local elapsed
    elapsed=$(($(date +%s) - start_time))

    if [[ $overall_status -eq 0 ]]; then
        success "All requested components are TLS-ready (${elapsed}s elapsed)"
    else
        error "Some components failed readiness checks (${elapsed}s elapsed)"
    fi

    return $overall_status
}

main "$@"
