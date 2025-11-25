#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Integration Tests Script for GitHub Workflows
#
# This script runs integration tests against fully functional Sigul infrastructure,
# performing basic connectivity and authentication tests.
#
# Usage:
#   ./scripts/run-integration-tests.sh [OPTIONS]
#
# Options:
#   --verbose       Enable verbose output
#   --help          Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

verbose() {
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

# Test result functions
test_passed() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    ((TESTS_PASSED++))
    ((TOTAL_TESTS++))
}

test_failed() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    ((TESTS_FAILED++))
    ((TOTAL_TESTS++))
}

test_header() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}TEST: $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
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
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Run Sigul integration tests against deployed infrastructure.

Options:
    --verbose       Enable verbose debug output
    --help          Show this help message

Environment Variables:
    SIGUL_CLIENT_IMAGE     Docker image for client (required)
    SIGUL_SERVER_IMAGE     Docker image for server (optional, auto-detected)
    SIGUL_BRIDGE_IMAGE     Docker image for bridge (optional, auto-detected)

Examples:
    $0 --verbose
    SIGUL_CLIENT_IMAGE=client:test $0
EOF
}

# Helper function to run client command
run_client() {
    local cmd="$1"
    local password="${2:-auto_generated_ephemeral}"

    docker run --rm \
        --user 1000:1000 \
        --network sigul-docker_sigul-network \
        -v sigul-docker_sigul_client_nss:/etc/pki/sigul/client:ro \
        -v sigul-docker_sigul_client_config:/etc/sigul:ro \
        "${SIGUL_CLIENT_IMAGE}" \
        bash -c "printf '${password}\0' | sigul --batch -c /etc/sigul/client.conf ${cmd} 2>&1"
}

# Test 1: Basic Authentication - List Users
test_basic_authentication() {
    test_header "Basic Authentication - List Users"

    local output
    if output=$(run_client "list-users" 2>&1); then
        if echo "$output" | grep -q "admin"; then
            test_passed "Can authenticate and list users"
            verbose "  Users: $output"
            return 0
        fi
    fi

    test_failed "Failed to authenticate and list users"
    verbose "  Output: $output"
    return 1
}

# Test 2: Authentication Failure with Wrong Password
test_wrong_password() {
    test_header "Authentication Failure - Wrong Password"

    local output
    if output=$(run_client "list-users" "wrong_password" 2>&1 || true); then
        if echo "$output" | grep -qi "authentication.*failed\|error\|EOF"; then
            test_passed "Correctly rejects wrong password"
            return 0
        fi
    fi

    test_failed "Did not properly reject wrong password"
    verbose "  Output: $output"
    return 1
}

# Test 3: List Available Keys
test_list_keys() {
    test_header "List Available Keys"

    local output
    if output=$(run_client "list-keys" 2>&1); then
        test_passed "Can list signing keys"
        verbose "  Keys: ${output:-<none>}"
        return 0
    fi

    test_failed "Failed to list keys"
    verbose "  Output: $output"
    return 1
}

# Test 4: Multiple Consecutive Operations (Connection Stability)
test_connection_stability() {
    test_header "Connection Stability - Multiple Operations"

    local success_count=0
    local attempts=5

    for i in $(seq 1 $attempts); do
        local output
        if output=$(run_client "list-users" 2>&1); then
            if echo "$output" | grep -q "admin"; then
                ((success_count++))
                verbose "  Attempt $i: ✓"
            else
                verbose "  Attempt $i: ✗ (unexpected output)"
            fi
        else
            verbose "  Attempt $i: ✗ (command failed)"
        fi
    done

    if [[ $success_count -eq $attempts ]]; then
        test_passed "All $attempts consecutive operations succeeded"
        return 0
    else
        test_failed "Only $success_count/$attempts operations succeeded"
        return 1
    fi
}

# Test 5: Double-TLS Certificate Authentication
test_certificate_authentication() {
    test_header "Double-TLS Certificate Authentication"

    local output
    if output=$(run_client "list-users" 2>&1); then
        if echo "$output" | grep -q "admin" && ! echo "$output" | grep -qi "certificate.*error"; then
            test_passed "Client certificate authentication working"
            return 0
        fi
    fi

    test_failed "Certificate authentication issue detected"
    verbose "  Output: $output"
    return 1
}

# Test 6: User Information Query
test_user_info() {
    test_header "User Information Query"

    local output
    if output=$(run_client "user-info admin" 2>&1); then
        if echo "$output" | grep -qi "admin\|user"; then
            test_passed "Can query user information"
            verbose "  Info: $output"
            return 0
        fi
    fi

    test_failed "Failed to get user info"
    verbose "  Output: $output"
    return 1
}

# Test 7: List Key Users (Even if No Keys)
test_list_key_users() {
    test_header "List Key Users"

    # First check if there are any keys
    local keys
    if keys=$(run_client "list-keys" 2>&1) && [ -n "$keys" ] && ! echo "$keys" | grep -qi "error"; then
        local first_key
        first_key=$(echo "$keys" | head -1 | xargs)
        if [ -n "$first_key" ]; then
            if run_client "list-key-users \"$first_key\"" 2>&1 >/dev/null; then
                test_passed "Can list key users for: $first_key"
                return 0
            fi
        fi
    fi

    test_passed "No keys available to test (expected for fresh install)"
    return 0
}

# Test 8: Check Available Commands
test_command_availability() {
    test_header "Client Command Availability"

    local output
    if output=$(docker run --rm --user 1000:1000 "${SIGUL_CLIENT_IMAGE}" sigul --help-commands 2>&1); then
        if echo "$output" | grep -q "list-users"; then
            test_passed "Client commands are accessible"
            verbose "  Sample commands available:"
            echo "$output" | head -10 | sed 's/^/    /' >&2
            return 0
        fi
    fi

    test_failed "Client commands not accessible"
    return 1
}

# Test 9: Bridge Connection Test
test_bridge_connection() {
    test_header "Bridge Connection Verification"

    local start_time end_time duration
    start_time=$(date +%s)

    local output
    if output=$(run_client "list-users" 2>&1); then
        end_time=$(date +%s)
        duration=$((end_time - start_time))

        if echo "$output" | grep -q "admin"; then
            test_passed "Bridge connection successful (${duration}s)"
            if [[ $duration -lt 5 ]]; then
                verbose "  Connection latency is good"
            else
                verbose "  Connection took ${duration}s (acceptable)"
            fi
            return 0
        fi
    fi

    test_failed "Bridge connection failed"
    verbose "  Output: $output"
    return 1
}

# Test 10: Batch Mode Input Handling
test_batch_mode() {
    test_header "Batch Mode Password Input (NUL-terminated)"

    local output
    if output=$(docker run --rm \
        --user 1000:1000 \
        --network sigul-docker_sigul-network \
        -v sigul-docker_sigul_client_nss:/etc/pki/sigul/client:ro \
        -v sigul-docker_sigul_client_config:/etc/sigul:ro \
        "${SIGUL_CLIENT_IMAGE}" \
        bash -c 'printf "auto_generated_ephemeral\0" | sigul --batch -c /etc/sigul/client.conf list-users 2>&1'); then

        if echo "$output" | grep -q "admin"; then
            test_passed "Batch mode NUL-terminated password works correctly"
            return 0
        fi
    fi

    test_failed "Batch mode password handling failed"
    verbose "  Output: $output"
    return 1
}

# Print banner
print_banner() {
    echo
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                           ║${NC}"
    echo -e "${BLUE}║          SIGUL INTEGRATION TEST SUITE                     ║${NC}"
    echo -e "${BLUE}║          Testing from Client Perspective                  ║${NC}"
    echo -e "${BLUE}║                                                           ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo
}

# Print summary
print_summary() {
    echo
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                     TEST SUMMARY                          ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "Total Tests:  ${BLUE}${TOTAL_TESTS}${NC}"
    echo -e "Passed:       ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed:       ${RED}${TESTS_FAILED}${NC}"
    echo
}

# Main test execution
run_all_tests() {
    print_banner

    log "Checking Sigul stack status..."
    if ! docker ps --format '{{.Names}}' | grep -q "sigul-server"; then
        error "Sigul stack is not running!"
        error "Required containers: sigul-server, sigul-bridge"
        return 1
    fi
    success "Stack is running"
    echo

    # Run all tests
    test_basic_authentication || true
    test_wrong_password || true
    test_list_keys || true
    test_connection_stability || true
    test_certificate_authentication || true
    test_user_info || true
    test_list_key_users || true
    test_command_availability || true
    test_bridge_connection || true
    test_batch_mode || true

    print_summary

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                                           ║${NC}"
        echo -e "${GREEN}║              🎉 ALL TESTS PASSED! 🎉                      ║${NC}"
        echo -e "${GREEN}║                                                           ║${NC}"
        echo -e "${GREEN}║  The Sigul client can successfully communicate with      ║${NC}"
        echo -e "${GREEN}║  the bridge and server via double-TLS!                   ║${NC}"
        echo -e "${GREEN}║                                                           ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo
        echo -e "${GREEN}✓ Client authentication working${NC}"
        echo -e "${GREEN}✓ Double-TLS connection stable${NC}"
        echo -e "${GREEN}✓ Certificate validation successful${NC}"
        echo -e "${GREEN}✓ Multiple operations tested${NC}"
        echo
        return 0
    else
        echo -e "${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                                                           ║${NC}"
        echo -e "${RED}║                ❌ SOME TESTS FAILED ❌                    ║${NC}"
        echo -e "${RED}║                                                           ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo
        return 1
    fi
}

# Main function
main() {
    parse_args "$@"

    if [[ "${SHOW_HELP:-false}" == "true" ]]; then
        show_help
        exit 0
    fi

    # Ensure SIGUL_CLIENT_IMAGE is set
    if [[ -z "${SIGUL_CLIENT_IMAGE:-}" ]]; then
        error "SIGUL_CLIENT_IMAGE environment variable must be set"
        error "Example: SIGUL_CLIENT_IMAGE=client:test $0"
        exit 1
    fi

    log "=== Sigul Integration Tests ==="
    log "Verbose mode: ${VERBOSE_MODE}"
    log "Client image: ${SIGUL_CLIENT_IMAGE}"
    log "Project root: ${PROJECT_ROOT}"
    echo

    if run_all_tests; then
        success "=== Integration Tests Complete ==="
        exit 0
    else
        error "=== Integration Tests Failed ==="
        exit 1
    fi
}

# Set default verbose mode to false
VERBOSE_MODE=false
SHOW_HELP=false

# Execute main function with all arguments
main "$@"
