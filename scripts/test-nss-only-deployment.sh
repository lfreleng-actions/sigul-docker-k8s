#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Test NSS-Only Deployment Script
#
# This script tests the NSS-only Sigul deployment to ensure all components
# work correctly with the simplified validation approach.
#
# Key Test Areas:
# - NSS database initialization
# - Certificate generation and validation
# - Component health checks
# - Inter-component communication
# - Docker deployment integration
#
# Usage:
#   ./test-nss-only-deployment.sh [--quick] [--verbose]
#
# Options:
#   --quick     Run quick tests only (skip full deployment)
#   --verbose   Enable verbose logging
#   --help      Show this help message

set -euo pipefail

# Script version
readonly SCRIPT_VERSION="1.0.0"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly PROJECT_ROOT
readonly TEST_DIR="$PROJECT_ROOT/test-nss-only"
readonly DOCKER_COMPOSE_FILE="$PROJECT_ROOT/docker-compose.sigul.yml"

# Test configuration
QUICK_TEST=false
VERBOSE=false
# shellcheck disable=SC2034
TEST_TIMEOUT=300  # 5 minutes

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging functions
log() {
    echo -e "${BLUE}[NSS-TEST]${NC} $*"
}

success() {
    echo -e "${GREEN}[NSS-TEST] ✅${NC} $*"
}

error() {
    echo -e "${RED}[NSS-TEST] ❌${NC} $*"
}

warn() {
    echo -e "${YELLOW}[NSS-TEST] ⚠️${NC} $*"
}

debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${PURPLE}[NSS-TEST] 🔍${NC} $*"
    fi
}

# Test result tracking
test_result() {
    local test_name="$1"
    local result="$2"
    local details="${3:-}"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$result" == "PASS" ]]; then
        success "$test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        if [[ -n "$details" ]]; then
            debug "Details: $details"
        fi
    else
        error "$test_name"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        if [[ -n "$details" ]]; then
            error "Details: $details"
        fi
    fi
}

#######################################
# Test Environment Setup
#######################################

setup_test_environment() {
    log "Setting up NSS-only test environment"

    # Create test directory
    if [[ -d "$TEST_DIR" ]]; then
        debug "Removing existing test directory"
        rm -rf "$TEST_DIR"
    fi

    mkdir -p "$TEST_DIR"
    debug "Created test directory: $TEST_DIR"

    # Set environment variables for testing
    export NSS_PASSWORD="test_password_123"
    export SIGUL_ADMIN_PASSWORD="admin_password_123"
    export SIGUL_ADMIN_USER="testadmin"
    export DEBUG="true"

    success "Test environment setup complete"
}

# shellcheck disable=SC2317  # Function is called via trap
cleanup_test_environment() {
    log "Cleaning up test environment"

    # Stop any running containers
    if docker compose -f "$DOCKER_COMPOSE_FILE" ps -q >/dev/null 2>&1; then
        debug "Stopping Docker containers"
        docker compose -f "$DOCKER_COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi

    # Remove test directory
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
        debug "Removed test directory"
    fi

    # Clean up any test containers or volumes
    docker system prune -f >/dev/null 2>&1 || true

    success "Test environment cleanup complete"
}

#######################################
# Unit Tests for NSS Scripts
#######################################

test_nss_validation_script() {
    log "Testing NSS validation script"

    local script_path="$SCRIPT_DIR/validate-nss.sh"

    # Test 1: Script exists and is executable
    if [[ -x "$script_path" ]]; then
        test_result "NSS validation script exists and is executable" "PASS"
    else
        test_result "NSS validation script exists and is executable" "FAIL" "Script not found or not executable: $script_path"
        return 1
    fi

    # Test 2: Help option works
    if "$script_path" --help >/dev/null 2>&1; then
        test_result "NSS validation script help option works" "PASS"
    else
        test_result "NSS validation script help option works" "FAIL"
    fi

    # Test 3: Invalid component handling
    if ! "$script_path" invalid_component >/dev/null 2>&1; then
        test_result "NSS validation script handles invalid components" "PASS"
    else
        test_result "NSS validation script handles invalid components" "FAIL"
    fi
}

test_nss_init_script() {
    log "Testing NSS initialization script"

    local script_path="$SCRIPT_DIR/sigul-init-nss-only.sh"

    # Test 1: Script exists and is executable
    if [[ -x "$script_path" ]]; then
        test_result "NSS init script exists and is executable" "PASS"
    else
        test_result "NSS init script exists and is executable" "FAIL" "Script not found: $script_path"
        return 1
    fi

    # Test 2: Help option works
    if "$script_path" --help >/dev/null 2>&1; then
        test_result "NSS init script help option works" "PASS"
    else
        test_result "NSS init script help option works" "FAIL"
    fi

    # Test 3: Requires role parameter
    if ! "$script_path" >/dev/null 2>&1; then
        test_result "NSS init script requires role parameter" "PASS"
    else
        test_result "NSS init script requires role parameter" "FAIL"
    fi
}

test_nss_health_library() {
    log "Testing NSS health check library"

    local script_path="$SCRIPT_DIR/lib/health.sh"

    # Test 1: Library exists
    if [[ -f "$script_path" ]]; then
        test_result "NSS health library exists" "PASS"
    else
        test_result "NSS health library exists" "FAIL" "Library not found: $script_path"
        return 1
    fi

    # Test 2: Library can be sourced
    # shellcheck disable=SC1090  # Dynamic source path
    if source "$script_path" >/dev/null 2>&1; then
        test_result "NSS health library can be sourced" "PASS"
    else
        test_result "NSS health library can be sourced" "FAIL"
    fi

    # Test 3: Required functions are defined
    # shellcheck disable=SC1090  # Dynamic source path
    source "$script_path" >/dev/null 2>&1 || true
    local required_functions=("nss_health_check_bridge" "nss_health_check_server" "nss_health_check_client")
    local functions_ok=true

    for func in "${required_functions[@]}"; do
        if declare -f "$func" >/dev/null 2>&1; then
            debug "Function found: $func"
        else
            error "Function missing: $func"
            functions_ok=false
        fi
    done

    if [[ "$functions_ok" == "true" ]]; then
        test_result "NSS health library functions are defined" "PASS"
    else
        test_result "NSS health library functions are defined" "FAIL"
    fi
}

#######################################
# Docker Integration Tests
#######################################

test_docker_compose_configuration() {
    log "Testing Docker Compose configuration"

    # Test 1: Docker Compose file exists
    if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
        test_result "Docker Compose file exists" "PASS"
    else
        test_result "Docker Compose file exists" "FAIL" "File not found: $DOCKER_COMPOSE_FILE"
        return 1
    fi

    # Test 2: Docker Compose file is valid YAML
    if docker compose -f "$DOCKER_COMPOSE_FILE" config >/dev/null 2>&1; then
        test_result "Docker Compose file is valid YAML" "PASS"
    else
        test_result "Docker Compose file is valid YAML" "FAIL"
    fi

    # Test 3: Required services are defined
    local required_services=("sigul-bridge" "sigul-server")
    local services_config
    services_config=$(docker compose -f "$DOCKER_COMPOSE_FILE" config --services 2>/dev/null || echo "")

    for service in "${required_services[@]}"; do
        if echo "$services_config" | grep -q "^$service$"; then
            test_result "Docker service defined: $service" "PASS"
        else
            test_result "Docker service defined: $service" "FAIL"
        fi
    done

    # Test 4: NSS-only commands are used
    local compose_content
    compose_content=$(cat "$DOCKER_COMPOSE_FILE")

    if echo "$compose_content" | grep -q "sigul-init-nss-only.sh"; then
        test_result "Docker Compose uses NSS-only initialization" "PASS"
    else
        test_result "Docker Compose uses NSS-only initialization" "FAIL"
    fi
}

test_docker_build() {
    log "Testing Docker build process"

    # Test 1: Bridge image builds successfully
    if docker build -f "$PROJECT_ROOT/Dockerfile.bridge" -t sigul-bridge-test "$PROJECT_ROOT" >/dev/null 2>&1; then
        test_result "Bridge Docker image builds successfully" "PASS"
    else
        test_result "Bridge Docker image builds successfully" "FAIL"
    fi

    # Test 2: Server image builds successfully
    if docker build -f "$PROJECT_ROOT/Dockerfile.server" -t sigul-server-test "$PROJECT_ROOT" >/dev/null 2>&1; then
        test_result "Server Docker image builds successfully" "PASS"
    else
        test_result "Server Docker image builds successfully" "FAIL"
    fi

    # Test 3: Client image builds successfully
    if docker build -f "$PROJECT_ROOT/Dockerfile.client" -t sigul-client-test "$PROJECT_ROOT" >/dev/null 2>&1; then
        test_result "Client Docker image builds successfully" "PASS"
    else
        test_result "Client Docker image builds successfully" "FAIL"
    fi

    # Cleanup test images
    docker rmi sigul-bridge-test sigul-server-test sigul-client-test >/dev/null 2>&1 || true
}

#######################################
# Integration Tests
#######################################

test_nss_only_deployment() {
    log "Testing NSS-only deployment integration"

    if [[ "$QUICK_TEST" == "true" ]]; then
        warn "Skipping full deployment test in quick mode"
        return 0
    fi

    # Start deployment
    log "Starting NSS-only deployment"

    if ! docker compose -f "$DOCKER_COMPOSE_FILE" up -d >/dev/null 2>&1; then
        test_result "Docker deployment starts successfully" "FAIL"
        return 1
    fi

    test_result "Docker deployment starts successfully" "PASS"

    # Wait for services to be healthy
    local max_wait=120
    local wait_time=0
    local services_healthy=false

    while [[ $wait_time -lt $max_wait ]]; do
        if docker compose -f "$DOCKER_COMPOSE_FILE" ps --filter "health=healthy" | grep -q "sigul-bridge"; then
            services_healthy=true
            break
        fi
        sleep 5
        wait_time=$((wait_time + 5))
        debug "Waiting for services to be healthy... (${wait_time}s/${max_wait}s)"
    done

    if [[ "$services_healthy" == "true" ]]; then
        test_result "Bridge service becomes healthy" "PASS"
    else
        test_result "Bridge service becomes healthy" "FAIL" "Timeout after ${max_wait}s"
    fi

    # Test NSS certificate validation in running containers
    test_nss_certificates_in_containers

    # Cleanup
    docker compose -f "$DOCKER_COMPOSE_FILE" down --volumes >/dev/null 2>&1 || true
}

test_nss_certificates_in_containers() {
    log "Testing NSS certificates in running containers"

    # Test bridge certificates
    if docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca >/dev/null 2>&1; then
        test_result "Bridge CA certificate exists in NSS database" "PASS"
    else
        test_result "Bridge CA certificate exists in NSS database" "FAIL"
    fi

    if docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-bridge-cert >/dev/null 2>&1; then
        test_result "Bridge service certificate exists in NSS database" "PASS"
    else
        test_result "Bridge service certificate exists in NSS database" "FAIL"
    fi

    # Test server certificates (if server is running)
    if docker ps --format "{{.Names}}" | grep -q "sigul-server"; then
        if docker exec sigul-server certutil -d sql:/var/sigul/nss/server -L -n sigul-ca >/dev/null 2>&1; then
            test_result "Server CA certificate exists in NSS database" "PASS"
        else
            test_result "Server CA certificate exists in NSS database" "FAIL"
        fi

        if docker exec sigul-server certutil -d sql:/var/sigul/nss/server -L -n sigul-server-cert >/dev/null 2>&1; then
            test_result "Server service certificate exists in NSS database" "PASS"
        else
            test_result "Server service certificate exists in NSS database" "FAIL"
        fi
    fi
}

#######################################
# Test Suite Execution
#######################################

run_unit_tests() {
    log "=== Running Unit Tests ==="
    test_nss_validation_script
    test_nss_init_script
    test_nss_health_library
}

run_docker_tests() {
    log "=== Running Docker Tests ==="
    test_docker_compose_configuration
    if [[ "$QUICK_TEST" == "false" ]]; then
        test_docker_build
    else
        warn "Skipping Docker build tests in quick mode"
    fi
}

run_integration_tests() {
    log "=== Running Integration Tests ==="
    test_nss_only_deployment
}

print_test_summary() {
    log "=== Test Summary ==="
    log "Total tests: $TOTAL_TESTS"
    success "Passed: $PASSED_TESTS"
    if [[ $FAILED_TESTS -gt 0 ]]; then
        error "Failed: $FAILED_TESTS"
    else
        log "Failed: $FAILED_TESTS"
    fi

    local success_rate=0
    if [[ $TOTAL_TESTS -gt 0 ]]; then
        success_rate=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    fi

    log "Success rate: ${success_rate}%"

    if [[ $FAILED_TESTS -eq 0 ]]; then
        success "🎉 All NSS-only tests passed! The simplified approach is working correctly."
    else
        error "❌ Some tests failed. Review the errors above and fix issues before deployment."
    fi
}

show_usage() {
    cat << EOF
Test NSS-Only Deployment Script v$SCRIPT_VERSION

This script tests the NSS-only Sigul deployment to ensure all components
work correctly with the simplified validation approach.

Usage:
  $0 [OPTIONS]

Options:
  --quick     Run quick tests only (skip Docker builds and full deployment)
  --verbose   Enable verbose logging and debug output
  --help      Show this help message

Test Categories:
  1. Unit Tests       - Test NSS scripts and libraries
  2. Docker Tests     - Test Docker configuration and builds
  3. Integration Tests - Test full NSS-only deployment

Examples:
  $0                  # Run all tests
  $0 --quick         # Run quick tests only
  $0 --verbose       # Run with detailed logging
  $0 --quick --verbose # Quick tests with verbose output

Environment Variables:
  NSS_PASSWORD            NSS database password (default: auto-generated)
  SIGUL_ADMIN_PASSWORD    Admin password (default: auto-generated)
  DEBUG                   Enable debug mode (default: true for tests)

EOF
}

main() {
    log "NSS-Only Deployment Test Suite v$SCRIPT_VERSION"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick)
                QUICK_TEST=true
                log "Quick test mode enabled"
                shift
                ;;
            --verbose)
                VERBOSE=true
                log "Verbose mode enabled"
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Check prerequisites
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is required but not installed"
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose is required but not available"
        exit 1
    fi

    # Setup test environment
    setup_test_environment

    # Set trap for cleanup
    trap cleanup_test_environment EXIT

    # Run test suites
    run_unit_tests
    run_docker_tests
    run_integration_tests

    # Print summary
    print_test_summary

    # Exit with appropriate code
    if [[ $FAILED_TESTS -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"
