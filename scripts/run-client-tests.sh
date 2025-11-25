#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Unified Sigul Client Test Runner
#
# This script runs client tests in both CI and local environments.
# It automatically detects the environment and configures accordingly.
#
# Usage:
#   ./scripts/run-client-tests.sh [OPTIONS]
#
# Options:
#   --verbose           Enable verbose output
#   --network NAME      Docker network name (auto-detected if not specified)
#   --client-image IMG  Client image name (auto-detected if not specified)
#   --help              Show this help message
#
# Environment Variables (CI):
#   SIGUL_CLIENT_IMAGE      Client image name (e.g., "client-linux-amd64-image:test")
#   SIGUL_ADMIN_PASSWORD    Admin password (loaded from test-artifacts if not set)
#   SIGUL_NETWORK_NAME      Network name (auto-detected if not set)
#   CI                      Set to "true" in CI environments

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
VERBOSE_MODE=false
NETWORK_NAME=""
CLIENT_IMAGE=""
ADMIN_PASSWORD=""
SHOW_HELP=false

# Detect if we're in CI
IS_CI="${CI:-false}"

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

verbose() {
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $*"
    fi
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --network)
                NETWORK_NAME="$2"
                shift 2
                ;;
            --client-image)
                CLIENT_IMAGE="$2"
                shift 2
                ;;
            --help)
                SHOW_HELP=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Unified Sigul Client Test Runner

Usage: $0 [OPTIONS]

Options:
    --verbose           Enable verbose output
    --network NAME      Docker network name (auto-detected if not specified)
    --client-image IMG  Client image name (auto-detected if not specified)
    --help              Show this help message

Environment Variables:
    SIGUL_CLIENT_IMAGE      Client image name (overrides auto-detection)
    SIGUL_ADMIN_PASSWORD    Admin password (from deployment)
    SIGUL_NETWORK_NAME      Network name (overrides auto-detection)
    CI                      Set to "true" in CI environments

Examples:
    # Local development (auto-detect everything)
    ./scripts/run-client-tests.sh --verbose

    # CI environment (with explicit configuration)
    SIGUL_CLIENT_IMAGE="client-linux-amd64-image:test" \\
    SIGUL_ADMIN_PASSWORD="\$(cat test-artifacts/admin-password)" \\
        ./scripts/run-client-tests.sh --verbose

EOF
}

# Detect environment and load configuration
detect_environment() {
    log "Detecting environment..."

    if [[ "$IS_CI" == "true" ]]; then
        log "Running in CI environment"

        # In CI, we expect environment variables to be set
        if [[ -z "$CLIENT_IMAGE" ]] && [[ -n "${SIGUL_CLIENT_IMAGE:-}" ]]; then
            CLIENT_IMAGE="$SIGUL_CLIENT_IMAGE"
            verbose "Using client image from SIGUL_CLIENT_IMAGE: $CLIENT_IMAGE"
        fi

        if [[ -z "$NETWORK_NAME" ]] && [[ -n "${SIGUL_NETWORK_NAME:-}" ]]; then
            NETWORK_NAME="$SIGUL_NETWORK_NAME"
            verbose "Using network from SIGUL_NETWORK_NAME: $NETWORK_NAME"
        fi

        # Load admin password from test-artifacts in CI
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            if [[ -n "${SIGUL_ADMIN_PASSWORD:-}" ]]; then
                ADMIN_PASSWORD="$SIGUL_ADMIN_PASSWORD"
                verbose "Using admin password from SIGUL_ADMIN_PASSWORD"
            elif [[ -f "${PROJECT_ROOT}/test-artifacts/admin-password" ]]; then
                ADMIN_PASSWORD=$(cat "${PROJECT_ROOT}/test-artifacts/admin-password")
                verbose "Loaded admin password from test-artifacts/admin-password"
            else
                error "Admin password not found in CI environment"
                return 1
            fi
        fi
    else
        log "Running in local development environment"

        # In local development, auto-detect what we can
        if [[ -z "$CLIENT_IMAGE" ]]; then
            CLIENT_IMAGE=$(docker images --filter "reference=*sigul*client*" --format "{{.Repository}}:{{.Tag}}" | head -1 || echo "")
            if [[ -z "$CLIENT_IMAGE" ]]; then
                error "Could not auto-detect client image. Please specify with --client-image"
                return 1
            fi
            verbose "Auto-detected client image: $CLIENT_IMAGE"
        fi

        if [[ -z "$NETWORK_NAME" ]]; then
            NETWORK_NAME=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1 || echo "")
            if [[ -z "$NETWORK_NAME" ]]; then
                error "Could not auto-detect network. Please specify with --network"
                return 1
            fi
            verbose "Auto-detected network: $NETWORK_NAME"
        fi

        # Try to load password from test-artifacts, fall back to default
        if [[ -z "$ADMIN_PASSWORD" ]]; then
            if [[ -f "${PROJECT_ROOT}/test-artifacts/admin-password" ]]; then
                ADMIN_PASSWORD=$(cat "${PROJECT_ROOT}/test-artifacts/admin-password")
                verbose "Loaded admin password from test-artifacts/admin-password"
            else
                ADMIN_PASSWORD="auto_generated_ephemeral"
                verbose "Using default admin password: auto_generated_ephemeral"
            fi
        fi
    fi

    # Validate we have everything we need
    if [[ -z "$CLIENT_IMAGE" ]]; then
        error "Client image not specified and could not be auto-detected"
        return 1
    fi

    if [[ -z "$NETWORK_NAME" ]]; then
        error "Network name not specified and could not be auto-detected"
        return 1
    fi

    if [[ -z "$ADMIN_PASSWORD" ]]; then
        error "Admin password not available"
        return 1
    fi

    verbose "Configuration complete:"
    verbose "  Client Image: $CLIENT_IMAGE"
    verbose "  Network: $NETWORK_NAME"
    verbose "  Password: [set]"

    return 0
}

# Verify the stack is running
verify_stack() {
    log "Verifying Sigul stack is running..."

    if ! docker ps --format "{{.Names}}" | grep -q "sigul-server"; then
        error "Sigul server container is not running"
        return 1
    fi

    if ! docker ps --format "{{.Names}}" | grep -q "sigul-bridge"; then
        error "Sigul bridge container is not running"
        return 1
    fi

    verbose "✓ Server and bridge containers are running"

    # Check health status
    local server_health bridge_health
    server_health=$(docker inspect --format='{{.State.Health.Status}}' sigul-server 2>/dev/null || echo "unknown")
    bridge_health=$(docker inspect --format='{{.State.Health.Status}}' sigul-bridge 2>/dev/null || echo "unknown")

    verbose "  Server health: $server_health"
    verbose "  Bridge health: $bridge_health"

    if [[ "$server_health" != "healthy" ]] && [[ "$server_health" != "unknown" ]]; then
        warn "Server container is not healthy: $server_health"
    fi

    if [[ "$bridge_health" != "healthy" ]] && [[ "$bridge_health" != "unknown" ]]; then
        warn "Bridge container is not healthy: $bridge_health"
    fi

    return 0
}

# Run the client tests
run_tests() {
    log "Running client tests..."

    local test_script="${SCRIPT_DIR}/client-tests.sh"

    if [[ ! -f "$test_script" ]]; then
        error "Test script not found: $test_script"
        return 1
    fi

    if [[ ! -x "$test_script" ]]; then
        verbose "Making test script executable"
        chmod +x "$test_script"
    fi

    # Build arguments for the test script
    local test_args=()

    if [[ "$VERBOSE_MODE" == "true" ]]; then
        test_args+=("--verbose")
    fi

    test_args+=("--network" "$NETWORK_NAME")
    test_args+=("--client-image" "$CLIENT_IMAGE")
    test_args+=("--admin-password" "$ADMIN_PASSWORD")

    verbose "Executing: $test_script ${test_args[*]}"

    # Run the tests
    if "$test_script" "${test_args[@]}"; then
        success "Client tests completed successfully"
        return 0
    else
        error "Client tests failed"
        return 1
    fi
}

# Main function
main() {
    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    log "═══════════════════════════════════════════════════════════"
    log "  Sigul Client Test Runner"
    log "  Environment: $(if [[ "$IS_CI" == "true" ]]; then echo "CI"; else echo "Local"; fi)"
    log "═══════════════════════════════════════════════════════════"
    echo ""

    # Detect and configure environment
    if ! detect_environment; then
        error "Failed to detect environment configuration"
        exit 1
    fi

    # Verify stack is running
    if ! verify_stack; then
        error "Sigul stack verification failed"
        exit 1
    fi

    echo ""

    # Run the tests
    if run_tests; then
        echo ""
        success "═══════════════════════════════════════════════════════════"
        success "  All client tests passed!"
        success "═══════════════════════════════════════════════════════════"
        exit 0
    else
        echo ""
        error "═══════════════════════════════════════════════════════════"
        error "  Client tests failed!"
        error "═══════════════════════════════════════════════════════════"
        exit 1
    fi
}

# Execute main
main "$@"
