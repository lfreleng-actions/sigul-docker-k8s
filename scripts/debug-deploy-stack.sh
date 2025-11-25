#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Stack Debug Deployment Script
#
# This script deploys the Sigul stack using the standard deployment script
# but with enhanced debugging, TLS diagnostics, and persistent containers
# for interactive troubleshooting.
#
# Usage:
#   ./scripts/debug-deploy-stack.sh [OPTIONS]
#
# Options:
#   --clean         Clean all volumes and containers before deployment
#   --keep          Keep containers running for debugging (default)
#   --auto-test     Run TLS diagnostics automatically after deployment
#   --trace         Enable NSS/NSPR trace logging in containers
#   --help          Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Options
CLEAN_VOLUMES=false
KEEP_CONTAINERS=true
AUTO_TEST=false
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
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $*"
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
Sigul Stack Debug Deployment Script

USAGE:
    ./scripts/debug-deploy-stack.sh [OPTIONS]

OPTIONS:
    --clean         Clean all volumes and containers before deployment
    --keep          Keep containers running for debugging (default: true)
    --auto-test     Run TLS diagnostics automatically after deployment
    --trace         Enable NSS/NSPR trace logging in containers
    --help          Show this help message

DESCRIPTION:
    This script deploys the Sigul stack with enhanced debugging capabilities
    for troubleshooting TLS and authentication issues. It:

    1. Optionally cleans existing containers and volumes
    2. Deploys infrastructure using standard deployment script
    3. Enables debug logging in all containers
    4. Optionally runs comprehensive TLS diagnostics
    5. Provides interactive debugging commands

EXAMPLES:
    # Fresh deployment with auto-testing
    ./scripts/debug-deploy-stack.sh --clean --auto-test

    # Deploy with trace logging enabled
    ./scripts/debug-deploy-stack.sh --trace

    # Quick debug deployment
    ./scripts/debug-deploy-stack.sh

INTERACTIVE DEBUGGING:
    After deployment, you can:

    # Run TLS diagnostics
    ./scripts/debug-tls-stack.sh --all --verbose

    # Check specific components
    ./scripts/debug-tls-stack.sh --certs
    ./scripts/debug-tls-stack.sh --connectivity
    ./scripts/debug-tls-stack.sh --tls

    # Enable full NSS trace
    ./scripts/debug-tls-stack.sh --full-trace

    # Exec into containers
    docker exec -it sigul-bridge bash
    docker exec -it sigul-server bash

    # View logs with follow
    docker logs -f sigul-bridge
    docker logs -f sigul-server

    # Test TLS manually
    docker exec sigul-bridge openssl s_client -connect sigul-server.example.org:44333

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --clean)
                CLEAN_VOLUMES=true
                shift
                ;;
            --keep)
                # shellcheck disable=SC2034  # Placeholder for future use
                KEEP_CONTAINERS=true
                shift
                ;;
            --auto-test)
                AUTO_TEST=true
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
clean_deployment() {
    section "Cleaning Existing Deployment"

    log "Stopping and removing Sigul containers..."
    docker stop sigul-bridge sigul-server 2>/dev/null || true
    docker rm sigul-bridge sigul-server 2>/dev/null || true

    if [[ "$CLEAN_VOLUMES" == "true" ]]; then
        log "Removing Sigul volumes..."
        docker volume ls --filter "name=sigul" --format "{{.Name}}" | while read -r vol; do
            log "Removing volume: $vol"
            docker volume rm "$vol" 2>/dev/null || true
        done
        success "Volumes cleaned"
    else
        log "Keeping existing volumes (use --clean to remove)"
    fi

    log "Removing integration test containers..."
    docker rm -f sigul-client-integration 2>/dev/null || true

    success "Cleanup completed"
}

# Deploy infrastructure with debug settings
deploy_with_debug() {
    section "Deploying Sigul Infrastructure with Debug Settings"

    log "Running deployment script with debug mode..."

    local deploy_args=(
        "--verbose"
        "--debug"
        "--local-debug"
    )

    if ! "${SCRIPT_DIR}/deploy-sigul-infrastructure.sh" "${deploy_args[@]}"; then
        error "Deployment failed!"
        return 1
    fi

    success "Infrastructure deployed successfully"
    return 0
}

# Enable trace logging in containers
enable_trace_logging() {
    section "Enabling NSS/NSPR Trace Logging"

    log "Configuring trace logging in bridge container..."
    docker exec sigul-bridge sh -c "
        echo 'export NSPR_LOG_MODULES=\"all:5\"' >> /etc/profile.d/nss-debug.sh
        echo 'export NSPR_LOG_FILE=/var/log/sigul/nss-trace.log' >> /etc/profile.d/nss-debug.sh
        echo 'export NSS_DEBUG_PKCS11=1' >> /etc/profile.d/nss-debug.sh
        mkdir -p /var/log/sigul
        chmod 777 /var/log/sigul
    " 2>/dev/null || warn "Could not configure bridge trace logging"

    log "Configuring trace logging in server container..."
    docker exec sigul-server sh -c "
        echo 'export NSPR_LOG_MODULES=\"all:5\"' >> /etc/profile.d/nss-debug.sh
        echo 'export NSPR_LOG_FILE=/var/log/sigul/nss-trace.log' >> /etc/profile.d/nss-debug.sh
        echo 'export NSS_DEBUG_PKCS11=1' >> /etc/profile.d/nss-debug.sh
        mkdir -p /var/log/sigul
        chmod 777 /var/log/sigul
    " 2>/dev/null || warn "Could not configure server trace logging"

    warn "Restart containers to apply trace logging:"
    warn "  docker restart sigul-bridge sigul-server"

    success "Trace logging configured"
}

# Display deployment information
show_deployment_info() {
    section "Deployment Information"

    log "Container Status:"
    docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    echo ""
    log "Network Information:"
    docker network ls --filter "name=sigul" --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"

    echo ""
    log "Volume Information:"
    docker volume ls --filter "name=sigul" --format "table {{.Name}}\t{{.Driver}}"

    echo ""
    log "Container IPs:"
    local bridge_ip
    local server_ip
    bridge_ip=$(docker inspect sigul-bridge --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "N/A")
    server_ip=$(docker inspect sigul-server --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "N/A")
    echo "  Bridge: $bridge_ip"
    echo "  Server: $server_ip"

    echo ""
    log "Ephemeral Passwords:"
    if [[ -f "${PROJECT_ROOT}/test-artifacts/admin-password" ]]; then
        local admin_pass
        admin_pass=$(cat "${PROJECT_ROOT}/test-artifacts/admin-password")
        echo "  Admin Password: $admin_pass"
    fi
    if [[ -f "${PROJECT_ROOT}/test-artifacts/nss-password" ]]; then
        local nss_pass
        nss_pass=$(cat "${PROJECT_ROOT}/test-artifacts/nss-password")
        echo "  NSS Password: $nss_pass"
    fi
}

# Run TLS diagnostics
run_tls_diagnostics() {
    section "Running TLS Diagnostics"

    log "Waiting 5 seconds for containers to stabilize..."
    sleep 5

    if [[ -x "${SCRIPT_DIR}/debug-tls-stack.sh" ]]; then
        log "Running comprehensive TLS diagnostics..."
        "${SCRIPT_DIR}/debug-tls-stack.sh" --all --verbose || {
            error "TLS diagnostics failed - see output above"
            return 1
        }
    else
        error "TLS diagnostics script not found or not executable"
        return 1
    fi

    success "TLS diagnostics completed"
}

# Show next steps
show_next_steps() {
    section "Next Steps for Debugging"

    cat << 'EOF'

✅ Sigul stack deployed with debug settings

📋 Quick Commands:

  # View logs
  docker logs -f sigul-bridge
  docker logs -f sigul-server

  # Run TLS diagnostics
  ./scripts/debug-tls-stack.sh --all --verbose

  # Check certificates
  ./scripts/debug-tls-stack.sh --certs

  # Test TLS handshakes
  ./scripts/debug-tls-stack.sh --tls

  # Full NSS trace
  ./scripts/debug-tls-stack.sh --full-trace

  # Interactive debugging
  docker exec -it sigul-bridge bash
  docker exec -it sigul-server bash

  # Manual TLS test from bridge to server
  docker exec sigul-bridge openssl s_client \
    -connect sigul-server.example.org:44333 \
    -showcerts < /dev/null

  # Check NSS database
  docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul
  docker exec sigul-server certutil -L -d sql:/etc/pki/sigul

  # View NSS trace logs (if enabled)
  docker exec sigul-bridge cat /var/log/sigul/nss-trace.log
  docker exec sigul-server cat /var/log/sigul/nss-trace.log

📚 Configuration Files:

  Bridge: docker exec sigul-bridge cat /etc/sigul/bridge.conf
  Server: docker exec sigul-server cat /etc/sigul/server.conf

🔍 Integration Testing:

  # Deploy client and run tests
  ./scripts/run-integration-tests.sh --verbose --local-debug

🧹 Cleanup:

  # Stop and remove (keep volumes)
  docker stop sigul-bridge sigul-server
  docker rm sigul-bridge sigul-server

  # Full cleanup (remove volumes)
  ./scripts/debug-deploy-stack.sh --clean

EOF
}

# Main execution
main() {
    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    section "Sigul Debug Deployment"
    log "Starting debug deployment of Sigul stack..."

    # Clean if requested
    if [[ "$CLEAN_VOLUMES" == "true" ]]; then
        clean_deployment
    fi

    # Deploy infrastructure
    if ! deploy_with_debug; then
        error "Deployment failed - see errors above"
        exit 1
    fi

    # Enable trace logging if requested
    if [[ "$ENABLE_TRACE" == "true" ]]; then
        enable_trace_logging
    fi

    # Wait for containers to settle
    log "Waiting for containers to initialize (10 seconds)..."
    sleep 10

    # Show deployment info
    show_deployment_info

    # Run diagnostics if requested
    if [[ "$AUTO_TEST" == "true" ]]; then
        run_tls_diagnostics || {
            warn "TLS diagnostics found issues - review output above"
        }
    fi

    # Show next steps
    show_next_steps

    success "Debug deployment completed!"
    log "Stack is ready for interactive debugging"

    return 0
}

main "$@"
