#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Pytest Integration Tests Bridge Script
#
# This script bridges our new pytest-based integration tests with the existing
# CI infrastructure. It allows the existing CI workflow to run comprehensive
# pytest tests while maintaining compatibility with the current framework.
#
# Usage:
#   ./scripts/run-pytest-integration-tests.sh [OPTIONS]
#
# Options:
#   --verbose       Enable verbose output
#   --category CAT  Run specific test category (infrastructure|certificates|communication|authentication|functional)
#   --timeout SEC   Test timeout in seconds (default: 300)
#   --help          Show this help message
#
# Environment Variables:
#   SIGUL_CLIENT_IMAGE   Client container image (required)
#   SIGUL_SERVER_IMAGE   Server container image (required)
#   SIGUL_BRIDGE_IMAGE   Bridge container image (required)
#   CI                   Set to 'true' for CI mode

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT
readonly TEST_DIR="$PROJECT_ROOT/tests/integration"
readonly ARTIFACTS_DIR="$PROJECT_ROOT/test-artifacts"

# Default configuration
DEFAULT_TIMEOUT=300
DEFAULT_CATEGORY="all"
VERBOSE_MODE=false
TEST_CATEGORY="$DEFAULT_CATEGORY"
TIMEOUT="$DEFAULT_TIMEOUT"
SHOW_HELP=false

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] PYTEST-BRIDGE:${NC} $*"
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
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

# Show help message
show_help() {
    cat << 'EOF'
Pytest Integration Tests Bridge Script

This script runs pytest-based integration tests within the existing CI framework.

USAGE:
    ./scripts/run-pytest-integration-tests.sh [OPTIONS]

OPTIONS:
    --verbose       Enable verbose output
    --category CAT  Run specific test category
    --timeout SEC   Test timeout in seconds
    --help          Show this help message

TEST CATEGORIES:
    all                   Run all test categories (default)
    infrastructure        Container and network setup tests
    certificates          NSS database and certificate tests
    communication         Inter-component connectivity tests
    authentication        TLS handshake and auth tests
    functional            Basic Sigul operations tests

ENVIRONMENT VARIABLES:
    SIGUL_CLIENT_IMAGE   Client container image (required)
    SIGUL_SERVER_IMAGE   Server container image (required)
    SIGUL_BRIDGE_IMAGE   Bridge container image (required)
    CI                   Set to 'true' for CI mode

EXAMPLES:
    ./scripts/run-pytest-integration-tests.sh --verbose
    ./scripts/run-pytest-integration-tests.sh --category infrastructure
    ./scripts/run-pytest-integration-tests.sh --timeout 600

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                SHOW_HELP=true
                shift
                ;;
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --category)
                TEST_CATEGORY="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
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

# Validate environment
validate_environment() {
    log "Validating environment for pytest integration tests"

    # Check required environment variables
    if [[ -z "${SIGUL_CLIENT_IMAGE:-}" ]]; then
        error "SIGUL_CLIENT_IMAGE environment variable is required"
        return 1
    fi

    if [[ -z "${SIGUL_SERVER_IMAGE:-}" ]]; then
        error "SIGUL_SERVER_IMAGE environment variable is required"
        return 1
    fi

    if [[ -z "${SIGUL_BRIDGE_IMAGE:-}" ]]; then
        error "SIGUL_BRIDGE_IMAGE environment variable is required"
        return 1
    fi

    debug "Environment validation passed"
    debug "Client image: $SIGUL_CLIENT_IMAGE"
    debug "Server image: $SIGUL_SERVER_IMAGE"
    debug "Bridge image: $SIGUL_BRIDGE_IMAGE"

    return 0
}

# Install test dependencies
install_test_dependencies() {
    log "Installing pytest test dependencies"

    # Check if Python is available
    if ! command -v python3 >/dev/null 2>&1; then
        error "Python 3 is not installed"
        return 1
    fi

    # Check if pip is available
    if ! command -v pip3 >/dev/null 2>&1 && ! python3 -m pip --version >/dev/null 2>&1; then
        error "pip is not available"
        return 1
    fi

    # Use minimal requirements that are more likely to work in CI
    local requirements_file="$TEST_DIR/requirements-minimal.txt"

    if [[ -f "$requirements_file" ]]; then
        debug "Installing from requirements file: $requirements_file"
        if python3 -m pip install -r "$requirements_file" --quiet; then
            debug "Test dependencies installed successfully"
        else
            warn "Failed to install from requirements file, installing minimal set"
            # Fallback to essential packages only
            python3 -m pip install pytest docker requests --quiet || {
                error "Failed to install minimal test dependencies"
                return 1
            }
        fi
    else
        debug "Requirements file not found, installing minimal set"
        python3 -m pip install pytest docker requests --quiet || {
            error "Failed to install minimal test dependencies"
            return 1
        }
    fi

    # Verify pytest installation
    if ! python3 -m pytest --version >/dev/null 2>&1; then
        error "pytest installation verification failed"
        return 1
    fi

    success "Test dependencies installed successfully"
    return 0
}

# Check if Sigul stack is running
check_stack_status() {
    log "Checking Sigul stack status"

    # Check if containers are running
    local bridge_status server_status

    bridge_status=$(docker ps --filter "name=sigul-bridge" --format "{{.Status}}" | head -1)
    server_status=$(docker ps --filter "name=sigul-server" --format "{{.Status}}" | head -1)

    if [[ -z "$bridge_status" ]]; then
        warn "Bridge container not found or not running"
        return 1
    fi

    if [[ -z "$server_status" ]]; then
        warn "Server container not found or not running"
        return 1
    fi

    if [[ "$bridge_status" =~ "Up" ]] && [[ "$server_status" =~ "Up" ]]; then
        debug "Sigul stack is running"
        debug "Bridge status: $bridge_status"
        debug "Server status: $server_status"
        return 0
    else
        warn "Sigul stack containers are not in running state"
        warn "Bridge status: $bridge_status"
        warn "Server status: $server_status"
        return 1
    fi
}

# Start Sigul stack if not running
ensure_stack_running() {
    log "Ensuring Sigul stack is running"

    if check_stack_status; then
        success "Sigul stack is already running"
        return 0
    fi

    log "Starting Sigul stack"

    # Check if docker-compose file exists
    local compose_file="$PROJECT_ROOT/docker-compose.sigul.yml"
    if [[ ! -f "$compose_file" ]]; then
        error "Docker compose file not found: $compose_file"
        return 1
    fi

    # Start the stack
    if docker compose -f "$compose_file" up -d sigul-bridge sigul-server; then
        success "Sigul stack started"
    else
        error "Failed to start Sigul stack"
        return 1
    fi

    # Wait for stack to be ready
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        debug "Waiting for stack readiness (attempt $attempt/$max_attempts)"

        if check_stack_status; then
            success "Sigul stack is ready"
            return 0
        fi

        sleep 5
        ((attempt++))
    done

    error "Timeout waiting for Sigul stack to be ready"
    return 1
}

# Prepare test environment
prepare_test_environment() {
    log "Preparing test environment"

    # Create artifacts directory
    mkdir -p "$ARTIFACTS_DIR"
    debug "Created artifacts directory: $ARTIFACTS_DIR"

    # Set up environment variables for tests
    export PYTEST_SIGUL_CLIENT_IMAGE="$SIGUL_CLIENT_IMAGE"
    export PYTEST_SIGUL_SERVER_IMAGE="$SIGUL_SERVER_IMAGE"
    export PYTEST_SIGUL_BRIDGE_IMAGE="$SIGUL_BRIDGE_IMAGE"
    export PYTEST_TIMEOUT="$TIMEOUT"
    export PYTEST_VERBOSE="$VERBOSE_MODE"

    debug "Test environment variables set"
    return 0
}

# Run pytest tests
run_pytest_tests() {
    log "Running pytest integration tests"

    # Change to project root
    cd "$PROJECT_ROOT"

    # Build pytest command
    local pytest_cmd=("python3" "-m" "pytest")

    # Add test file
    local test_file="$TEST_DIR/test_sigul_stack.py"
    if [[ ! -f "$test_file" ]]; then
        error "Test file not found: $test_file"
        return 1
    fi
    pytest_cmd+=("$test_file")

    # Add category filter
    if [[ "$TEST_CATEGORY" != "all" ]]; then
        # Convert category name to class name (infrastructure -> TestInfrastructure)
        local class_name="Test${TEST_CATEGORY^}"
        pytest_cmd+=("-k" "$class_name")
        log "Running tests for category: $TEST_CATEGORY (class: $class_name)"
    fi

    # Add verbosity
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        pytest_cmd+=("-v" "-s")
    else
        pytest_cmd+=("--tb=short")
    fi

    # Add timeout
    pytest_cmd+=("--timeout=$TIMEOUT")

    # Add JUnit XML output
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    pytest_cmd+=("--junit-xml=$ARTIFACTS_DIR/pytest_results_$timestamp.xml")

    debug "Pytest command: ${pytest_cmd[*]}"

    # Run tests
    local test_exit_code=0
    if "${pytest_cmd[@]}"; then
        success "Pytest tests completed successfully"
    else
        test_exit_code=$?
        error "Pytest tests failed (exit code: $test_exit_code)"
    fi

    return $test_exit_code
}

# Collect test artifacts
collect_artifacts() {
    log "Collecting test artifacts"

    # Collect container logs
    local logs_dir="$ARTIFACTS_DIR/container-logs"
    mkdir -p "$logs_dir"

    # Bridge logs
    if docker ps --filter "name=sigul-bridge" --format "{{.Names}}" | grep -q "sigul-bridge"; then
        docker logs sigul-bridge > "$logs_dir/bridge.log" 2>&1 || true
        debug "Collected bridge container logs"
    fi

    # Server logs
    if docker ps --filter "name=sigul-server" --format "{{.Names}}" | grep -q "sigul-server"; then
        docker logs sigul-server > "$logs_dir/server.log" 2>&1 || true
        debug "Collected server container logs"
    fi

    # Container inspect information
    docker inspect sigul-bridge > "$logs_dir/bridge_inspect.json" 2>/dev/null || true
    docker inspect sigul-server > "$logs_dir/server_inspect.json" 2>/dev/null || true

    # Docker system information
    docker --version > "$logs_dir/docker_version.txt" 2>&1 || true
    docker info > "$logs_dir/docker_info.txt" 2>&1 || true

    # Create test summary
    cat > "$ARTIFACTS_DIR/test_summary.txt" << EOF
Pytest Integration Tests Summary
===============================
Timestamp: $(date)
Category: $TEST_CATEGORY
Timeout: $TIMEOUT seconds
Verbose: $VERBOSE_MODE

Container Images:
- Client: $SIGUL_CLIENT_IMAGE
- Server: $SIGUL_SERVER_IMAGE
- Bridge: $SIGUL_BRIDGE_IMAGE

Test Results:
- JUnit XML: Available in pytest_results_*.xml
- Container Logs: Available in container-logs/
- Docker Info: Available in container-logs/docker_*.txt

EOF

    success "Test artifacts collected in: $ARTIFACTS_DIR"
    return 0
}

# Main execution function
main() {
    log "=== Pytest Integration Tests Bridge Script ==="

    # Parse arguments
    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    # Validate environment
    if ! validate_environment; then
        error "Environment validation failed"
        exit 1
    fi

    # Install test dependencies
    if ! install_test_dependencies; then
        error "Failed to install test dependencies"
        exit 1
    fi

    # Ensure Sigul stack is running
    if ! ensure_stack_running; then
        error "Failed to ensure Sigul stack is running"
        exit 1
    fi

    # Prepare test environment
    if ! prepare_test_environment; then
        error "Failed to prepare test environment"
        exit 1
    fi

    # Run pytest tests
    local test_result=0
    if ! run_pytest_tests; then
        test_result=$?
        error "Pytest tests failed"
    fi

    # Collect artifacts (always run)
    collect_artifacts

    # Final result
    if [[ $test_result -eq 0 ]]; then
        success "🎉 All pytest integration tests passed!"
    else
        error "💥 Pytest integration tests failed (exit code: $test_result)"
    fi

    exit $test_result
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
