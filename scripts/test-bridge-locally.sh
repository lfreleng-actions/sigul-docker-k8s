#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Local Bridge Testing Script
#
# This script helps reproduce and analyze bridge startup race conditions
# by testing the bridge startup process locally with various scenarios.
#
# Usage:
#   ./scripts/test-bridge-locally.sh [OPTIONS]
#
# Options:
#   --build-first       Build the bridge container locally before testing
#   --test-flags        Test daemon flag support detection
#   --race-test         Perform race condition testing (start/stop cycles)
#   --verbose           Enable verbose output
#   --help              Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Test configuration
BUILD_FIRST=false
TEST_FLAGS=false
RACE_TEST=false
VERBOSE_MODE=false
SHOW_HELP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

verbose() {
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

# Help function
show_help() {
    cat << EOF
Local Bridge Testing Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --build-first       Build the bridge container locally before testing
    --test-flags        Test daemon flag support detection
    --race-test         Perform race condition testing (start/stop cycles)
    --verbose           Enable verbose output
    --help              Show this help message

DESCRIPTION:
    This script helps diagnose bridge startup issues locally by:

    1. Building bridge container locally (optional)
    2. Testing daemon flag support (--internal-log-dir, --internal-pid-dir)
    3. Running race condition tests (rapid start/stop cycles)
    4. Collecting detailed diagnostics for analysis

    The script creates isolated test environments to reproduce issues
    without affecting the main CI/CD pipeline.

EXAMPLES:
    # Test flag support only
    $0 --test-flags --verbose

    # Full local test including build and race testing
    $0 --build-first --test-flags --race-test --verbose

    # Quick race condition test with existing images
    $0 --race-test

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --build-first)
                BUILD_FIRST=true
                shift
                ;;
            --test-flags)
                TEST_FLAGS=true
                shift
                ;;
            --race-test)
                RACE_TEST=true
                shift
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
                echo
                show_help
                exit 1
                ;;
        esac
    done
}

# Detect platform for image naming
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
            error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Build bridge container locally
build_bridge_container() {
    local platform
    platform=$(detect_platform)
    local image_name="bridge-${platform}-test:local"

    log "Building bridge container locally for platform: $platform"

    cd "$PROJECT_ROOT"

    # Build the bridge container
    if docker build -f Dockerfile.bridge -t "$image_name" .; then
        success "Bridge container built successfully: $image_name"
        echo "$image_name"
    else
        error "Failed to build bridge container"
        exit 1
    fi
}

# Test daemon flag support
test_daemon_flags() {
    local platform
    platform=$(detect_platform)
    local image_name="bridge-${platform}-image:test"

    # Try to use local build if available
    if docker image inspect "bridge-${platform}-test:local" >/dev/null 2>&1; then
        image_name="bridge-${platform}-test:local"
    fi

    log "Testing daemon flag support using image: $image_name"

    # Test sigul_bridge --help output
    log "Testing sigul_bridge --help output..."
    local help_output
    if help_output=$(docker run --rm "$image_name" sigul_bridge --help 2>&1); then
        verbose "Help output received successfully"

        # Check for internal flags
        if echo "$help_output" | grep -q -- '--internal-log-dir'; then
            success "✅ --internal-log-dir flag is supported"
        else
            warn "❌ --internal-log-dir flag is NOT supported"
        fi

        if echo "$help_output" | grep -q -- '--internal-pid-dir'; then
            success "✅ --internal-pid-dir flag is supported"
        else
            warn "❌ --internal-pid-dir flag is NOT supported"
        fi

        # Show relevant help sections
        log "Relevant help output sections:"
        echo "$help_output" | grep -A5 -B5 -E "(internal|log|pid|dir)" || echo "No relevant sections found"

    else
        error "Failed to get help output from sigul_bridge"
        verbose "Error output: $help_output"
        return 1
    fi

    # Test version information
    log "Testing version information..."
    local version_output
    if version_output=$(docker run --rm "$image_name" sigul_bridge --version 2>&1); then
        log "Version: $version_output"
    else
        verbose "Version check failed or not supported: $version_output"
    fi

    return 0
}

# Perform race condition testing
test_race_conditions() {
    local platform
    platform=$(detect_platform)
    local bridge_image="bridge-${platform}-image:test"
    local test_network="bridge-test-network"
    local test_volume="bridge-test-volume"

    # Try to use local build if available
    if docker image inspect "bridge-${platform}-test:local" >/dev/null 2>&1; then
        bridge_image="bridge-${platform}-test:local"
    fi

    log "Starting race condition testing using image: $bridge_image"

    # Cleanup any existing test resources
    cleanup_test_resources

    # Create test network and volume
    log "Creating test network and volume..."
    docker network create "$test_network" >/dev/null 2>&1 || true
    docker volume create "$test_volume" >/dev/null 2>&1 || true

    # Run multiple rapid start/stop cycles
    local cycles=5
    local success_count=0
    local failure_count=0

    for ((i=1; i<=cycles; i++)); do
        log "Race test cycle $i/$cycles"

        local container_name="bridge-race-test-$i"
        local start_time
        start_time=$(date +%s%3N)

        # Start bridge container
        verbose "Starting container: $container_name"
        if docker run -d \
            --name "$container_name" \
            --network "$test_network" \
            -v "$test_volume":/var/sigul \
            -e DEBUG=true \
            -e NSS_PASSWORD="test-password-$(date +%s)" \
            --user sigul \
            "$bridge_image" \
            /usr/local/bin/sigul-init.sh --role bridge --start-service; then

            # Wait for container to start
            sleep 2

            # Check if container is still running
            local container_status
            container_status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "unknown")

            local end_time
            end_time=$(date +%s%3N)
            local duration=$((end_time - start_time))

            if [[ "$container_status" == "running" ]]; then
                success "Cycle $i: Container started successfully (${duration}ms)"
                ((success_count++))

                # Test port binding
                sleep 3
                if docker exec "$container_name" ss -tlun | grep -q ":44334"; then
                    success "Cycle $i: Port 44334 is listening"
                else
                    warn "Cycle $i: Port 44334 is NOT listening"
                fi

            elif [[ "$container_status" == "restarting" ]]; then
                warn "Cycle $i: Container is restarting (${duration}ms)"
                ((failure_count++))

                # Collect logs
                log "Collecting logs for failed cycle $i..."
                docker logs "$container_name" > "race-test-logs-cycle-$i.txt" 2>&1 || true

            else
                warn "Cycle $i: Container failed to start or exited (${duration}ms, status: $container_status)"
                ((failure_count++))

                # Collect logs
                docker logs "$container_name" > "race-test-logs-cycle-$i.txt" 2>&1 || true
            fi

            # Stop and remove container
            docker stop "$container_name" >/dev/null 2>&1 || true
            docker rm "$container_name" >/dev/null 2>&1 || true

        else
            error "Cycle $i: Failed to start container"
            ((failure_count++))
        fi

        # Brief pause between cycles
        sleep 1
    done

    # Report results
    log "Race condition test results:"
    log "  Successful starts: $success_count/$cycles"
    log "  Failed starts: $failure_count/$cycles"

    if [[ $failure_count -gt 0 ]]; then
        warn "Race conditions detected! Check race-test-logs-cycle-*.txt files"

        # Analyze common failure patterns
        log "Analyzing failure patterns..."
        if ls race-test-logs-cycle-*.txt >/dev/null 2>&1; then
            log "Common error patterns found:"
            grep -h "ERROR\|error\|Error\|failed\|Failed" race-test-logs-cycle-*.txt | sort | uniq -c | sort -nr || true
        fi
    else
        success "No race conditions detected in $cycles cycles"
    fi

    # Cleanup
    cleanup_test_resources
}

# Cleanup test resources
cleanup_test_resources() {
    verbose "Cleaning up test resources..."

    # Stop and remove any bridge test containers
    docker ps -aq --filter "name=bridge-race-test" | xargs -r docker rm -f >/dev/null 2>&1 || true

    # Remove test network and volume
    docker network rm bridge-test-network >/dev/null 2>&1 || true
    docker volume rm bridge-test-volume >/dev/null 2>&1 || true
}

# Interactive bridge testing
interactive_bridge_test() {
    local platform
    platform=$(detect_platform)
    local bridge_image="bridge-${platform}-image:test"

    # Try to use local build if available
    if docker image inspect "bridge-${platform}-test:local" >/dev/null 2>&1; then
        bridge_image="bridge-${platform}-test:local"
    fi

    log "Starting interactive bridge test session..."
    log "Image: $bridge_image"
    log "Press Ctrl+C to exit"

    # Create temporary test environment
    local test_container="bridge-interactive-test"
    local test_network="bridge-interactive-network"
    local test_volume="bridge-interactive-volume"

    # Cleanup any existing resources
    docker rm -f "$test_container" >/dev/null 2>&1 || true
    docker network rm "$test_network" >/dev/null 2>&1 || true
    docker volume rm "$test_volume" >/dev/null 2>&1 || true

    # Create resources
    docker network create "$test_network" >/dev/null 2>&1
    docker volume create "$test_volume" >/dev/null 2>&1

    # Trap cleanup on exit
    trap 'log "Cleaning up interactive test..."; docker rm -f "$test_container" >/dev/null 2>&1 || true; docker network rm "$test_network" >/dev/null 2>&1 || true; docker volume rm "$test_volume" >/dev/null 2>&1 || true' EXIT

    log "Starting bridge container interactively..."
    docker run -it --rm \
        --name "$test_container" \
        --network "$test_network" \
        -v "$test_volume":/var/sigul \
        -e DEBUG=true \
        -e NSS_PASSWORD="interactive-test-password" \
        --user sigul \
        "$bridge_image" \
        bash
}

# Main function
main() {
    parse_args "$@"

    if [[ "${SHOW_HELP}" == "true" ]]; then
        show_help
        exit 0
    fi

    log "Starting local bridge testing..."
    log "Project root: $PROJECT_ROOT"
    log "Platform: $(detect_platform)"

    # Change to project directory
    cd "$PROJECT_ROOT"

    # Build container if requested
    if [[ "${BUILD_FIRST}" == "true" ]]; then
        build_bridge_container
    fi

    # Test daemon flags if requested
    if [[ "${TEST_FLAGS}" == "true" ]]; then
        log "Testing daemon flag support..."
        test_daemon_flags
    fi

    # Run race condition tests if requested
    if [[ "${RACE_TEST}" == "true" ]]; then
        log "Running race condition tests..."
        test_race_conditions
    fi

    # If no specific tests requested, run interactive mode
    if [[ "${BUILD_FIRST}" == "false" && "${TEST_FLAGS}" == "false" && "${RACE_TEST}" == "false" ]]; then
        log "No specific tests requested, starting interactive mode..."
        interactive_bridge_test
    fi

    success "Local bridge testing completed"
}

# Execute main function with all arguments
main "$@"
