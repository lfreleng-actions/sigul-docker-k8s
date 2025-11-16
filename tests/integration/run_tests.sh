#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Stack Integration Test Runner
#
# This script provides a comprehensive test runner for the Sigul signing infrastructure,
# supporting both local development and CI/CD environments.
#
# Features:
# - Automatic environment detection (local vs CI)
# - Docker stack management
# - Test execution with proper cleanup
# - Comprehensive reporting
# - Parallel test execution support
# - Test result artifacts collection
#
# Usage:
#   ./run_tests.sh [OPTIONS]
#
# Options:
#   --help                Show this help message
#   --local               Force local development mode
#   --ci                  Force CI/CD mode
#   --build               Rebuild containers before testing
#   --no-cleanup          Skip cleanup after tests (for debugging)
#   --verbose             Enable verbose output
#   --parallel            Run tests in parallel
#   --category CATEGORY   Run specific test category (infrastructure|certificates|communication|authentication|functional)
#   --output-dir DIR      Directory for test artifacts (default: test-artifacts)
#   --timeout SECONDS     Test timeout in seconds (default: 300)
#   --retry-count COUNT   Number of retry attempts for failed tests (default: 2)
#
# Examples:
#   ./run_tests.sh                                    # Run all tests with auto-detection
#   ./run_tests.sh --local --verbose                  # Local development with verbose output
#   ./run_tests.sh --ci --parallel                    # CI mode with parallel execution
#   ./run_tests.sh --category infrastructure          # Run only infrastructure tests
#   ./run_tests.sh --build --no-cleanup               # Rebuild and debug mode
#
# Environment Variables:
#   CI                    Set to 'true' for CI mode detection
#   SIGUL_TEST_TIMEOUT    Override default test timeout
#   SIGUL_TEST_PARALLEL   Set to 'true' to enable parallel tests
#   SIGUL_TEST_VERBOSE    Set to 'true' for verbose output
#   SIGUL_BUILD_CACHE     Set to 'false' to disable build cache

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly PROJECT_ROOT
readonly TEST_DIR="$SCRIPT_DIR"
readonly COMPOSE_FILE="$PROJECT_ROOT/docker-compose.sigul.yml"

# Default configuration
DEFAULT_TIMEOUT=300
DEFAULT_RETRY_COUNT=2
DEFAULT_OUTPUT_DIR="test-artifacts"
DEFAULT_PARALLEL=false
DEFAULT_VERBOSE=false
DEFAULT_BUILD=false
DEFAULT_CLEANUP=true
DEFAULT_CATEGORY="all"

# Runtime configuration
TIMEOUT=${SIGUL_TEST_TIMEOUT:-$DEFAULT_TIMEOUT}
RETRY_COUNT=$DEFAULT_RETRY_COUNT
OUTPUT_DIR="$PROJECT_ROOT/$DEFAULT_OUTPUT_DIR"
PARALLEL=${SIGUL_TEST_PARALLEL:-$DEFAULT_PARALLEL}
VERBOSE=${SIGUL_TEST_VERBOSE:-$DEFAULT_VERBOSE}
BUILD_CONTAINERS=$DEFAULT_BUILD
CLEANUP_AFTER=$DEFAULT_CLEANUP
TEST_CATEGORY=$DEFAULT_CATEGORY
FORCE_MODE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
# shellcheck disable=SC2034
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] TEST-RUNNER:${NC} $*"
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

debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

# Show help message
show_help() {
    cat << EOF
Sigul Stack Integration Test Runner

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --help                Show this help message
    --local               Force local development mode
    --ci                  Force CI/CD mode
    --build               Rebuild containers before testing
    --no-cleanup          Skip cleanup after tests (for debugging)
    --verbose             Enable verbose output
    --parallel            Run tests in parallel
    --category CATEGORY   Run specific test category
    --output-dir DIR      Directory for test artifacts
    --timeout SECONDS     Test timeout in seconds
    --retry-count COUNT   Number of retry attempts

TEST CATEGORIES:
    all                   Run all test categories (default)
    infrastructure        Container and network setup tests
    certificates          NSS database and certificate tests
    communication         Inter-component connectivity tests
    authentication        TLS handshake and auth tests
    functional            Basic Sigul operations tests

EXAMPLES:
    $0                                    # Run all tests (auto-detect mode)
    $0 --local --verbose                  # Local dev with verbose output
    $0 --ci --parallel                    # CI mode with parallel execution
    $0 --category infrastructure          # Run only infrastructure tests
    $0 --build --no-cleanup               # Rebuild containers and debug

ENVIRONMENT VARIABLES:
    CI                    Set to 'true' for CI mode detection
    SIGUL_TEST_TIMEOUT    Override default test timeout
    SIGUL_TEST_PARALLEL   Set to 'true' to enable parallel tests
    SIGUL_TEST_VERBOSE    Set to 'true' for verbose output
    SIGUL_BUILD_CACHE     Set to 'false' to disable build cache

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_help
                exit 0
                ;;
            --local)
                FORCE_MODE="local"
                shift
                ;;
            --ci)
                FORCE_MODE="ci"
                shift
                ;;
            --build)
                BUILD_CONTAINERS=true
                shift
                ;;
            --no-cleanup)
                CLEANUP_AFTER=false
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --parallel)
                PARALLEL=true
                shift
                ;;
            --category)
                TEST_CATEGORY="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --retry-count)
                RETRY_COUNT="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Detect execution environment
detect_environment() {
    if [[ -n "$FORCE_MODE" ]]; then
        echo "$FORCE_MODE"
        return
    fi

    # Check for CI environment indicators
    if [[ "${CI:-false}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${JENKINS_URL:-}" ]]; then
        echo "ci"
    else
        echo "local"
    fi
}

# Setup test environment
setup_environment() {
    local env_mode="$1"

    log "Setting up test environment for mode: $env_mode"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    debug "Created output directory: $OUTPUT_DIR"

    # Ensure we're in the project root
    cd "$PROJECT_ROOT"

    # Verify required files exist
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "Docker compose file not found: $COMPOSE_FILE"
        exit 1
    fi

    # Check Docker availability
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed or not in PATH"
        exit 1
    fi

    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose is not available"
        exit 1
    fi

    # Install Python test dependencies
    install_test_dependencies "$env_mode"
}

# Install test dependencies
install_test_dependencies() {
    local env_mode="$1"
    local requirements_file="$TEST_DIR/requirements-minimal.txt"

    if [[ ! -f "$requirements_file" ]]; then
        warn "Requirements file not found: $requirements_file"
        return
    fi

    log "Installing Python test dependencies"

    if [[ "$env_mode" == "ci" ]]; then
        # CI environment: install directly
        pip install -r "$requirements_file"
    else
        # Local environment: recommend virtual environment
        if [[ -z "${VIRTUAL_ENV:-}" ]]; then
            warn "Running in local mode without virtual environment"
            warn "Consider using: python3 -m venv test-env && source test-env/bin/activate"
        fi
        pip install -r "$requirements_file"
    fi

    debug "Test dependencies installed successfully"
}

# Build containers if requested
build_containers() {
    if [[ "$BUILD_CONTAINERS" != "true" ]]; then
        return
    fi

    log "Building Sigul containers"

    local build_args=()
    if [[ "${SIGUL_BUILD_CACHE:-true}" == "false" ]]; then
        build_args+=("--no-cache")
    fi

    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" build "${build_args[@]}"
    else
        docker-compose -f "$COMPOSE_FILE" build "${build_args[@]}"
    fi

    success "Container build completed"
}

# Start Sigul stack
start_stack() {
    log "Starting Sigul stack"

    # Clean up any existing stack
    stop_stack || true

    # Start the core services
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" up -d sigul-bridge sigul-server
    else
        docker-compose -f "$COMPOSE_FILE" up -d sigul-bridge sigul-server
    fi

    # Wait for services to be ready
    wait_for_stack_ready
}

# Wait for stack to be ready
wait_for_stack_ready() {
    log "Waiting for Sigul stack to be ready"

    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        debug "Health check attempt $attempt/$max_attempts"

        # Check container status
        local bridge_status server_status
        if docker compose version >/dev/null 2>&1; then
            bridge_status=$(docker compose -f "$COMPOSE_FILE" ps -q sigul-bridge | xargs -r docker inspect --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
            server_status=$(docker compose -f "$COMPOSE_FILE" ps -q sigul-server | xargs -r docker inspect --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
        else
            bridge_status=$(docker-compose -f "$COMPOSE_FILE" ps -q sigul-bridge | xargs -r docker inspect --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
            server_status=$(docker-compose -f "$COMPOSE_FILE" ps -q sigul-server | xargs -r docker inspect --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
        fi

        debug "Health status - Bridge: $bridge_status, Server: $server_status"

        if [[ "$bridge_status" == "healthy" && "$server_status" == "healthy" ]]; then
            success "Sigul stack is ready"
            return 0
        fi

        if [[ "$bridge_status" == "unhealthy" || "$server_status" == "unhealthy" ]]; then
            error "Sigul stack health check failed"
            show_container_logs
            return 1
        fi

        sleep 5
        ((attempt++))
    done

    error "Timeout waiting for Sigul stack to be ready"
    show_container_logs
    return 1
}

# Show container logs for debugging
show_container_logs() {
    warn "Showing container logs for debugging"

    echo "=== Bridge Logs ==="
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" logs sigul-bridge --tail 20 || true
    else
        docker-compose -f "$COMPOSE_FILE" logs sigul-bridge --tail 20 || true
    fi

    echo "=== Server Logs ==="
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" logs sigul-server --tail 20 || true
    else
        docker-compose -f "$COMPOSE_FILE" logs sigul-server --tail 20 || true
    fi
}

# Stop Sigul stack
stop_stack() {
    debug "Stopping Sigul stack"

    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" down --volumes 2>/dev/null || true
    else
        docker-compose -f "$COMPOSE_FILE" down --volumes 2>/dev/null || true
    fi
}

# Run tests
run_tests() {
    log "Running integration tests"

    # Build pytest command
    local pytest_cmd=("python3" "-m" "pytest")
    local test_file="$TEST_DIR/test_sigul_stack.py"

    # Add test file
    pytest_cmd+=("$test_file")

    # Add category filter
    if [[ "$TEST_CATEGORY" != "all" ]]; then
        pytest_cmd+=("-k" "test_$TEST_CATEGORY")
        log "Running tests for category: $TEST_CATEGORY"
    fi

    # Add verbosity
    if [[ "$VERBOSE" == "true" ]]; then
        pytest_cmd+=("-v" "-s")
    else
        pytest_cmd+=("--tb=short")
    fi

    # Add parallel execution
    if [[ "$PARALLEL" == "true" ]] && python3 -c "import xdist" 2>/dev/null; then
        pytest_cmd+=("-n" "auto")
        debug "Parallel execution enabled"
    else
        debug "pytest-xdist not available or parallel disabled"
    fi

    # Add timeout
    pytest_cmd+=("--timeout=$TIMEOUT")

    # Add output options (conditionally based on available plugins)
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')

    # Check for pytest-html plugin
    if python3 -c "import pytest_html" 2>/dev/null; then
        pytest_cmd+=("--html=$OUTPUT_DIR/test_report_$timestamp.html")
    else
        debug "pytest-html not available, skipping HTML report"
    fi

    # Basic JUnit XML is built into pytest
    pytest_cmd+=("--junit-xml=$OUTPUT_DIR/test_results_$timestamp.xml")

    # Add coverage if available
    if python3 -c "import pytest_cov" 2>/dev/null; then
        pytest_cmd+=("--cov=sigul" "--cov-report=html:$OUTPUT_DIR/coverage_$timestamp")
    else
        debug "pytest-cov not available, skipping coverage report"
    fi

    debug "Pytest command: ${pytest_cmd[*]}"

    # Run tests with retries
    local attempt=1
    local test_exit_code=1

    while [[ $attempt -le $((RETRY_COUNT + 1)) ]]; do
        if [[ $attempt -gt 1 ]]; then
            warn "Test attempt $attempt/$((RETRY_COUNT + 1))"
        fi

        # Execute tests
        if "${pytest_cmd[@]}"; then
            test_exit_code=0
            break
        else
            test_exit_code=$?
            if [[ $attempt -le $RETRY_COUNT ]]; then
                warn "Tests failed, retrying in 10 seconds..."
                sleep 10
            fi
        fi

        ((attempt++))
    done

    return $test_exit_code
}

# Collect test artifacts
collect_artifacts() {
    log "Collecting test artifacts"

    # Container logs
    local logs_dir="$OUTPUT_DIR/logs"
    mkdir -p "$logs_dir"

    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" logs sigul-bridge > "$logs_dir/bridge.log" 2>&1 || true
        docker compose -f "$COMPOSE_FILE" logs sigul-server > "$logs_dir/server.log" 2>&1 || true
    else
        docker-compose -f "$COMPOSE_FILE" logs sigul-bridge > "$logs_dir/bridge.log" 2>&1 || true
        docker-compose -f "$COMPOSE_FILE" logs sigul-server > "$logs_dir/server.log" 2>&1 || true
    fi

    # Container inspect information
    docker inspect sigul-bridge > "$logs_dir/bridge_inspect.json" 2>/dev/null || true
    docker inspect sigul-server > "$logs_dir/server_inspect.json" 2>/dev/null || true

    # System information
    docker --version > "$logs_dir/docker_version.txt" 2>&1 || true
    docker info > "$logs_dir/docker_info.txt" 2>&1 || true

    success "Test artifacts collected in: $OUTPUT_DIR"
}

# Cleanup function
cleanup() {
    if [[ "$CLEANUP_AFTER" == "true" ]]; then
        log "Cleaning up test environment"
        stop_stack
    else
        warn "Cleanup skipped (--no-cleanup specified)"
        warn "Manual cleanup required: docker compose -f $COMPOSE_FILE down --volumes"
    fi
}

# Main execution function
main() {
    log "=== Sigul Stack Integration Test Runner ==="

    # Parse arguments
    parse_args "$@"

    # Detect environment
    local env_mode
    env_mode=$(detect_environment)
    log "Detected environment: $env_mode"

    # Setup trap for cleanup
    trap cleanup EXIT

    # Setup environment
    setup_environment "$env_mode"

    # Build containers if requested
    build_containers

    # Start stack
    start_stack

    # Run tests
    local test_result=0
    if run_tests; then
        success "All tests passed!"
    else
        test_result=$?
        error "Some tests failed (exit code: $test_result)"
    fi

    # Collect artifacts
    collect_artifacts

    # Return test result
    exit $test_result
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
