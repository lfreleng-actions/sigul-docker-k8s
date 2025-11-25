#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul TLS Stack Debugging Script
#
# Comprehensive diagnostics for NSS/NSPR "Unexpected EOF" errors
# and TLS handshake failures in the Sigul container stack.
#
# Usage:
#   ./scripts/debug-tls-stack.sh [OPTIONS]
#
# Options:
#   --verbose       Enable verbose output
#   --all           Run all diagnostic tests
#   --certs         Check certificate setup only
#   --connectivity  Test network connectivity only
#   --tls           Test TLS handshakes only
#   --nss           Test NSS database access only
#   --full-trace    Enable full NSS/NSPR trace logging
#   --help          Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default options
VERBOSE_MODE=false
RUN_ALL=false
CHECK_CERTS=false
CHECK_CONNECTIVITY=false
CHECK_TLS=false
CHECK_NSS=false
FULL_TRACE=false
SHOW_HELP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
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
        echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
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
Sigul TLS Stack Debugging Script

USAGE:
    ./scripts/debug-tls-stack.sh [OPTIONS]

OPTIONS:
    --verbose       Enable verbose output with detailed information
    --all           Run all diagnostic tests (default if no specific test selected)
    --certs         Check certificate setup and NSS databases
    --connectivity  Test network connectivity between components
    --tls           Test TLS handshakes with detailed traces
    --nss           Test NSS database access and password authentication
    --full-trace    Enable full NSS/NSPR trace logging (very verbose)
    --help          Show this help message

DESCRIPTION:
    This script performs comprehensive diagnostics on the Sigul TLS stack
    to debug "Unexpected EOF in NSPR" errors and TLS handshake failures.

    It tests:
    1. Container presence and running state
    2. NSS database validity and accessibility
    3. Certificate presence, validity, and trust chains
    4. Network connectivity (TCP and DNS)
    5. TLS handshake capability using multiple tools
    6. Certificate nickname matching with configuration
    7. NSS/NSPR library operations with debug logging

EXAMPLES:
    # Run all diagnostics
    ./scripts/debug-tls-stack.sh --all --verbose

    # Check only certificate setup
    ./scripts/debug-tls-stack.sh --certs

    # Test TLS with full trace logging
    ./scripts/debug-tls-stack.sh --tls --full-trace

    # Quick connectivity check
    ./scripts/debug-tls-stack.sh --connectivity

EOF
}

# Parse command line arguments
parse_args() {
    local has_specific_test=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --all)
                RUN_ALL=true
                has_specific_test=true
                shift
                ;;
            --certs)
                CHECK_CERTS=true
                has_specific_test=true
                shift
                ;;
            --connectivity)
                CHECK_CONNECTIVITY=true
                has_specific_test=true
                shift
                ;;
            --tls)
                CHECK_TLS=true
                has_specific_test=true
                shift
                ;;
            --nss)
                CHECK_NSS=true
                has_specific_test=true
                shift
                ;;
            --full-trace)
                FULL_TRACE=true
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

    # If no specific test selected, run all
    if [[ "$has_specific_test" == "false" ]]; then
        RUN_ALL=true
    fi

    # If --all selected, enable all tests
    if [[ "$RUN_ALL" == "true" ]]; then
        CHECK_CERTS=true
        CHECK_CONNECTIVITY=true
        CHECK_TLS=true
        CHECK_NSS=true
    fi
}

# Detect which containers are running
detect_containers() {
    section "Container Detection"

    log "Detecting Sigul containers..."

    # Look for running containers
    local bridge_container=""
    local server_container=""
    local client_container=""

    bridge_container=$(docker ps --filter "name=sigul-bridge" --format "{{.Names}}" | head -1 || echo "")
    server_container=$(docker ps --filter "name=sigul-server" --format "{{.Names}}" | head -1 || echo "")
    client_container=$(docker ps --filter "name=sigul-client" --format "{{.Names}}" | head -1 || echo "")

    if [[ -z "$bridge_container" ]]; then
        warn "Bridge container not found or not running"
        BRIDGE_CONTAINER=""
    else
        success "Bridge container: $bridge_container"
        BRIDGE_CONTAINER="$bridge_container"
    fi

    if [[ -z "$server_container" ]]; then
        warn "Server container not found or not running"
        SERVER_CONTAINER=""
    else
        success "Server container: $server_container"
        SERVER_CONTAINER="$server_container"
    fi

    if [[ -z "$client_container" ]]; then
        warn "Client container not found or not running"
        CLIENT_CONTAINER=""
    else
        success "Client container: $client_container"
        CLIENT_CONTAINER="$client_container"
    fi

    # Try to find network
    local network_name=""
    network_name=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1 || echo "")

    if [[ -z "$network_name" ]]; then
        warn "Sigul network not found"
        NETWORK_NAME=""
    else
        success "Network: $network_name"
        NETWORK_NAME="$network_name"
    fi

    echo ""
    log "Container Status Summary:"
    docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true

    return 0
}

# Check NSS databases
check_nss_databases() {
    section "NSS Database Validation"

    local exit_code=0

    # Check bridge NSS database
    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        log "Checking bridge NSS database..."

        if docker exec "$BRIDGE_CONTAINER" test -f /etc/pki/sigul/cert9.db; then
            success "Bridge NSS database exists (cert9.db)"

            verbose "Bridge NSS database details:"
            docker exec "$BRIDGE_CONTAINER" ls -lh /etc/pki/sigul/cert9.db || true

            verbose "Listing certificates in bridge NSS database:"
            docker exec "$BRIDGE_CONTAINER" certutil -L -d sql:/etc/pki/sigul 2>&1 | sed 's/^/  /' || {
                error "Failed to list bridge certificates"
                exit_code=1
            }

            verbose "Listing private keys in bridge NSS database:"
            docker exec "$BRIDGE_CONTAINER" certutil -K -d sql:/etc/pki/sigul 2>&1 | sed 's/^/  /' || {
                error "Failed to list bridge private keys"
                exit_code=1
            }
        else
            error "Bridge NSS database NOT found"
            exit_code=1
        fi
    fi

    # Check server NSS database
    if [[ -n "$SERVER_CONTAINER" ]]; then
        log "Checking server NSS database..."

        if docker exec "$SERVER_CONTAINER" test -f /etc/pki/sigul/cert9.db; then
            success "Server NSS database exists (cert9.db)"

            verbose "Server NSS database details:"
            docker exec "$SERVER_CONTAINER" ls -lh /etc/pki/sigul/cert9.db || true

            verbose "Listing certificates in server NSS database:"
            docker exec "$SERVER_CONTAINER" certutil -L -d sql:/etc/pki/sigul 2>&1 | sed 's/^/  /' || {
                error "Failed to list server certificates"
                exit_code=1
            }

            verbose "Listing private keys in server NSS database:"
            docker exec "$SERVER_CONTAINER" certutil -K -d sql:/etc/pki/sigul 2>&1 | sed 's/^/  /' || {
                error "Failed to list server private keys"
                exit_code=1
            }
        else
            error "Server NSS database NOT found"
            exit_code=1
        fi
    fi

    # Check client NSS database
    if [[ -n "$CLIENT_CONTAINER" ]]; then
        log "Checking client NSS database..."

        if docker exec "$CLIENT_CONTAINER" test -f /etc/pki/sigul/client/cert9.db; then
            success "Client NSS database exists (cert9.db)"

            verbose "Client NSS database details:"
            docker exec "$CLIENT_CONTAINER" ls -lh /etc/pki/sigul/client/cert9.db || true

            verbose "Listing certificates in client NSS database:"
            docker exec "$CLIENT_CONTAINER" certutil -L -d sql:/etc/pki/sigul/client 2>&1 | sed 's/^/  /' || {
                error "Failed to list client certificates"
                exit_code=1
            }

            verbose "Listing private keys in client NSS database:"
            docker exec "$CLIENT_CONTAINER" certutil -K -d sql:/etc/pki/sigul/client 2>&1 | sed 's/^/  /' || {
                error "Failed to list client private keys"
                exit_code=1
            }
        else
            error "Client NSS database NOT found"
            exit_code=1
        fi
    fi

    return $exit_code
}

# Validate certificate details
check_certificate_details() {
    section "Certificate Details and Validation"

    local exit_code=0

    # Bridge certificates
    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        log "Checking bridge certificate details..."

        # CA certificate
        if docker exec "$BRIDGE_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n sigul-ca >/dev/null 2>&1; then
            verbose "Bridge CA certificate details:"
            docker exec "$BRIDGE_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n sigul-ca 2>&1 | sed 's/^/  /' || true
        else
            error "Bridge CA certificate 'sigul-ca' not found"
            exit_code=1
        fi

        # Bridge certificate
        if docker exec "$BRIDGE_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n sigul-bridge-cert >/dev/null 2>&1; then
            verbose "Bridge server certificate details:"
            docker exec "$BRIDGE_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n sigul-bridge-cert 2>&1 | sed 's/^/  /' || true
        else
            error "Bridge certificate 'sigul-bridge-cert' not found"
            exit_code=1
        fi

        # Check certificate validity
        log "Validating bridge certificate expiration..."
        docker exec "$BRIDGE_CONTAINER" sh -c "certutil -L -d sql:/etc/pki/sigul -n sigul-bridge-cert | grep -E 'Not Before|Not After'" 2>&1 | sed 's/^/  /' || true
    fi

    # Server certificates
    if [[ -n "$SERVER_CONTAINER" ]]; then
        log "Checking server certificate details..."

        # CA certificate
        if docker exec "$SERVER_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n sigul-ca >/dev/null 2>&1; then
            verbose "Server CA certificate details:"
            docker exec "$SERVER_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n sigul-ca 2>&1 | sed 's/^/  /' || true
        else
            error "Server CA certificate 'sigul-ca' not found"
            exit_code=1
        fi

        # Server certificate
        if docker exec "$SERVER_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n sigul-server-cert >/dev/null 2>&1; then
            verbose "Server server certificate details:"
            docker exec "$SERVER_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n sigul-server-cert 2>&1 | sed 's/^/  /' || true
        else
            error "Server certificate 'sigul-server-cert' not found"
            exit_code=1
        fi

        # Check certificate validity
        log "Validating server certificate expiration..."
        docker exec "$SERVER_CONTAINER" sh -c "certutil -L -d sql:/etc/pki/sigul -n sigul-server-cert | grep -E 'Not Before|Not After'" 2>&1 | sed 's/^/  /' || true
    fi

    # Client certificates
    if [[ -n "$CLIENT_CONTAINER" ]]; then
        log "Checking client certificate details..."

        # CA certificate
        if docker exec "$CLIENT_CONTAINER" certutil -L -d sql:/etc/pki/sigul/client -n sigul-ca >/dev/null 2>&1; then
            verbose "Client CA certificate details:"
            docker exec "$CLIENT_CONTAINER" certutil -L -d sql:/etc/pki/sigul/client -n sigul-ca 2>&1 | sed 's/^/  /' || true
        else
            error "Client CA certificate 'sigul-ca' not found"
            exit_code=1
        fi

        # Client certificate
        if docker exec "$CLIENT_CONTAINER" certutil -L -d sql:/etc/pki/sigul/client -n sigul-client-cert >/dev/null 2>&1; then
            verbose "Client client certificate details:"
            docker exec "$CLIENT_CONTAINER" certutil -L -d sql:/etc/pki/sigul/client -n sigul-client-cert 2>&1 | sed 's/^/  /' || true
        else
            error "Client certificate 'sigul-client-cert' not found"
            exit_code=1
        fi

        # Check certificate validity
        log "Validating client certificate expiration..."
        docker exec "$CLIENT_CONTAINER" sh -c "certutil -L -d sql:/etc/pki/sigul/client -n sigul-client-cert | grep -E 'Not Before|Not After'" 2>&1 | sed 's/^/  /' || true

        # SECURITY CHECK: Ensure CA private key is NOT on client
        log "Security check: Verifying CA private key is NOT on client..."
        if docker exec "$CLIENT_CONTAINER" certutil -K -d sql:/etc/pki/sigul/client 2>/dev/null | grep -q "sigul-ca"; then
            error "SECURITY VIOLATION: CA private key found on client!"
            exit_code=1
        else
            success "Security check passed: CA private key NOT on client"
        fi
    fi

    return $exit_code
}

# Check network connectivity
check_network_connectivity() {
    section "Network Connectivity Tests"

    local exit_code=0

    if [[ -z "$NETWORK_NAME" ]]; then
        error "No Sigul network detected, skipping connectivity tests"
        return 1
    fi

    # Get container IPs
    local bridge_ip=""
    local server_ip=""

    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        bridge_ip=$(docker inspect "$BRIDGE_CONTAINER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' || echo "")
        if [[ -n "$bridge_ip" ]]; then
            log "Bridge IP: $bridge_ip"
        else
            warn "Could not determine bridge IP"
        fi
    fi

    if [[ -n "$SERVER_CONTAINER" ]]; then
        server_ip=$(docker inspect "$SERVER_CONTAINER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' || echo "")
        if [[ -n "$server_ip" ]]; then
            log "Server IP: $server_ip"
        else
            warn "Could not determine server IP"
        fi
    fi

    # Test DNS resolution from client
    if [[ -n "$CLIENT_CONTAINER" ]]; then
        log "Testing DNS resolution from client..."

        if docker exec "$CLIENT_CONTAINER" nslookup sigul-bridge.example.org >/dev/null 2>&1; then
            success "Client can resolve sigul-bridge.example.org"
        else
            error "Client CANNOT resolve sigul-bridge.example.org"
            exit_code=1
        fi

        if docker exec "$CLIENT_CONTAINER" nslookup sigul-server.example.org >/dev/null 2>&1; then
            success "Client can resolve sigul-server.example.org"
        else
            error "Client CANNOT resolve sigul-server.example.org"
            exit_code=1
        fi
    fi

    # Test TCP connectivity from client to bridge
    if [[ -n "$CLIENT_CONTAINER" && -n "$bridge_ip" ]]; then
        log "Testing TCP connectivity: client -> bridge:44334..."

        if docker exec "$CLIENT_CONTAINER" timeout 3 nc -zv "$bridge_ip" 44334 >/dev/null 2>&1; then
            success "Client can connect to bridge TCP port 44334"
        else
            error "Client CANNOT connect to bridge TCP port 44334"
            exit_code=1
        fi
    fi

    # Test TCP connectivity from bridge to server
    if [[ -n "$BRIDGE_CONTAINER" && -n "$server_ip" ]]; then
        log "Testing TCP connectivity: bridge -> server:44333..."

        if docker exec "$BRIDGE_CONTAINER" timeout 3 nc -zv "$server_ip" 44333 >/dev/null 2>&1; then
            success "Bridge can connect to server TCP port 44333"
        else
            error "Bridge CANNOT connect to server TCP port 44333"
            exit_code=1
        fi
    fi

    # Test listening ports
    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        log "Checking bridge listening ports..."
        docker exec "$BRIDGE_CONTAINER" netstat -tlnp 2>/dev/null | grep -E "44334|44333" | sed 's/^/  /' || {
            warn "Could not check bridge listening ports"
        }
    fi

    if [[ -n "$SERVER_CONTAINER" ]]; then
        log "Checking server listening ports..."
        docker exec "$SERVER_CONTAINER" netstat -tlnp 2>/dev/null | grep "44333" | sed 's/^/  /' || {
            warn "Could not check server listening ports"
        }
    fi

    return $exit_code
}

# Test TLS handshakes using openssl s_client
test_tls_with_openssl() {
    section "TLS Handshake Tests (OpenSSL)"

    local exit_code=0

    # Test client -> bridge TLS handshake
    if [[ -n "$CLIENT_CONTAINER" ]]; then
        log "Testing TLS handshake: client -> bridge:44334..."

        local output
        output=$(docker exec "$CLIENT_CONTAINER" timeout 5 openssl s_client \
            -connect sigul-bridge.example.org:44334 \
            -verify 2 \
            -showcerts \
            < /dev/null 2>&1 || echo "FAILED")

        if echo "$output" | grep -q "Verify return code: 0"; then
            success "TLS handshake successful: client -> bridge"
            verbose "Certificate chain verification PASSED"
        elif echo "$output" | grep -q "CONNECTED"; then
            warn "TLS connection established but verification failed"
            error "Verify return code: $(echo "$output" | grep "Verify return code" || echo "unknown")"
            exit_code=1
        else
            error "TLS handshake FAILED: client -> bridge"
            exit_code=1
        fi

        if [[ "$VERBOSE_MODE" == "true" ]]; then
            echo "$output" | grep -E "depth=|verify return:|subject=|issuer=" | sed 's/^/  /'
        fi
    fi

    # Test bridge -> server TLS handshake
    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        log "Testing TLS handshake: bridge -> server:44333..."

        local output
        output=$(docker exec "$BRIDGE_CONTAINER" timeout 5 openssl s_client \
            -connect sigul-server.example.org:44333 \
            -verify 2 \
            -showcerts \
            < /dev/null 2>&1 || echo "FAILED")

        if echo "$output" | grep -q "Verify return code: 0"; then
            success "TLS handshake successful: bridge -> server"
            verbose "Certificate chain verification PASSED"
        elif echo "$output" | grep -q "CONNECTED"; then
            warn "TLS connection established but verification failed"
            error "Verify return code: $(echo "$output" | grep "Verify return code" || echo "unknown")"
            exit_code=1
        else
            error "TLS handshake FAILED: bridge -> server"
            exit_code=1
        fi

        if [[ "$VERBOSE_MODE" == "true" ]]; then
            echo "$output" | grep -E "depth=|verify return:|subject=|issuer=" | sed 's/^/  /'
        fi
    fi

    return $exit_code
}

# Test NSS database access with password
test_nss_database_access() {
    section "NSS Database Access and Authentication"

    local exit_code=0

    # Load NSS password if available
    local nss_password=""
    local password_file="${PROJECT_ROOT}/test-artifacts/nss-password"

    if [[ -f "$password_file" ]]; then
        nss_password=$(cat "$password_file")
        verbose "Loaded NSS password from test artifacts"
    else
        warn "NSS password file not found: $password_file"
    fi

    # Test bridge NSS database authentication
    if [[ -n "$BRIDGE_CONTAINER" && -n "$nss_password" ]]; then
        log "Testing bridge NSS database authentication..."

        if docker exec "$BRIDGE_CONTAINER" sh -c "echo '$nss_password' | certutil -K -d sql:/etc/pki/sigul -f /dev/stdin" >/dev/null 2>&1; then
            success "Bridge NSS database authentication successful"
        else
            error "Bridge NSS database authentication FAILED"
            verbose "Trying without password..."
            if docker exec "$BRIDGE_CONTAINER" certutil -K -d sql:/etc/pki/sigul >/dev/null 2>&1; then
                warn "NSS database accessible without password (not recommended)"
            else
                error "NSS database not accessible"
                exit_code=1
            fi
        fi
    fi

    # Test server NSS database authentication
    if [[ -n "$SERVER_CONTAINER" && -n "$nss_password" ]]; then
        log "Testing server NSS database authentication..."

        if docker exec "$SERVER_CONTAINER" sh -c "echo '$nss_password' | certutil -K -d sql:/etc/pki/sigul -f /dev/stdin" >/dev/null 2>&1; then
            success "Server NSS database authentication successful"
        else
            error "Server NSS database authentication FAILED"
            exit_code=1
        fi
    fi

    # Test client NSS database authentication
    if [[ -n "$CLIENT_CONTAINER" && -n "$nss_password" ]]; then
        log "Testing client NSS database authentication..."

        if docker exec "$CLIENT_CONTAINER" sh -c "echo '$nss_password' | certutil -K -d sql:/etc/pki/sigul/client -f /dev/stdin" >/dev/null 2>&1; then
            success "Client NSS database authentication successful"
        else
            error "Client NSS database authentication FAILED"
            exit_code=1
        fi
    fi

    return $exit_code
}

# Test with NSS tools (tstclnt)
test_tls_with_tstclnt() {
    section "TLS Handshake Tests (NSS tstclnt)"

    local exit_code=0

    if ! command -v tstclnt >/dev/null 2>&1; then
        warn "tstclnt not available in host, checking containers..."
    fi

    # Test client -> bridge with tstclnt
    if [[ -n "$CLIENT_CONTAINER" ]]; then
        log "Testing TLS with tstclnt: client -> bridge:44334..."

        local nss_password=""
        local password_file="${PROJECT_ROOT}/test-artifacts/nss-password"
        if [[ -f "$password_file" ]]; then
            nss_password=$(cat "$password_file")
        fi

        local cmd="tstclnt -h sigul-bridge.example.org -p 44334 -d sql:/etc/pki/sigul/client -v -o"

        if [[ -n "$nss_password" ]]; then
            cmd="echo '$nss_password' | $cmd -w /dev/stdin"
        fi

        local output
        output=$(docker exec "$CLIENT_CONTAINER" sh -c "$cmd" 2>&1 || echo "FAILED")

        if echo "$output" | grep -q "SSL_ForceHandshake: success"; then
            success "NSS tstclnt handshake successful: client -> bridge"
        else
            error "NSS tstclnt handshake FAILED: client -> bridge"
            error "Output: $output"
            exit_code=1
        fi

        if [[ "$VERBOSE_MODE" == "true" ]]; then
            # shellcheck disable=SC2001  # sed used for indentation formatting
            echo "$output" | sed 's/^/  /'
        fi
    fi

    return $exit_code
}

# Test with full NSS/NSPR trace logging
test_with_nss_trace() {
    section "NSS/NSPR Full Trace Testing"

    log "Running Sigul client with full NSS/NSPR trace logging..."
    warn "This will produce VERY verbose output"

    if [[ -z "$CLIENT_CONTAINER" ]]; then
        error "No client container available for trace testing"
        return 1
    fi

    local nss_password=""
    local password_file="${PROJECT_ROOT}/test-artifacts/nss-password"
    if [[ -f "$password_file" ]]; then
        nss_password=$(cat "$password_file")
    fi

    log "Attempting to list users with full NSS trace..."

    docker exec "$CLIENT_CONTAINER" sh -c "
        export NSPR_LOG_MODULES='all:5'
        export NSPR_LOG_FILE=/tmp/nss-trace.log
        export NSS_DEBUG_PKCS11=1

        echo 'test123' | timeout 10 sigul -c /etc/sigul/client.conf --batch list-users 2>&1 || true

        echo '=== NSS Trace Log ==='
        cat /tmp/nss-trace.log 2>/dev/null || echo 'No trace log generated'
    " 2>&1 | if [[ "$VERBOSE_MODE" == "true" ]]; then
        cat
    else
        head -100
    fi

    return 0
}

# Check configuration file consistency
check_configuration_consistency() {
    section "Configuration File Validation"

    local exit_code=0

    # Check bridge configuration
    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        log "Checking bridge configuration..."

        if docker exec "$BRIDGE_CONTAINER" test -f /etc/sigul/bridge.conf; then
            verbose "Bridge configuration file exists"

            verbose "Certificate nicknames in bridge config:"
            docker exec "$BRIDGE_CONTAINER" grep -E "nickname|cert-nickname" /etc/sigul/bridge.conf 2>/dev/null | sed 's/^/  /' || true

            verbose "NSS directory in bridge config:"
            docker exec "$BRIDGE_CONTAINER" grep "nss-dir" /etc/sigul/bridge.conf 2>/dev/null | sed 's/^/  /' || true

            # Check if certificate nicknames in config match NSS database
            local bridge_nickname
            bridge_nickname=$(docker exec "$BRIDGE_CONTAINER" grep "bridge-cert-nickname" /etc/sigul/bridge.conf 2>/dev/null | cut -d: -f2 | xargs || echo "")

            if [[ -n "$bridge_nickname" ]]; then
                if docker exec "$BRIDGE_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n "$bridge_nickname" >/dev/null 2>&1; then
                    success "Bridge certificate nickname '$bridge_nickname' matches NSS database"
                else
                    error "Bridge certificate nickname '$bridge_nickname' NOT FOUND in NSS database"
                    exit_code=1
                fi
            fi
        else
            error "Bridge configuration file NOT found"
            exit_code=1
        fi
    fi

    # Check server configuration
    if [[ -n "$SERVER_CONTAINER" ]]; then
        log "Checking server configuration..."

        if docker exec "$SERVER_CONTAINER" test -f /etc/sigul/server.conf; then
            verbose "Server configuration file exists"

            verbose "Certificate nicknames in server config:"
            docker exec "$SERVER_CONTAINER" grep -E "nickname|cert-nickname" /etc/sigul/server.conf 2>/dev/null | sed 's/^/  /' || true

            verbose "NSS directory in server config:"
            docker exec "$SERVER_CONTAINER" grep "nss-dir" /etc/sigul/server.conf 2>/dev/null | sed 's/^/  /' || true

            # Check if certificate nicknames in config match NSS database
            local server_nickname
            server_nickname=$(docker exec "$SERVER_CONTAINER" grep "server-cert-nickname" /etc/sigul/server.conf 2>/dev/null | cut -d: -f2 | xargs || echo "")

            if [[ -n "$server_nickname" ]]; then
                if docker exec "$SERVER_CONTAINER" certutil -L -d sql:/etc/pki/sigul -n "$server_nickname" >/dev/null 2>&1; then
                    success "Server certificate nickname '$server_nickname' matches NSS database"
                else
                    error "Server certificate nickname '$server_nickname' NOT FOUND in NSS database"
                    exit_code=1
                fi
            fi
        else
            error "Server configuration file NOT found"
            exit_code=1
        fi
    fi

    # Check client configuration
    if [[ -n "$CLIENT_CONTAINER" ]]; then
        log "Checking client configuration..."

        if docker exec "$CLIENT_CONTAINER" test -f /etc/sigul/client.conf; then
            verbose "Client configuration file exists"

            verbose "Certificate nicknames in client config:"
            docker exec "$CLIENT_CONTAINER" grep -E "nickname|cert-nickname" /etc/sigul/client.conf 2>/dev/null | sed 's/^/  /' || true

            verbose "NSS directory in client config:"
            docker exec "$CLIENT_CONTAINER" grep "nss-dir" /etc/sigul/client.conf 2>/dev/null | sed 's/^/  /' || true

            # Check if certificate nicknames in config match NSS database
            local client_nickname
            client_nickname=$(docker exec "$CLIENT_CONTAINER" grep "client-cert-nickname" /etc/sigul/client.conf 2>/dev/null | cut -d: -f2 | xargs || echo "")

            if [[ -n "$client_nickname" ]]; then
                if docker exec "$CLIENT_CONTAINER" certutil -L -d sql:/etc/pki/sigul/client -n "$client_nickname" >/dev/null 2>&1; then
                    success "Client certificate nickname '$client_nickname' matches NSS database"
                else
                    error "Client certificate nickname '$client_nickname' NOT FOUND in NSS database"
                    exit_code=1
                fi
            fi
        else
            error "Client configuration file NOT found"
            exit_code=1
        fi
    fi

    return $exit_code
}

# Check for race conditions and timing issues
check_race_conditions() {
    section "Race Condition and Timing Analysis"

    log "Analyzing container startup timing..."

    # Check container uptimes
    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        local bridge_uptime
        bridge_uptime=$(docker ps --filter "name=$BRIDGE_CONTAINER" --format "{{.Status}}" || echo "unknown")
        log "Bridge uptime: $bridge_uptime"
    fi

    if [[ -n "$SERVER_CONTAINER" ]]; then
        local server_uptime
        server_uptime=$(docker ps --filter "name=$SERVER_CONTAINER" --format "{{.Status}}" || echo "unknown")
        log "Server uptime: $server_uptime"
    fi

    # Check if processes are running
    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        log "Checking bridge processes..."
        docker exec "$BRIDGE_CONTAINER" ps aux | grep -E "sigul|python" | grep -v grep | sed 's/^/  /' || warn "No sigul processes found in bridge"
    fi

    if [[ -n "$SERVER_CONTAINER" ]]; then
        log "Checking server processes..."
        docker exec "$SERVER_CONTAINER" ps aux | grep -E "sigul|python" | grep -v grep | sed 's/^/  /' || warn "No sigul processes found in server"
    fi

    # Check recent logs for initialization messages
    if [[ -n "$BRIDGE_CONTAINER" ]]; then
        log "Recent bridge initialization logs:"
        docker logs "$BRIDGE_CONTAINER" 2>&1 | tail -20 | sed 's/^/  /'
    fi

    if [[ -n "$SERVER_CONTAINER" ]]; then
        log "Recent server initialization logs:"
        docker logs "$SERVER_CONTAINER" 2>&1 | tail -20 | sed 's/^/  /'
    fi

    return 0
}

# Generate comprehensive diagnostic report
generate_diagnostic_report() {
    section "Diagnostic Report Summary"

    local report_file
    report_file="${PROJECT_ROOT}/test-artifacts/tls-diagnostics-$(date +%Y%m%d-%H%M%S).txt"
    mkdir -p "${PROJECT_ROOT}/test-artifacts"

    {
        echo "Sigul TLS Stack Diagnostic Report"
        echo "Generated: $(date)"
        echo ""
        echo "Container Status:"
        docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo "Network Status:"
        docker network ls --filter "name=sigul"
        echo ""
        echo "Volume Status:"
        docker volume ls --filter "name=sigul"
    } > "$report_file"

    success "Diagnostic report saved to: $report_file"
}

# Main execution
main() {
    log "Sigul TLS Stack Debugging Script"
    log "================================"

    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    # Detect containers
    detect_containers

    local overall_exit_code=0

    # Run selected tests
    if [[ "$CHECK_NSS" == "true" ]]; then
        check_nss_databases || overall_exit_code=1
        check_configuration_consistency || overall_exit_code=1
        test_nss_database_access || overall_exit_code=1
    fi

    if [[ "$CHECK_CERTS" == "true" ]]; then
        check_certificate_details || overall_exit_code=1
    fi

    if [[ "$CHECK_CONNECTIVITY" == "true" ]]; then
        check_network_connectivity || overall_exit_code=1
    fi

    if [[ "$CHECK_TLS" == "true" ]]; then
        test_tls_with_openssl || overall_exit_code=1
        test_tls_with_tstclnt || overall_exit_code=1
    fi

    if [[ "$FULL_TRACE" == "true" ]]; then
        test_with_nss_trace || overall_exit_code=1
    fi

    # Always check for race conditions
    check_race_conditions || overall_exit_code=1

    # Generate report
    generate_diagnostic_report

    section "Final Summary"

    if [[ $overall_exit_code -eq 0 ]]; then
        success "All TLS diagnostics PASSED"
    else
        error "Some TLS diagnostics FAILED - see details above"
    fi

    return $overall_exit_code
}

# Global variables for detected containers
BRIDGE_CONTAINER=""
SERVER_CONTAINER=""
CLIENT_CONTAINER=""
NETWORK_NAME=""

# Run main
main "$@"
