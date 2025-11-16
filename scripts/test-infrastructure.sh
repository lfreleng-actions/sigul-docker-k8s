#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Simple infrastructure test script for Sigul Docker stack
# This script provides an easy way to test the stack locally

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Detect platform architecture (matching GitHub Actions)
detect_platform() {
    local arch
    arch=$(uname -m)
    case $arch in
        x86_64)
            echo "linux-amd64"
            ;;
        aarch64|arm64)
            echo "linux-arm64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Show usage
show_usage() {
    echo "Sigul Docker Stack Infrastructure Testing"
    echo "========================================"
    echo
    echo "Usage: $0 [command] [options]"
    echo
    echo "Commands:"
    echo "  start         - Start the docker-compose stack"
    echo "  stop          - Stop the running stack"
    echo "  logs          - Show logs from running containers"
    echo "  status        - Show status of containers"
    echo "  health        - Check health of all services"
    echo "  clean         - Clean up all containers and volumes"
    echo "  rebuild       - Rebuild images and restart stack"
    echo "  help          - Show this help message"
    echo
    echo "Options:"
    echo "  --skip-admin  - Skip admin user creation (for debugging)"
    echo "  --debug       - Enable debug mode"
    echo
    echo "Examples:"
    echo "  $0 start --skip-admin     # Start without creating admin user"
    echo "  $0 start --debug          # Start with debug logging"
    echo "  $0 health                 # Check if services are healthy"
    echo "  $0 logs                   # Show recent logs"
    echo
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if we're in the right directory
    if [[ ! -f "docker-compose.sigul.yml" ]]; then
        log_error "docker-compose.sigul.yml not found. Please run this from the project root directory."
        exit 1
    fi

    # Check docker
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi

    # Check docker compose (V2 style)
    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose V2 is not available. Please update Docker."
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    log_success "All prerequisites satisfied"
}

# Get compose command
get_compose_cmd() {
    echo "docker compose -f docker-compose.sigul.yml"
}

# Build images
build_images() {
    local platform_id
    platform_id=$(detect_platform)

    log_info "Building Docker images for platform: $platform_id..."

    log_info "Building sigul-server image..."
    docker build -f Dockerfile.server -t "server:${platform_id}" .
    docker tag "server:${platform_id}" "server-${platform_id}-image:test"

    log_info "Building sigul-bridge image..."
    docker build -f Dockerfile.bridge -t "bridge:${platform_id}" .
    docker tag "bridge:${platform_id}" "bridge-${platform_id}-image:test"

    log_info "Building sigul-client image..."
    docker build -f Dockerfile.client -t "client:${platform_id}" .
    docker tag "client:${platform_id}" "client-${platform_id}-image:test"

    log_success "Images built successfully with GitHub Actions compatible tags"
}

# Start the stack
start_stack() {
    local skip_admin="${SKIP_ADMIN:-false}"
    local debug_mode="${DEBUG_MODE:-false}"
    local platform_id
    platform_id=$(detect_platform)

    log_info "Starting Sigul infrastructure stack for platform: $platform_id..."

    # Set environment variables with GitHub Actions compatible image names
    export SIGUL_SKIP_ADMIN_USER="$skip_admin"
    export SIGUL_SERVER_IMAGE="server-${platform_id}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-${platform_id}-image:test"
    export SIGUL_CLIENT_IMAGE="client-${platform_id}-image:test"

    if [[ "$debug_mode" == "true" ]]; then
        export DEBUG="true"
    fi

    # Build images if they don't exist
    if ! docker image inspect "$SIGUL_SERVER_IMAGE" >/dev/null 2>&1 || \
       ! docker image inspect "$SIGUL_BRIDGE_IMAGE" >/dev/null 2>&1 || \
       ! docker image inspect "$SIGUL_CLIENT_IMAGE" >/dev/null 2>&1; then
        log_info "Building missing images..."
        build_images
    fi

    # Clean up first
    $(get_compose_cmd) down -v --remove-orphans 2>/dev/null || true

    # Start the stack
    log_info "Starting containers..."
    $(get_compose_cmd) up -d

    # Monitor startup
    log_info "Monitoring startup for 60 seconds..."
    local success=false
    for i in {1..12}; do
        echo "=== Status check $i/12 ==="
        $(get_compose_cmd) ps

        # Check for any failed containers
        if $(get_compose_cmd) ps | grep -q "Exit\|unhealthy"; then
            log_warning "Some containers have issues. Showing logs..."
            $(get_compose_cmd) logs --tail=20
            break
        fi

        # Check if all services are healthy
        local healthy_count
        healthy_count=$($(get_compose_cmd) ps --format json | jq -r '.Health // "unknown"' | grep -c "healthy" || echo "0")

        if [[ "$healthy_count" -ge 1 ]]; then
            success=true
            break
        fi

        if [[ $i -lt 12 ]]; then
            sleep 5
        fi
    done

    if [[ "$success" == "true" ]]; then
        log_success "Stack started successfully!"
        show_status
    else
        log_error "Stack failed to start properly"
        log_info "Use '$0 logs' to see detailed logs"
        return 1
    fi
}

# Stop the stack
stop_stack() {
    local platform_id
    platform_id=$(detect_platform)

    log_info "Stopping Sigul infrastructure stack..."

    # Set environment variables with GitHub Actions compatible image names
    export SIGUL_SERVER_IMAGE="server-${platform_id}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-${platform_id}-image:test"
    export SIGUL_CLIENT_IMAGE="client-${platform_id}-image:test"

    $(get_compose_cmd) down
    log_success "Stack stopped"
}

# Show logs
show_logs() {
    local platform_id
    platform_id=$(detect_platform)

    log_info "Showing logs from all containers..."

    # Set environment variables with GitHub Actions compatible image names
    export SIGUL_SERVER_IMAGE="server-${platform_id}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-${platform_id}-image:test"
    export SIGUL_CLIENT_IMAGE="client-${platform_id}-image:test"

    # Check if any containers are running
    if [[ $($(get_compose_cmd) ps --services --filter status=running | wc -l) -eq 0 ]]; then
        log_warning "No containers appear to be running."
        return
    fi

    $(get_compose_cmd) logs --tail=50 --follow
}

# Show status
show_status() {
    local platform_id
    platform_id=$(detect_platform)

    # Set environment variables with GitHub Actions compatible image names
    export SIGUL_SERVER_IMAGE="server-${platform_id}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-${platform_id}-image:test"
    export SIGUL_CLIENT_IMAGE="client-${platform_id}-image:test"

    log_info "Container Status:"
    $(get_compose_cmd) ps

    echo ""
    log_info "Port Status:"
    # Server connects to bridge - doesn't listen on a port
    if timeout 3 bash -c "nc -z localhost 44334" 2>/dev/null; then
        log_success "✅ sigul-bridge is accessible on port 44334"
    else
        log_warning "❌ sigul-bridge is not accessible on port 44334"
    fi

    # Check server process health (not port-based)
    if docker exec sigul-server pgrep -f server >/dev/null 2>&1; then
        log_success "✅ sigul-server process is running"
    else
        log_warning "❌ sigul-server process is not running"
    fi
}

# Check health
check_health() {
    local platform_id
    platform_id=$(detect_platform)

    log_info "Checking health of all services..."

    # Set environment variables with GitHub Actions compatible image names
    export SIGUL_SERVER_IMAGE="server-${platform_id}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-${platform_id}-image:test"
    export SIGUL_CLIENT_IMAGE="client-${platform_id}-image:test"

    local healthy=0
    local total=0

    # Get container health status
    while read -r container; do
        if [[ -n "$container" ]]; then
            ((total++))
            local status
            status=$(docker container inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no-healthcheck")

            case "$status" in
                "healthy")
                    log_success "✅ $container is healthy"
                    ((healthy++))
                    ;;
                "unhealthy")
                    log_error "❌ $container is unhealthy"
                    ;;
                "starting")
                    log_warning "🔄 $container is starting"
                    ;;
                "no-healthcheck")
                    log_warning "⚠️  $container has no health check"
                    ((healthy++))  # Count as healthy if no health check
                    ;;
                *)
                    log_warning "❓ $container status unknown: $status"
                    ;;
            esac
        fi
    done < <($(get_compose_cmd) ps -q)

    echo ""
    if [[ $healthy -eq $total && $total -gt 0 ]]; then
        log_success "All services are healthy ($healthy/$total)"
        return 0
    else
        log_error "Some services are not healthy ($healthy/$total)"
        return 1
    fi
}

# Clean up
cleanup() {
    local platform_id
    platform_id=$(detect_platform)

    log_info "Cleaning up containers and volumes..."

    # Stop and remove containers
    $(get_compose_cmd) down -v --remove-orphans 2>/dev/null || true

    # Remove images with GitHub Actions compatible names
    docker rmi "server-${platform_id}-image:test" "bridge-${platform_id}-image:test" "client-${platform_id}-image:test" 2>/dev/null || true
    docker rmi "server:${platform_id}" "bridge:${platform_id}" "client:${platform_id}" 2>/dev/null || true

    # Remove any dangling images
    docker image prune -f 2>/dev/null || true

    log_success "Cleanup completed"
}

# Rebuild and restart
rebuild_and_restart() {
    log_info "Rebuilding images and restarting stack..."

    cleanup
    build_images
    start_stack
}

# Parse options
SKIP_ADMIN="false"
DEBUG_MODE="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-admin)
            SKIP_ADMIN="true"
            shift
            ;;
        --debug)
            DEBUG_MODE="true"
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Main execution
main() {
    # Check prerequisites first
    check_prerequisites

    # Handle commands
    case "${1:-help}" in
        "start")
            start_stack
            ;;
        "stop")
            stop_stack
            ;;
        "logs")
            show_logs
            ;;
        "status")
            show_status
            ;;
        "health")
            check_health
            ;;
        "clean")
            cleanup
            ;;
        "rebuild")
            rebuild_and_restart
            ;;
        "help"|"-h"|"--help")
            show_usage
            ;;
        *)
            log_error "Unknown command: $1"
            echo
            show_usage
            exit 1
            ;;
    esac
}

# Export variables for the functions
export SKIP_ADMIN DEBUG_MODE

# Run main function
main "$@"
