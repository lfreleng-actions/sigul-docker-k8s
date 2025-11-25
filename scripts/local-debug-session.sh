#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Local Debugging Session Script
#
# This script orchestrates a complete local debugging session for the Sigul
# container stack using the proper deployment mechanisms (not docker compose up).
#
# It handles:
# - Building images locally if needed
# - Deploying with proper initialization (admin passwords, etc)
# - Running comprehensive diagnostics
# - Setting up interactive debugging environment
#
# Usage:
#   ./scripts/local-debug-session.sh [OPTIONS]
#
# Options:
#   --clean         Remove all volumes and start fresh
#   --skip-build    Skip building images (use existing)
#   --skip-tests    Skip running diagnostics after deploy
#   --interactive   Keep containers running for manual debugging
#   --trace         Enable NSS/NSPR trace logging
#   --help          Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Options
CLEAN_START=false
SKIP_BUILD=false
SKIP_TESTS=false
INTERACTIVE=false
ENABLE_TRACE=false
SHOW_HELP=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
# CYAN='\033[0;36m'  # Unused - commented out
NC='\033[0m'

# Logging functions
log() {
    echo -e "${BLUE}[DEBUG SESSION]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[DEBUG SESSION]${NC} $*"
}

error() {
    echo -e "${RED}[DEBUG SESSION]${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[DEBUG SESSION]${NC} $*"
}

section() {
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}  $*${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Help function
show_help() {
    cat << 'EOF'
Local Debugging Session Script

USAGE:
    ./scripts/local-debug-session.sh [OPTIONS]

OPTIONS:
    --clean         Remove all volumes and start fresh
    --skip-build    Skip building images (use existing images)
    --skip-tests    Skip running diagnostics after deployment
    --interactive   Keep containers running for manual debugging
    --trace         Enable NSS/NSPR trace logging in containers
    --help          Show this help message

DESCRIPTION:
    This script orchestrates a complete local debugging session using
    proper deployment mechanisms (not direct docker compose up).

    It performs:
    1. Optional cleanup of existing deployment
    2. Building container images (if not skipped)
    3. Deploying infrastructure with proper initialization
       - Admin password generation and injection
       - NSS password management
       - Certificate setup
    4. Running comprehensive diagnostics
    5. Setting up interactive debugging environment

    The script uses deploy-sigul-infrastructure.sh which handles all
    proper initialization that docker compose up bypasses.

EXAMPLES:
    # Fresh start with full diagnostics
    ./scripts/local-debug-session.sh --clean

    # Quick test with existing images
    ./scripts/local-debug-session.sh --skip-build

    # Deploy and keep running for manual debugging
    ./scripts/local-debug-session.sh --interactive

    # Full debug session with trace logging
    ./scripts/local-debug-session.sh --clean --trace

    # Quick redeploy without tests
    ./scripts/local-debug-session.sh --skip-build --skip-tests

INTERACTIVE DEBUGGING:
    After deployment, you can:

    # View logs
    docker logs -f sigul-bridge
    docker logs -f sigul-server

    # Exec into containers
    docker exec -it sigul-bridge bash
    docker exec -it sigul-server bash

    # Run diagnostics
    ./scripts/debug-tls-stack.sh --all --verbose
    ./scripts/test-nss-isolation.sh --verbose

    # Check passwords
    cat test-artifacts/admin-password
    cat test-artifacts/nss-password

    # Manual TLS tests
    docker exec sigul-bridge openssl s_client \
      -connect sigul-server.example.org:44333 -showcerts

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean)
                CLEAN_START=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            --interactive)
                INTERACTIVE=true
                shift
                ;;
            --trace)
                ENABLE_TRACE=true
                shift
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

# Clean existing deployment
cleanup_deployment() {
    section "Cleaning Existing Deployment"

    log "Stopping and removing Sigul containers..."
    docker stop sigul-bridge sigul-server 2>/dev/null || true
    docker rm sigul-bridge sigul-server 2>/dev/null || true

    if [[ "$CLEAN_START" == "true" ]]; then
        log "Removing all Sigul volumes..."
        docker volume ls --filter "name=sigul" --format "{{.Name}}" | while read -r vol; do
            log "  Removing volume: $vol"
            docker volume rm "$vol" 2>/dev/null || true
        done

        log "Removing test artifacts..."
        rm -rf "${PROJECT_ROOT}/test-artifacts"

        success "Full cleanup completed"
    else
        log "Keeping existing volumes (use --clean for full cleanup)"
    fi

    # Clean any leftover integration test containers
    log "Cleaning integration test containers..."
    docker rm -f sigul-client-integration 2>/dev/null || true
}

# Detect platform
detect_platform() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "linux-amd64"
            ;;
        aarch64|arm64)
            echo "linux-arm64"
            ;;
        *)
            echo "linux-amd64"
            ;;
    esac
}

# Build container images
build_images() {
    section "Building Container Images"

    local platform_id
    platform_id=$(detect_platform)
    log "Building for platform: $platform_id"

    local platform_arg
    case "$platform_id" in
        linux-amd64)
            platform_arg="linux/amd64"
            ;;
        linux-arm64)
            platform_arg="linux/arm64"
            ;;
    esac

    # Build bridge
    log "Building bridge image..."
    if docker build --platform "$platform_arg" \
        -f "${PROJECT_ROOT}/Dockerfile.bridge" \
        -t "bridge-${platform_id}-image:test" \
        "${PROJECT_ROOT}"; then
        success "Bridge image built: bridge-${platform_id}-image:test"
    else
        error "Failed to build bridge image"
        return 1
    fi

    # Build server
    log "Building server image..."
    if docker build --platform "$platform_arg" \
        -f "${PROJECT_ROOT}/Dockerfile.server" \
        -t "server-${platform_id}-image:test" \
        "${PROJECT_ROOT}"; then
        success "Server image built: server-${platform_id}-image:test"
    else
        error "Failed to build server image"
        return 1
    fi

    # Build client (for integration tests)
    log "Building client image..."
    if docker build --platform "$platform_arg" \
        -f "${PROJECT_ROOT}/Dockerfile.client" \
        -t "client-${platform_id}-image:test" \
        "${PROJECT_ROOT}"; then
        success "Client image built: client-${platform_id}-image:test"
    else
        error "Failed to build client image"
        return 1
    fi

    success "All images built successfully"
}

# Deploy infrastructure using proper deployment script
deploy_infrastructure() {
    section "Deploying Sigul Infrastructure"

    log "Using deploy-sigul-infrastructure.sh for proper initialization..."
    log "This ensures admin passwords and NSS setup are handled correctly"

    # Set environment variables for deployment
    local platform_id
    platform_id=$(detect_platform)
    export SIGUL_SERVER_IMAGE="server-${platform_id}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-${platform_id}-image:test"
    export SIGUL_CLIENT_IMAGE="client-${platform_id}-image:test"
    export SIGUL_RUNNER_PLATFORM="$platform_id"

    case "$platform_id" in
        linux-amd64)
            export SIGUL_DOCKER_PLATFORM="linux/amd64"
            ;;
        linux-arm64)
            export SIGUL_DOCKER_PLATFORM="linux/arm64"
            ;;
    esac

    log "Environment configured:"
    log "  SIGUL_SERVER_IMAGE=$SIGUL_SERVER_IMAGE"
    log "  SIGUL_BRIDGE_IMAGE=$SIGUL_BRIDGE_IMAGE"
    log "  SIGUL_RUNNER_PLATFORM=$SIGUL_RUNNER_PLATFORM"

    # Run deployment script with debug and local-debug modes
    local deploy_args=(
        "--verbose"
        "--debug"
        "--local-debug"
    )

    if ! "${SCRIPT_DIR}/deploy-sigul-infrastructure.sh" "${deploy_args[@]}"; then
        error "Deployment failed!"
        error "Check logs above for details"
        return 1
    fi

    success "Infrastructure deployed successfully"
    return 0
}

# Wait for TLS readiness
wait_for_readiness() {
    section "Waiting for TLS Readiness"

    log "Using wait-for-tls-ready.sh to avoid race conditions..."

    if "${SCRIPT_DIR}/wait-for-tls-ready.sh" --all --timeout 120 --verbose; then
        success "All components are TLS-ready"
        return 0
    else
        error "Components did not become ready in time"
        return 1
    fi
}

# Enable trace logging if requested
enable_trace_logging() {
    section "Enabling NSS/NSPR Trace Logging"

    log "Configuring trace logging in containers..."

    # Bridge
    docker exec sigul-bridge sh -c "
        mkdir -p /var/log/sigul
        chmod 777 /var/log/sigul
        cat > /etc/profile.d/nss-debug.sh << 'EOF'
export NSPR_LOG_MODULES='all:5'
export NSPR_LOG_FILE=/var/log/sigul/nss-trace.log
export NSS_DEBUG_PKCS11=1
EOF
    " 2>/dev/null || warn "Could not configure bridge trace logging"

    # Server
    docker exec sigul-server sh -c "
        mkdir -p /var/log/sigul
        chmod 777 /var/log/sigul
        cat > /etc/profile.d/nss-debug.sh << 'EOF'
export NSPR_LOG_MODULES='all:5'
export NSPR_LOG_FILE=/var/log/sigul/nss-trace.log
export NSS_DEBUG_PKCS11=1
EOF
    " 2>/dev/null || warn "Could not configure server trace logging"

    warn "Trace logging configured"
    warn "Note: Restart containers to apply trace logging:"
    warn "  docker restart sigul-bridge sigul-server"
}

# Run diagnostics
run_diagnostics() {
    section "Running Comprehensive Diagnostics"

    log "Running TLS diagnostic suite..."

    if "${SCRIPT_DIR}/debug-tls-stack.sh" --all --verbose; then
        success "All diagnostics passed!"
    else
        warn "Some diagnostics failed - review output above"
        warn "You can re-run diagnostics with:"
        warn "  ./scripts/debug-tls-stack.sh --all --verbose"
    fi

    log ""
    log "For more detailed analysis, run:"
    log "  ./scripts/test-nss-isolation.sh --verbose"
}

# Show deployment information
show_deployment_info() {
    section "Deployment Information"

    log "Container Status:"
    docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    echo ""
    log "Network Information:"
    docker network ls --filter "name=sigul" --format "table {{.Name}}\t{{.Driver}}"

    echo ""
    log "Volume Information:"
    docker volume ls --filter "name=sigul" --format "table {{.Name}}\t{{.Driver}}"

    echo ""
    log "Container IPs:"
    local bridge_ip server_ip
    bridge_ip=$(docker inspect sigul-bridge --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "N/A")
    server_ip=$(docker inspect sigul-server --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "N/A")
    echo "  Bridge: $bridge_ip"
    echo "  Server: $server_ip"

    echo ""
    log "Ephemeral Passwords (stored in test-artifacts/):"
    if [[ -f "${PROJECT_ROOT}/test-artifacts/admin-password" ]]; then
        local admin_pass
        admin_pass=$(cat "${PROJECT_ROOT}/test-artifacts/admin-password")
        echo "  Admin Password: $admin_pass"
    else
        warn "  Admin password not found"
    fi

    if [[ -f "${PROJECT_ROOT}/test-artifacts/nss-password" ]]; then
        local nss_pass
        nss_pass=$(cat "${PROJECT_ROOT}/test-artifacts/nss-password")
        echo "  NSS Password: $nss_pass"
    else
        warn "  NSS password not found"
    fi
}

# Show interactive debugging commands
show_interactive_commands() {
    section "Interactive Debugging Commands"

    cat << 'EOF'

📋 Container Logs:
  docker logs -f sigul-bridge
  docker logs -f sigul-server
  docker logs sigul-bridge --tail 50
  docker logs sigul-server --tail 50

🔍 Diagnostics:
  ./scripts/debug-tls-stack.sh --all --verbose
  ./scripts/debug-tls-stack.sh --certs
  ./scripts/debug-tls-stack.sh --tls
  ./scripts/test-nss-isolation.sh --verbose

🖥️  Exec into Containers:
  docker exec -it sigul-bridge bash
  docker exec -it sigul-server bash

🔐 Certificate Inspection:
  docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul
  docker exec sigul-server certutil -L -d sql:/etc/pki/sigul
  docker exec sigul-bridge certutil -K -d sql:/etc/pki/sigul

📁 Configuration:
  docker exec sigul-bridge cat /etc/sigul/bridge.conf
  docker exec sigul-server cat /etc/sigul/server.conf

🔌 Network Testing:
  docker exec sigul-bridge nslookup sigul-server.example.org
  docker exec sigul-bridge nc -zv sigul-server.example.org 44333
  docker exec sigul-bridge openssl s_client \
    -connect sigul-server.example.org:44333 -showcerts < /dev/null

📊 NSS Trace Logs (if --trace was used):
  docker exec sigul-bridge cat /var/log/sigul/nss-trace.log
  docker exec sigul-server cat /var/log/sigul/nss-trace.log

🧪 Run Integration Tests:
  ./scripts/run-integration-tests.sh --verbose --local-debug

🧹 Cleanup:
  docker stop sigul-bridge sigul-server
  docker rm sigul-bridge sigul-server
  docker volume rm $(docker volume ls -q --filter name=sigul)

EOF
}

# Main execution
main() {
    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    section "Local Sigul Debugging Session"
    log "Starting local debugging session..."
    log "Options: clean=$CLEAN_START, skip-build=$SKIP_BUILD, skip-tests=$SKIP_TESTS"
    log "         interactive=$INTERACTIVE, trace=$ENABLE_TRACE"

    # Step 1: Cleanup
    cleanup_deployment

    # Step 2: Build images (unless skipped)
    if [[ "$SKIP_BUILD" == "false" ]]; then
        if ! build_images; then
            error "Image building failed"
            exit 1
        fi
    else
        log "Skipping image build (--skip-build specified)"
        local platform_id
        platform_id=$(detect_platform)
        log "Verifying required images exist..."
        for img in "bridge-${platform_id}-image:test" "server-${platform_id}-image:test" "client-${platform_id}-image:test"; do
            if docker image inspect "$img" >/dev/null 2>&1; then
                log "  ✓ $img"
            else
                error "  ✗ $img NOT FOUND"
                error "Remove --skip-build to build images"
                exit 1
            fi
        done
    fi

    # Step 3: Deploy infrastructure
    if ! deploy_infrastructure; then
        error "Deployment failed"
        exit 1
    fi

    # Step 4: Wait for readiness
    if ! wait_for_readiness; then
        error "Components did not become ready"
        warn "Continuing anyway for debugging..."
    fi

    # Step 5: Enable trace logging if requested
    if [[ "$ENABLE_TRACE" == "true" ]]; then
        enable_trace_logging
    fi

    # Step 6: Show deployment info
    show_deployment_info

    # Step 7: Run diagnostics (unless skipped)
    if [[ "$SKIP_TESTS" == "false" ]]; then
        run_diagnostics
    else
        log "Skipping diagnostics (--skip-tests specified)"
    fi

    # Step 8: Interactive mode or exit
    if [[ "$INTERACTIVE" == "true" ]]; then
        show_interactive_commands
        section "Interactive Mode"
        success "Deployment complete - containers running for debugging"
        log "Press Ctrl+C to exit and stop containers, or run commands above"
        log ""
        warn "To keep containers running after exit, just close this terminal"
        warn "To stop later: docker stop sigul-bridge sigul-server"

        # Keep script running
        trap 'log "Exiting..."; exit 0' INT TERM
        while true; do
            sleep 1
        done
    else
        section "Session Complete"
        success "Local debugging session completed!"
        log ""
        log "Containers are running. To interact with them:"
        show_interactive_commands
    fi
}

main "$@"
