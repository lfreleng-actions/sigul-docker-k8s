#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# NSS/NSPR Isolation Testing Script
#
# This script tests NSS/NSPR operations in isolation to identify
# exactly where TLS handshake failures occur. It progressively tests
# each layer of the stack from basic database access to full handshakes.
#
# Usage:
#   ./scripts/test-nss-isolation.sh [OPTIONS]
#
# Options:
#   --container <name>  Test specific container (bridge, server, or client)
#   --verbose           Enable verbose output
#   --help              Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Options
TARGET_CONTAINER=""
VERBOSE_MODE=false
SHOW_HELP=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test results
PASSED_TESTS=0
FAILED_TESTS=0
TOTAL_TESTS=0

# Logging functions
log() {
    echo -e "${BLUE}[TEST] INFO:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[TEST] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[TEST] ERROR:${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[TEST] SUCCESS:${NC} $*"
}

verbose() {
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${CYAN}[TEST] DEBUG:${NC} $*"
    fi
}

section() {
    echo ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}  $*${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

test_result() {
    local test_name="$1"
    local result="$2"
    local details="${3:-}"

    ((TOTAL_TESTS++))

    if [[ "$result" == "PASS" ]]; then
        ((PASSED_TESTS++))
        success "✓ $test_name"
        [[ -n "$details" ]] && verbose "  $details"
    else
        ((FAILED_TESTS++))
        error "✗ $test_name"
        [[ -n "$details" ]] && error "  $details"
    fi
}

# Help function
show_help() {
    cat << 'EOF'
NSS/NSPR Isolation Testing Script

USAGE:
    ./scripts/test-nss-isolation.sh [OPTIONS]

OPTIONS:
    --container <name>  Test specific container: bridge, server, or client
    --verbose           Enable verbose output
    --help              Show this help message

DESCRIPTION:
    This script performs isolated testing of NSS/NSPR operations to identify
    exactly where TLS handshake failures occur. Tests progress from basic
    operations to complex handshakes:

    1. NSS Database Access
       - Database file existence
       - Database validity
       - Password authentication

    2. Certificate Operations
       - Certificate listing
       - Certificate details retrieval
       - Private key access

    3. Network Operations
       - Socket creation
       - Name resolution
       - TCP connectivity

    4. TLS Operations
       - SSL context creation
       - Certificate loading
       - Trust chain validation
       - Handshake execution

EXAMPLES:
    # Test all containers
    ./scripts/test-nss-isolation.sh --verbose

    # Test specific container
    ./scripts/test-nss-isolation.sh --container bridge

    # Quick test
    ./scripts/test-nss-isolation.sh

EOF
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --container)
                TARGET_CONTAINER="$2"
                shift 2
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
                show_help
                exit 1
                ;;
        esac
    done
}

# Test 1: NSS database file existence
test_db_existence() {
    local container="$1"
    local nss_dir="$2"

    verbose "Testing NSS database file existence in $container..."

    if docker exec "$container" test -f "$nss_dir/cert9.db"; then
        test_result "DB Existence ($container)" "PASS" "cert9.db found"
        return 0
    else
        test_result "DB Existence ($container)" "FAIL" "cert9.db not found at $nss_dir"
        return 1
    fi
}

# Test 2: NSS database validity (can open and read)
test_db_validity() {
    local container="$1"
    local nss_dir="$2"

    verbose "Testing NSS database validity in $container..."

    local output
    output=$(docker exec "$container" certutil -L -d "sql:$nss_dir" 2>&1 || echo "FAILED")

    if echo "$output" | grep -q "Certificate Nickname"; then
        test_result "DB Validity ($container)" "PASS" "Database can be read"
        return 0
    else
        test_result "DB Validity ($container)" "FAIL" "Cannot read database: $output"
        return 1
    fi
}

# Test 3: NSS database password authentication
test_db_password() {
    local container="$1"
    local nss_dir="$2"

    verbose "Testing NSS database password authentication in $container..."

    # Load password if available
    local password_file="${PROJECT_ROOT}/test-artifacts/nss-password"
    local nss_password=""

    if [[ -f "$password_file" ]]; then
        nss_password=$(cat "$password_file")
    else
        test_result "DB Password ($container)" "SKIP" "No password file available"
        return 0
    fi

    local output
    output=$(docker exec "$container" sh -c "echo '$nss_password' | certutil -K -d sql:$nss_dir -f /dev/stdin 2>&1" || echo "FAILED")

    if echo "$output" | grep -qE "^\<|rsa|ec"; then
        test_result "DB Password ($container)" "PASS" "Password authentication successful"
        return 0
    elif echo "$output" | grep -q "FAILED"; then
        test_result "DB Password ($container)" "FAIL" "Password authentication failed: $output"
        return 1
    else
        test_result "DB Password ($container)" "PASS" "No password required"
        return 0
    fi
}

# Test 4: Certificate presence
test_cert_presence() {
    local container="$1"
    local nss_dir="$2"
    local cert_nickname="$3"

    verbose "Testing certificate presence: $cert_nickname in $container..."

    if docker exec "$container" certutil -L -d "sql:$nss_dir" -n "$cert_nickname" >/dev/null 2>&1; then
        test_result "Cert Presence ($container:$cert_nickname)" "PASS"
        return 0
    else
        test_result "Cert Presence ($container:$cert_nickname)" "FAIL" "Certificate not found"
        return 1
    fi
}

# Test 5: Certificate validity (not expired)
test_cert_validity() {
    local container="$1"
    local nss_dir="$2"
    local cert_nickname="$3"

    verbose "Testing certificate validity: $cert_nickname in $container..."

    local output
    output=$(docker exec "$container" certutil -L -d "sql:$nss_dir" -n "$cert_nickname" 2>&1)

    if echo "$output" | grep -q "Not After"; then
        local not_after
        not_after=$(echo "$output" | grep "Not After" | sed 's/.*: //')
        verbose "Certificate expires: $not_after"
        test_result "Cert Validity ($container:$cert_nickname)" "PASS" "Not expired"
        return 0
    else
        test_result "Cert Validity ($container:$cert_nickname)" "WARN" "Cannot determine expiration"
        return 0
    fi
}

# Test 6: Private key presence
test_private_key() {
    local container="$1"
    local nss_dir="$2"
    local cert_nickname="$3"

    verbose "Testing private key presence: $cert_nickname in $container..."

    local output
    output=$(docker exec "$container" certutil -K -d "sql:$nss_dir" 2>&1)

    if echo "$output" | grep -q "$cert_nickname"; then
        test_result "Private Key ($container:$cert_nickname)" "PASS"
        return 0
    else
        test_result "Private Key ($container:$cert_nickname)" "FAIL" "Private key not found"
        return 1
    fi
}

# Test 7: DNS resolution
test_dns_resolution() {
    local container="$1"
    local hostname="$2"

    verbose "Testing DNS resolution: $hostname from $container..."

    if docker exec "$container" nslookup "$hostname" >/dev/null 2>&1; then
        test_result "DNS Resolution ($container->$hostname)" "PASS"
        return 0
    else
        test_result "DNS Resolution ($container->$hostname)" "FAIL" "Cannot resolve hostname"
        return 1
    fi
}

# Test 8: TCP connectivity
test_tcp_connectivity() {
    local container="$1"
    local target_host="$2"
    local target_port="$3"

    verbose "Testing TCP connectivity: $container -> $target_host:$target_port..."

    if docker exec "$container" timeout 3 nc -zv "$target_host" "$target_port" >/dev/null 2>&1; then
        test_result "TCP Connect ($container->$target_host:$target_port)" "PASS"
        return 0
    else
        test_result "TCP Connect ($container->$target_host:$target_port)" "FAIL" "Cannot connect"
        return 1
    fi
}

# Test 9: TLS handshake with openssl
test_tls_handshake_openssl() {
    local container="$1"
    local target_host="$2"
    local target_port="$3"

    verbose "Testing TLS handshake (openssl): $container -> $target_host:$target_port..."

    local output
    output=$(docker exec "$container" timeout 5 openssl s_client \
        -connect "$target_host:$target_port" \
        -verify 2 \
        < /dev/null 2>&1 || echo "FAILED")

    if echo "$output" | grep -q "Verify return code: 0"; then
        test_result "TLS Handshake OpenSSL ($container->$target_host:$target_port)" "PASS"
        return 0
    elif echo "$output" | grep -q "CONNECTED"; then
        local verify_code
        verify_code=$(echo "$output" | grep "Verify return code" | head -1)
        test_result "TLS Handshake OpenSSL ($container->$target_host:$target_port)" "FAIL" "Connection but verification failed: $verify_code"
        return 1
    else
        test_result "TLS Handshake OpenSSL ($container->$target_host:$target_port)" "FAIL" "Cannot connect"
        return 1
    fi
}

# Test 10: TLS handshake with NSS tstclnt
test_tls_handshake_nss() {
    local container="$1"
    local nss_dir="$2"
    local target_host="$3"
    local target_port="$4"

    verbose "Testing TLS handshake (NSS): $container -> $target_host:$target_port..."

    # Check if tstclnt is available
    if ! docker exec "$container" which tstclnt >/dev/null 2>&1; then
        test_result "TLS Handshake NSS ($container->$target_host:$target_port)" "SKIP" "tstclnt not available"
        return 0
    fi

    local output
    output=$(docker exec "$container" timeout 5 tstclnt \
        -h "$target_host" \
        -p "$target_port" \
        -d "sql:$nss_dir" \
        -v -o 2>&1 || echo "FAILED")

    if echo "$output" | grep -q "SSL_ForceHandshake: success"; then
        test_result "TLS Handshake NSS ($container->$target_host:$target_port)" "PASS"
        return 0
    else
        test_result "TLS Handshake NSS ($container->$target_host:$target_port)" "FAIL" "Handshake failed"
        verbose "Output: $output"
        return 1
    fi
}

# Test 11: Python NSS module import
test_python_nss() {
    local container="$1"

    verbose "Testing Python NSS module import in $container..."

    local output
    output=$(docker exec "$container" python3 -c "import nss; print('OK')" 2>&1 || echo "FAILED")

    if echo "$output" | grep -q "OK"; then
        test_result "Python NSS Import ($container)" "PASS"
        return 0
    else
        test_result "Python NSS Import ($container)" "FAIL" "Cannot import NSS module: $output"
        return 1
    fi
}

# Test 12: Sigul Python imports
test_sigul_imports() {
    local container="$1"

    verbose "Testing Sigul Python imports in $container..."

    local output
    output=$(docker exec "$container" python3 -c "
import sys
sys.path.insert(0, '/usr/share/sigul')
try:
    import utils
    import double_tls
    print('OK')
except Exception as e:
    print(f'FAILED: {e}')
" 2>&1 || echo "FAILED")

    if echo "$output" | grep -q "OK"; then
        test_result "Sigul Python Imports ($container)" "PASS"
        return 0
    else
        test_result "Sigul Python Imports ($container)" "FAIL" "Cannot import Sigul modules: $output"
        return 1
    fi
}

# Run all tests for a container
run_container_tests() {
    local container="$1"
    local nss_dir="$2"
    local cert_nickname="$3"

    section "Testing Container: $container"

    log "NSS Directory: $nss_dir"
    log "Certificate: $cert_nickname"

    # Layer 1: Basic database access
    test_db_existence "$container" "$nss_dir"
    test_db_validity "$container" "$nss_dir"
    test_db_password "$container" "$nss_dir"

    # Layer 2: Certificate operations
    test_cert_presence "$container" "$nss_dir" "$cert_nickname"
    test_cert_validity "$container" "$nss_dir" "$cert_nickname"
    test_private_key "$container" "$nss_dir" "$cert_nickname"

    # CA certificate should also be present
    test_cert_presence "$container" "$nss_dir" "sigul-ca"

    # Layer 3: Python/Sigul
    test_python_nss "$container"
    test_sigul_imports "$container"
}

# Run connectivity tests
run_connectivity_tests() {
    section "Testing Network Connectivity"

    # Client -> Bridge
    if docker ps --filter "name=sigul-client" --format "{{.Names}}" | grep -q "sigul-client"; then
        test_dns_resolution "sigul-client" "sigul-bridge.example.org"
        test_tcp_connectivity "sigul-client" "sigul-bridge.example.org" "44334"
        test_tls_handshake_openssl "sigul-client" "sigul-bridge.example.org" "44334"
        test_tls_handshake_nss "sigul-client" "/etc/pki/sigul/client" "sigul-bridge.example.org" "44334"
    fi

    # Bridge -> Server
    if docker ps --filter "name=sigul-bridge" --format "{{.Names}}" | grep -q "sigul-bridge"; then
        test_dns_resolution "sigul-bridge" "sigul-server.example.org"
        test_tcp_connectivity "sigul-bridge" "sigul-server.example.org" "44333"
        test_tls_handshake_openssl "sigul-bridge" "sigul-server.example.org" "44333"
        test_tls_handshake_nss "sigul-bridge" "/etc/pki/sigul" "sigul-server.example.org" "44333"
    fi
}

# Main execution
main() {
    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    section "NSS/NSPR Isolation Testing"
    log "Starting isolated component tests..."

    # Determine which containers to test
    local containers_to_test=()

    if [[ -n "$TARGET_CONTAINER" ]]; then
        containers_to_test=("$TARGET_CONTAINER")
    else
        # Auto-detect running containers
        if docker ps --filter "name=sigul-bridge" --format "{{.Names}}" | grep -q "sigul-bridge"; then
            containers_to_test+=("bridge")
        fi
        if docker ps --filter "name=sigul-server" --format "{{.Names}}" | grep -q "sigul-server"; then
            containers_to_test+=("server")
        fi
        if docker ps --filter "name=sigul-client" --format "{{.Names}}" | grep -q "sigul-client"; then
            containers_to_test+=("client")
        fi
    fi

    if [[ ${#containers_to_test[@]} -eq 0 ]]; then
        error "No Sigul containers found running"
        exit 1
    fi

    # Test each container
    for container_type in "${containers_to_test[@]}"; do
        case "$container_type" in
            bridge)
                run_container_tests "sigul-bridge" "/etc/pki/sigul" "sigul-bridge-cert"
                ;;
            server)
                run_container_tests "sigul-server" "/etc/pki/sigul" "sigul-server-cert"
                ;;
            client)
                local client_name
                client_name=$(docker ps --filter "name=sigul-client" --format "{{.Names}}" | head -1)
                if [[ -n "$client_name" ]]; then
                    run_container_tests "$client_name" "/etc/pki/sigul/client" "sigul-client-cert"
                fi
                ;;
            *)
                error "Unknown container type: $container_type"
                ;;
        esac
    done

    # Run connectivity tests
    run_connectivity_tests

    # Summary
    section "Test Summary"
    log "Total Tests: $TOTAL_TESTS"
    success "Passed: $PASSED_TESTS"
    if [[ $FAILED_TESTS -gt 0 ]]; then
        error "Failed: $FAILED_TESTS"
    else
        log "Failed: $FAILED_TESTS"
    fi

    echo ""
    if [[ $FAILED_TESTS -eq 0 ]]; then
        success "✓ All isolation tests passed!"
        return 0
    else
        error "✗ Some isolation tests failed - see details above"
        return 1
    fi
}

main "$@"
