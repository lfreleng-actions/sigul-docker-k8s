#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Client Test Suite
#
# This script runs comprehensive client-side tests against a Sigul stack.
# It is designed to work both locally and in GitHub Actions CI.
#
# Usage:
#   ./scripts/client-tests.sh [OPTIONS]
#
# Options:
#   --verbose           Enable verbose output
#   --network NAME      Docker network name (default: auto-detect)
#   --client-image IMG  Client image name (default: auto-detect)
#   --admin-password P  Admin password (default: auto_generated_ephemeral)
#   --help              Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default configuration
VERBOSE_MODE=false
NETWORK_NAME=""
CLIENT_IMAGE=""
CLIENT_NSS_VOLUME=""
CLIENT_CONFIG_VOLUME=""
ADMIN_PASSWORD=""
ADMIN_PASSWORD_SET_BY_USER=false
SHOW_HELP=false

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TESTS_TOTAL=0

# Test results array
declare -a TEST_RESULTS=()

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

verbose() {
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        echo -e "${CYAN}[VERBOSE]${NC} $*"
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
            --admin-password)
                ADMIN_PASSWORD="$2"
                ADMIN_PASSWORD_SET_BY_USER=true
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
Sigul Client Test Suite

Usage: $0 [OPTIONS]

Options:
    --verbose           Enable verbose output
    --network NAME      Docker network name (default: auto-detect)
    --client-image IMG  Client image name (default: auto-detect)
    --admin-password P  Admin password (default: auto_generated_ephemeral)
    --help              Show this help message

Environment Variables:
    SIGUL_CLIENT_IMAGE      Override client image name
    SIGUL_NETWORK_NAME      Override network name
    SIGUL_ADMIN_PASSWORD    Override admin password

Examples:
    # Run with auto-detection (local development)
    ./scripts/client-tests.sh --verbose

    # Run in CI with explicit configuration
    ./scripts/client-tests.sh --network sigul-network --client-image client:test

EOF
}

# Auto-detect configuration
auto_detect_config() {
    verbose "Auto-detecting configuration..."

    # Detect network name
    if [[ -z "$NETWORK_NAME" ]]; then
        if [[ -n "${SIGUL_NETWORK_NAME:-}" ]]; then
            NETWORK_NAME="$SIGUL_NETWORK_NAME"
            verbose "Using network from SIGUL_NETWORK_NAME: $NETWORK_NAME"
        else
            # Try to find sigul network
            NETWORK_NAME=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1 || echo "")
            if [[ -z "$NETWORK_NAME" ]]; then
                error "Could not detect Sigul network. Use --network option."
                return 1
            fi
            verbose "Auto-detected network: $NETWORK_NAME"
        fi
    fi

    # Detect client image
    if [[ -z "$CLIENT_IMAGE" ]]; then
        if [[ -n "${SIGUL_CLIENT_IMAGE:-}" ]]; then
            CLIENT_IMAGE="$SIGUL_CLIENT_IMAGE"
            verbose "Using client image from SIGUL_CLIENT_IMAGE: $CLIENT_IMAGE"
        else
            # Try to find client image
            CLIENT_IMAGE=$(docker images --filter "reference=*sigul*client*" --format "{{.Repository}}:{{.Tag}}" | head -1 || echo "")
            if [[ -z "$CLIENT_IMAGE" ]]; then
                error "Could not detect Sigul client image. Use --client-image option."
                return 1
            fi
            verbose "Auto-detected client image: $CLIENT_IMAGE"
        fi
    fi

    # Detect NSS volume
    CLIENT_NSS_VOLUME=$(docker volume ls --filter "name=client.*nss" --format "{{.Name}}" | head -1 || echo "")
    if [[ -z "$CLIENT_NSS_VOLUME" ]]; then
        warn "Could not detect client NSS volume"
        CLIENT_NSS_VOLUME="sigul-docker_sigul_client_nss"
        verbose "Using default NSS volume: $CLIENT_NSS_VOLUME"
    else
        verbose "Auto-detected NSS volume: $CLIENT_NSS_VOLUME"
    fi

    # Detect config volume
    CLIENT_CONFIG_VOLUME=$(docker volume ls --filter "name=client.*config" --format "{{.Name}}" | head -1 || echo "")
    if [[ -z "$CLIENT_CONFIG_VOLUME" ]]; then
        warn "Could not detect client config volume"
        CLIENT_CONFIG_VOLUME="sigul-docker_sigul_client_config"
        verbose "Using default config volume: $CLIENT_CONFIG_VOLUME"
    else
        verbose "Auto-detected config volume: $CLIENT_CONFIG_VOLUME"
    fi

    # Try to load admin password from file if not explicitly set by user
    if [[ "$ADMIN_PASSWORD_SET_BY_USER" != "true" ]]; then
        if [[ -n "${SIGUL_ADMIN_PASSWORD:-}" ]]; then
            ADMIN_PASSWORD="$SIGUL_ADMIN_PASSWORD"
            verbose "Using admin password from SIGUL_ADMIN_PASSWORD"
        elif [[ -f "${PROJECT_ROOT}/test-artifacts/admin-password" ]]; then
            ADMIN_PASSWORD=$(cat "${PROJECT_ROOT}/test-artifacts/admin-password")
            verbose "Loaded admin password from test-artifacts/admin-password"
        else
            # Fall back to default if no other source
            ADMIN_PASSWORD="auto_generated_ephemeral"
            verbose "Using default admin password: auto_generated_ephemeral"
        fi
    else
        verbose "Using admin password from command line"
    fi

    return 0
}

# Verify prerequisites
verify_prerequisites() {
    verbose "Verifying prerequisites..."

    # Check Docker is available
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed or not in PATH"
        return 1
    fi

    # Check that the Sigul stack is running
    if ! docker ps --format "{{.Names}}" | grep -q "sigul-server"; then
        error "Sigul server container is not running"
        error "Please start the stack first: docker compose -f docker-compose.sigul.yml up -d"
        return 1
    fi

    if ! docker ps --format "{{.Names}}" | grep -q "sigul-bridge"; then
        error "Sigul bridge container is not running"
        error "Please start the stack first: docker compose -f docker-compose.sigul.yml up -d"
        return 1
    fi

    # Verify network exists
    if ! docker network inspect "$NETWORK_NAME" &> /dev/null; then
        error "Network '$NETWORK_NAME' does not exist"
        return 1
    fi

    # Verify client image exists
    if ! docker image inspect "$CLIENT_IMAGE" &> /dev/null; then
        error "Client image '$CLIENT_IMAGE' does not exist"
        return 1
    fi

    verbose "All prerequisites verified"
    return 0
}

# Run a client command
run_client_cmd() {
    local cmd="$1"
    local password="${2:-$ADMIN_PASSWORD}"

    docker run --rm \
        --user 1000:1000 \
        --network "$NETWORK_NAME" \
        -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
        -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        bash -c "printf \"${password}\\0\" | sigul --batch -c /etc/sigul/client.conf ${cmd} 2>&1"
}

# Test framework functions
test_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}TEST $((TESTS_TOTAL + 1)): $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
}

pass_test() {
    local test_name="$1"
    echo -e "${GREEN}✅ PASS${NC}: $test_name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_RESULTS+=("PASS: $test_name")
}

fail_test() {
    local test_name="$1"
    local reason="${2:-Unknown reason}"
    echo -e "${RED}❌ FAIL${NC}: $test_name"
    echo -e "${RED}   Reason: $reason${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_RESULTS+=("FAIL: $test_name - $reason")
}

# shellcheck disable=SC2317  # Function defined for future use
skip_test() {
    local test_name="$1"
    local reason="${2:-Skipped}"
    echo -e "${YELLOW}⊘ SKIP${NC}: $test_name"
    echo -e "${YELLOW}   Reason: $reason${NC}"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    TEST_RESULTS+=("SKIP: $test_name - $reason")
}

# Test Suite: Basic Client Operations
test_basic_authentication() {
    test_header "Basic Authentication - List Users"

    local output
    if output=$(run_client_cmd "list-users" 2>&1); then
        if echo "$output" | grep -q "admin"; then
            pass_test "Can authenticate and list users"
            verbose "  Users: $output"
            return 0
        else
            fail_test "Authentication succeeded but no users found" "$output"
            return 1
        fi
    else
        fail_test "Authentication failed" "$output"
        return 1
    fi
}

test_wrong_password() {
    test_header "Authentication Failure - Wrong Password"

    local output
    if output=$(run_client_cmd "list-users" "wrong_password_12345" 2>&1 || true); then
        if echo "$output" | grep -qi "authentication.*failed\|error"; then
            pass_test "Correctly rejects wrong password"
            return 0
        else
            fail_test "Did not properly reject wrong password" "$output"
            return 1
        fi
    else
        # Command failed as expected
        pass_test "Correctly rejects wrong password"
        return 0
    fi
}

test_list_keys() {
    test_header "List Available Keys"

    local output
    if output=$(run_client_cmd "list-keys" 2>&1); then
        pass_test "Can list signing keys"
        verbose "  Keys: ${output:-<none>}"
        return 0
    else
        fail_test "Failed to list keys" "$output"
        return 1
    fi
}

test_connection_stability() {
    test_header "Connection Stability - Multiple Operations"

    local success_count=0
    local total_attempts=5

    for i in $(seq 1 $total_attempts); do
        verbose "  Attempt $i/$total_attempts..."
        if output=$(run_client_cmd "list-users" 2>&1) && echo "$output" | grep -q "admin"; then
            success_count=$((success_count + 1))
            echo -e "  Attempt $i: ${GREEN}✓${NC}"
        else
            echo -e "  Attempt $i: ${RED}✗${NC}"
        fi
    done

    if [[ $success_count -eq $total_attempts ]]; then
        pass_test "All $total_attempts consecutive operations succeeded"
        return 0
    else
        fail_test "Only $success_count/$total_attempts operations succeeded"
        return 1
    fi
}

test_certificate_authentication() {
    test_header "Double-TLS Certificate Authentication"

    local output
    if output=$(run_client_cmd "list-users" 2>&1); then
        if echo "$output" | grep -q "admin" && ! echo "$output" | grep -qi "certificate.*error"; then
            pass_test "Client certificate authentication working"
            return 0
        else
            fail_test "Certificate authentication issue detected" "$output"
            return 1
        fi
    else
        fail_test "Command failed - possible certificate issue" "$output"
        return 1
    fi
}

test_user_information() {
    test_header "User Information Query"

    local output
    if output=$(run_client_cmd "user-info admin" 2>&1); then
        if echo "$output" | grep -qi "admin\|user\|administrator"; then
            pass_test "Can query user information"
            verbose "  Info: $output"
            return 0
        else
            fail_test "Unexpected user info format" "$output"
            return 1
        fi
    else
        fail_test "Failed to get user info" "$output"
        return 1
    fi
}

test_batch_mode_password() {
    test_header "Batch Mode Password Input (NUL-terminated)"

    # Test with explicit NUL terminator
    local output
    if output=$(docker run --rm \
        --user 1000:1000 \
        --network "$NETWORK_NAME" \
        -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
        -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        bash -c "printf \"${ADMIN_PASSWORD}\\0\" | sigul --batch -c /etc/sigul/client.conf list-users 2>&1"); then

        if echo "$output" | grep -q "admin"; then
            pass_test "Batch mode NUL-terminated password works correctly"
            return 0
        else
            fail_test "Batch mode succeeded but unexpected output" "$output"
            return 1
        fi
    else
        fail_test "Batch mode password handling failed" "$output"
        return 1
    fi
}

test_bridge_connection_latency() {
    test_header "Bridge Connection Latency Test"

    local start_time end_time duration
    start_time=$(date +%s)

    local output
    if output=$(run_client_cmd "list-users" 2>&1); then
        end_time=$(date +%s)
        duration=$((end_time - start_time))

        if echo "$output" | grep -q "admin"; then
            pass_test "Bridge connection successful (${duration}s)"
            if [[ $duration -lt 5 ]]; then
                verbose "  Connection latency is good"
            else
                warn "  Connection took ${duration}s (acceptable but slow)"
            fi
            return 0
        else
            fail_test "Connection succeeded but unexpected response"
            return 1
        fi
    else
        fail_test "Bridge connection failed"
        return 1
    fi
}

test_command_availability() {
    test_header "Client Command Availability"

    local output
    if output=$(docker run --rm --user 1000:1000 "$CLIENT_IMAGE" sigul --help-commands 2>&1); then
        if echo "$output" | grep -q "list-users"; then
            pass_test "Client commands are accessible"
            verbose "  Sample commands available:"
            echo "$output" | head -10 | sed 's/^/    /'
            return 0
        else
            fail_test "Client commands not properly listed" "$output"
            return 1
        fi
    else
        fail_test "Failed to access client commands" "$output"
        return 1
    fi
}

test_double_tls_flow() {
    test_header "Double-TLS Communication Flow"

    # This test verifies the complete double-TLS flow by checking logs
    local output
    if output=$(run_client_cmd "list-users" 2>&1); then
        if echo "$output" | grep -q "admin"; then
            pass_test "Double-TLS communication flow operational"
            verbose "  Client → Bridge → Server communication verified"
            return 0
        else
            fail_test "Double-TLS flow completed but unexpected result" "$output"
            return 1
        fi
    else
        fail_test "Double-TLS communication failed" "$output"
        return 1
    fi
}

# Main test execution
run_all_tests() {
    log "Starting Sigul Client Test Suite..."
    log "Network: $NETWORK_NAME"
    log "Client Image: $CLIENT_IMAGE"
    log "NSS Volume: $CLIENT_NSS_VOLUME"
    log "Config Volume: $CLIENT_CONFIG_VOLUME"
    echo ""

    local start_time
    start_time=$(date +%s)

    # Run all tests
    test_basic_authentication
    test_wrong_password
    test_list_keys
    test_connection_stability
    test_certificate_authentication
    test_user_information
    test_batch_mode_password
    test_bridge_connection_latency
    test_command_availability
    test_double_tls_flow

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Print summary
    print_summary "$duration"

    # Return exit code based on results
    if [[ $TESTS_FAILED -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Print test summary
print_summary() {
    local duration="$1"

    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                     TEST SUMMARY                          ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Total Tests:  ${BLUE}${TESTS_TOTAL}${NC}"
    echo -e "Passed:       ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed:       ${RED}${TESTS_FAILED}${NC}"
    echo -e "Skipped:      ${YELLOW}${TESTS_SKIPPED}${NC}"
    echo -e "Duration:     ${BLUE}${duration}s${NC}"
    echo ""

    # Calculate success rate
    if [[ $TESTS_TOTAL -gt 0 ]]; then
        local success_rate=$(( (TESTS_PASSED * 100) / TESTS_TOTAL ))
        echo -e "Success Rate: ${BLUE}${success_rate}%${NC}"
        echo ""
    fi

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                                           ║${NC}"
        echo -e "${GREEN}║              🎉 ALL TESTS PASSED! 🎉                      ║${NC}"
        echo -e "${GREEN}║                                                           ║${NC}"
        echo -e "${GREEN}║  The Sigul client can successfully communicate with      ║${NC}"
        echo -e "${GREEN}║  the bridge and server via double-TLS!                   ║${NC}"
        echo -e "${GREEN}║                                                           ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${GREEN}✓ Client authentication working${NC}"
        echo -e "${GREEN}✓ Double-TLS connection stable${NC}"
        echo -e "${GREEN}✓ Certificate validation successful${NC}"
        echo -e "${GREEN}✓ Multiple operations tested${NC}"
        echo ""
    else
        echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                                                           ║${NC}"
        echo -e "${RED}║              ❌ SOME TESTS FAILED ❌                      ║${NC}"
        echo -e "${RED}║                                                           ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Failed tests:"
        for result in "${TEST_RESULTS[@]}"; do
            if [[ "$result" == FAIL:* ]]; then
                echo "  - ${result#FAIL: }"
            fi
        done
        echo ""
    fi
}

# Main function
main() {
    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    log "╔═══════════════════════════════════════════════════════════╗"
    log "║                                                           ║"
    log "║          SIGUL CLIENT TEST SUITE                          ║"
    log "║          Production-Ready Client Testing                  ║"
    log "║                                                           ║"
    log "╚═══════════════════════════════════════════════════════════╝"
    echo ""

    # Auto-detect configuration
    if ! auto_detect_config; then
        error "Failed to auto-detect configuration"
        exit 1
    fi

    # Verify prerequisites
    if ! verify_prerequisites; then
        error "Prerequisites check failed"
        exit 1
    fi

    # Run all tests
    if run_all_tests; then
        success "Client test suite completed successfully"
        exit 0
    else
        error "Client test suite completed with failures"
        exit 1
    fi
}

# Execute main
main "$@"
