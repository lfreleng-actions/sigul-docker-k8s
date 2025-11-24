#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Application TLS Debugging Script
#
# This script helps debug the "Unexpected EOF in NSPR" error that occurs
# when the Sigul Python application attempts to connect, even though
# raw TLS tools (like tstclnt) work correctly.
#
# Usage:
#   ./debug-sigul-tls.sh [OPTIONS]
#
# Options:
#   --component <bridge|server|client>  Component to debug (default: all)
#   --enable-strace                     Enable strace on Sigul processes
#   --enable-nss-debug                  Enable NSS debug logging
#   --enable-python-debug               Enable Python debug logging
#   --test-raw-tls                      Test with tstclnt first
#   --test-sigul-app                    Test with Sigul application
#   --compare                           Compare raw TLS vs Sigul app behavior
#   --all                               Run all debugging tests
#   --help                              Show this help message

set -euo pipefail

# Script configuration

# Docker image name and network
CLIENT_IMAGE="sigul-docker-sigul-client-test"
NETWORK_NAME="sigul-docker_sigul-network"
VOLUME_PREFIX="sigul-docker"

# Default options
COMPONENT="all"
ENABLE_STRACE=false
ENABLE_NSS_DEBUG=false
ENABLE_PYTHON_DEBUG=false
TEST_RAW_TLS=false
TEST_SIGUL_APP=false
COMPARE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

section() {
    echo -e "${PURPLE}========================================${NC}"
    echo -e "${PURPLE}$*${NC}"
    echo -e "${PURPLE}========================================${NC}"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --component)
                COMPONENT="$2"
                shift 2
                ;;
            --enable-strace)
                ENABLE_STRACE=true
                shift
                ;;
            --enable-nss-debug)
                ENABLE_NSS_DEBUG=true
                shift
                ;;
            --enable-python-debug)
                ENABLE_PYTHON_DEBUG=true
                shift
                ;;
            --test-raw-tls)
                TEST_RAW_TLS=true
                shift
                ;;
            --test-sigul-app)
                TEST_SIGUL_APP=true
                shift
                ;;
            --compare)
                COMPARE=true
                TEST_RAW_TLS=true
                TEST_SIGUL_APP=true
                shift
                ;;
            --all)
                ENABLE_STRACE=true
                ENABLE_NSS_DEBUG=true
                ENABLE_PYTHON_DEBUG=true
                TEST_RAW_TLS=true
                TEST_SIGUL_APP=true
                COMPARE=true
                shift
                ;;
            --help)
                grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //' | sed 's/^#//'
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Check if containers are running
check_containers() {
    section "Checking Container Status"

    local containers=("sigul-bridge" "sigul-server")
    local all_running=true

    for container in "${containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            success "Container ${container} is running"
        else
            error "Container ${container} is NOT running"
            all_running=false
        fi
    done

    if [[ "$all_running" == "false" ]]; then
        error "Not all containers are running. Please start the stack first."
        exit 1
    fi

    log "Note: Client container runs as one-off commands, not a persistent service"

    echo
}

# Display NSS certificate info
check_certificates() {
    section "Checking NSS Certificates"

    log "Bridge certificates:"
    docker exec sigul-bridge certutil -d sql:/etc/pki/sigul/bridge -L || true
    echo

    log "Server certificates:"
    docker exec sigul-server certutil -d sql:/etc/pki/sigul/server -L || true
    echo

    log "Client certificates (using temporary container):"
    docker run --rm \
        --network "$NETWORK_NAME" \
        -v "${VOLUME_PREFIX}_sigul_client_nss:/etc/pki/sigul/client:ro" \
        "$CLIENT_IMAGE" \
        certutil -d sql:/etc/pki/sigul/client -L || true
    echo

    log "Checking bridge certificate trust flags:"
    docker exec sigul-bridge certutil -d sql:/etc/pki/sigul/bridge -L -n sigul-ca | grep -A5 "Trust Attributes" || true
    echo

    log "Checking client certificate trust flags:"
    docker run --rm \
        --network "$NETWORK_NAME" \
        -v "${VOLUME_PREFIX}_sigul_client_nss:/etc/pki/sigul/client:ro" \
        "$CLIENT_IMAGE" \
        certutil -d sql:/etc/pki/sigul/client -L -n sigul-ca | grep -A5 "Trust Attributes" || true
    echo
}

# Check configuration files
check_configurations() {
    section "Checking Configuration Files"

    log "Bridge configuration:"
    docker exec sigul-bridge cat /etc/sigul/bridge.conf | grep -E "bridge-cert-nickname|bridge-hostname|bridge-port" || true
    echo

    log "Server configuration:"
    docker exec sigul-server cat /etc/sigul/server.conf | grep -E "bridge-hostname|bridge-port|server-cert-nickname" || true
    echo

    log "Client configuration (using temporary container):"
    docker run --rm \
        --network "$NETWORK_NAME" \
        -v "${VOLUME_PREFIX}_sigul_client_config:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        cat /etc/sigul/client.conf | grep -E "bridge-hostname|bridge-port|client-cert-nickname" || true
    echo
}

# Test raw TLS connection with tstclnt
test_raw_tls() {
    section "Testing Raw TLS Connection (tstclnt)"

    log "Testing bridge TLS handshake from client container..."

    local test_cmd="tstclnt -h sigul-bridge.example.org -p 44334 -d sql:/etc/pki/sigul/client -n sigul-client-cert -w /etc/pki/sigul/client/nss-password -V tls1.3:tls1.3 -v"

    if [[ "$ENABLE_NSS_DEBUG" == "true" ]]; then
        test_cmd="SSLDEBUG=100 SSLTRACE=100 $test_cmd"
    fi

    log "Running: $test_cmd"
    echo

    if docker run --rm \
        --network "$NETWORK_NAME" \
        -v "${VOLUME_PREFIX}_sigul_client_nss:/etc/pki/sigul/client:ro" \
        "$CLIENT_IMAGE" \
        sh -c "$test_cmd" 2>&1 | tee /tmp/tstclnt-debug.log; then
        success "Raw TLS handshake SUCCESSFUL"
    else
        warn "Raw TLS handshake FAILED"
        error "See /tmp/tstclnt-debug.log for details"
    fi

    echo
}

# Test Sigul application connection
test_sigul_app() {
    section "Testing Sigul Application Connection"

    local sigul_cmd="sigul -c /etc/sigul/client.conf list-users"

    # Build environment variables for docker run
    local env_args=()

    if [[ "$ENABLE_NSS_DEBUG" == "true" ]]; then
        env_args+=("-e" "SSLDEBUG=100")
        env_args+=("-e" "SSLTRACE=100")
        env_args+=("-e" "NSS_DEBUG_PKCS11_MODULE=NSS Internal PKCS #11 Module")
    fi

    if [[ "$ENABLE_PYTHON_DEBUG" == "true" ]]; then
        env_args+=("-e" "PYTHONVERBOSE=1")
        env_args+=("-e" "PYTHONDEBUG=1")
    fi

    log "Testing Sigul application connection..."
    log "Command: ${sigul_cmd}"
    if [[ ${#env_args[@]} -gt 0 ]]; then
        log "Debug env vars: ${env_args[*]}"
    fi
    echo

    if [[ "$ENABLE_STRACE" == "true" ]]; then
        log "Running with strace..."
        if [[ ${#env_args[@]} -gt 0 ]]; then
            docker run --rm \
                --network "$NETWORK_NAME" \
                -v "${VOLUME_PREFIX}_sigul_client_config:/etc/sigul:ro" \
                -v "${VOLUME_PREFIX}_sigul_client_nss:/etc/pki/sigul/client:ro" \
                "${env_args[@]}" \
                "$CLIENT_IMAGE" \
                sh -c "strace -f -s 1024 $sigul_cmd 2>&1" | tee /tmp/sigul-app-debug.log || true
        else
            docker run --rm \
                --network "$NETWORK_NAME" \
                -v "${VOLUME_PREFIX}_sigul_client_config:/etc/sigul:ro" \
                -v "${VOLUME_PREFIX}_sigul_client_nss:/etc/pki/sigul/client:ro" \
                "$CLIENT_IMAGE" \
                sh -c "strace -f -s 1024 $sigul_cmd 2>&1" | tee /tmp/sigul-app-debug.log || true
        fi
    else
        if [[ ${#env_args[@]} -gt 0 ]]; then
            docker run --rm \
                --network "$NETWORK_NAME" \
                -v "${VOLUME_PREFIX}_sigul_client_config:/etc/sigul:ro" \
                -v "${VOLUME_PREFIX}_sigul_client_nss:/etc/pki/sigul/client:ro" \
                "${env_args[@]}" \
                "$CLIENT_IMAGE" \
                sh -c "$sigul_cmd 2>&1" | tee /tmp/sigul-app-debug.log || true
        else
            docker run --rm \
                --network "$NETWORK_NAME" \
                -v "${VOLUME_PREFIX}_sigul_client_config:/etc/sigul:ro" \
                -v "${VOLUME_PREFIX}_sigul_client_nss:/etc/pki/sigul/client:ro" \
                "$CLIENT_IMAGE" \
                sh -c "$sigul_cmd 2>&1" | tee /tmp/sigul-app-debug.log || true
        fi
    fi

    echo

    # Check for specific error patterns
    if grep -q "Unexpected EOF" /tmp/sigul-app-debug.log; then
        error "Found 'Unexpected EOF' error"
    fi

    if grep -q "NSPR error" /tmp/sigul-app-debug.log; then
        error "Found 'NSPR error'"
    fi

    if grep -q "SSL_ERROR" /tmp/sigul-app-debug.log; then
        error "Found SSL error"
    fi
}

# Compare raw TLS vs Sigul application
compare_behavior() {
    section "Comparing Raw TLS vs Sigul Application"

    log "Differences in behavior:"
    echo

    log "✅ Raw TLS (tstclnt):"
    log "   - Uses NSS directly"
    log "   - Explicit certificate nickname"
    log "   - Explicit password file"
    log "   - Explicit TLS version"
    log "   - Direct socket connection"
    echo

    log "❓ Sigul Application:"
    log "   - Uses Python NSS bindings"
    log "   - Relies on configuration file"
    log "   - May have additional protocol layers"
    log "   - May have different hostname resolution"
    echo

    log "Key things to check:"
    log "   1. Does Sigul use the correct NSS database path?"
    log "   2. Does Sigul specify the correct certificate nickname?"
    log "   3. Does Sigul resolve hostnames correctly?"
    log "   4. Does Sigul have additional protocol requirements?"
    log "   5. Is there a double-TLS setup that might be failing?"
    echo
}

# Check bridge and server logs
check_logs() {
    section "Checking Container Logs"

    log "Recent bridge logs:"
    docker logs --tail 50 sigul-bridge 2>&1 | tail -20
    echo

    log "Recent server logs:"
    docker logs --tail 50 sigul-server 2>&1 | tail -20
    echo

    log "Client logs: (Client runs as one-off commands, no persistent logs)"
    echo
}

# Check Python Sigul module configuration
check_python_sigul() {
    section "Checking Python Sigul Module"

    log "Sigul Python module location:"
    docker run --rm \
        --network "$NETWORK_NAME" \
        "$CLIENT_IMAGE" \
        python3 -c "import sigul_client; print(sigul_client.__file__)" || warn "Could not find sigul_client module"
    echo

    log "Checking NSS-related Python imports:"
    docker run --rm \
        --network "$NETWORK_NAME" \
        "$CLIENT_IMAGE" \
        python3 -c "import nss.ssl; print('NSS SSL module loaded successfully')" || error "NSS SSL module failed to load"
    echo

    log "Checking if Sigul can read configuration:"
    docker run --rm \
        --network "$NETWORK_NAME" \
        -v "${VOLUME_PREFIX}_sigul_client_config:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        python3 << 'PYEOF' || true
import sys
try:
    # Try to import and read config
    import configparser
    config = configparser.ConfigParser()
    config.read('/etc/sigul/client.conf')

    print("Configuration sections:", list(config.sections()))

    if 'client' in config:
        print("Bridge hostname:", config.get('client', 'bridge-hostname'))
        print("Bridge port:", config.get('client', 'bridge-port'))

    if 'nss' in config:
        print("NSS dir:", config.get('nss', 'nss-dir'))
        print("Client cert nickname:", config.get('nss', 'client-cert-nickname'))

except Exception as e:
    print(f"Error reading config: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    echo
}

# Test DNS resolution
check_dns() {
    section "Checking DNS Resolution"

    log "Resolving sigul-bridge.example.org from client:"
    docker run --rm \
        --network "$NETWORK_NAME" \
        "$CLIENT_IMAGE" \
        getent hosts sigul-bridge.example.org || warn "DNS resolution failed"
    echo

    log "Resolving sigul-server.example.org from bridge:"
    docker exec sigul-bridge getent hosts sigul-server.example.org || warn "DNS resolution failed"
    echo

    log "Testing TCP connectivity from client to bridge:"
    docker run --rm \
        --network "$NETWORK_NAME" \
        "$CLIENT_IMAGE" \
        nc -zv sigul-bridge.example.org 44334 || warn "TCP connection failed"
    echo
}

# Enable detailed logging in containers
enable_debug_logging() {
    section "Enabling Debug Logging in Containers"

    log "Debug environment variables will be set when running client commands"
    log "Bridge and server containers are persistent, client runs as one-off"

    echo
}

# Generate debugging report
generate_report() {
    section "Generating Debugging Report"

    local report_file
    report_file="/tmp/sigul-tls-debug-report-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "========================================"
        echo "Sigul TLS Debugging Report"
        echo "Generated: $(date)"
        echo "========================================"
        echo

        echo "## Container Status"
        docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo

        echo "## Certificate Status"
        echo "### Bridge"
        docker exec sigul-bridge certutil -d sql:/etc/pki/sigul/bridge -L || true
        echo
        echo "### Server"
        docker exec sigul-server certutil -d sql:/etc/pki/sigul/server -L || true
        echo
        echo "### Client"
        docker run --rm \
            --network "$NETWORK_NAME" \
            -v "${VOLUME_PREFIX}_sigul_client_nss:/etc/pki/sigul/client:ro" \
            "$CLIENT_IMAGE" \
            certutil -d sql:/etc/pki/sigul/client -L || true
        echo

        echo "## Configuration"
        echo "### Client Config"
        docker run --rm \
            --network "$NETWORK_NAME" \
            -v "${VOLUME_PREFIX}_sigul_client_config:/etc/sigul:ro" \
            "$CLIENT_IMAGE" \
            cat /etc/sigul/client.conf || true
        echo

        echo "## Test Results"
        if [[ -f /tmp/tstclnt-debug.log ]]; then
            echo "### Raw TLS Test (tstclnt)"
            tail -50 /tmp/tstclnt-debug.log
            echo
        fi

        if [[ -f /tmp/sigul-app-debug.log ]]; then
            echo "### Sigul Application Test"
            tail -50 /tmp/sigul-app-debug.log
            echo
        fi

        echo "## Container Logs"
        echo "### Bridge"
        docker logs --tail 50 sigul-bridge 2>&1
        echo
        echo "### Server"
        docker logs --tail 50 sigul-server 2>&1
        echo

    } > "$report_file"

    success "Report generated: $report_file"
    log "You can review this file for detailed debugging information"
}

# Main function
main() {
    parse_args "$@"

    log "Starting Sigul TLS debugging..."
    log "Component: $COMPONENT"
    log "Enable strace: $ENABLE_STRACE"
    log "Enable NSS debug: $ENABLE_NSS_DEBUG"
    log "Enable Python debug: $ENABLE_PYTHON_DEBUG"
    echo

    # Basic checks
    check_containers
    check_certificates
    check_configurations
    check_dns

    # Python module check
    check_python_sigul

    # Enable debugging if requested
    if [[ "$ENABLE_NSS_DEBUG" == "true" ]] || [[ "$ENABLE_PYTHON_DEBUG" == "true" ]]; then
        enable_debug_logging
    fi

    # Run tests
    if [[ "$TEST_RAW_TLS" == "true" ]]; then
        test_raw_tls
    fi

    if [[ "$TEST_SIGUL_APP" == "true" ]]; then
        test_sigul_app
    fi

    # Compare behavior
    if [[ "$COMPARE" == "true" ]]; then
        compare_behavior
    fi

    # Check logs
    check_logs

    # Generate report
    generate_report

    section "Debugging Complete"
    success "Review the output above and the generated report for insights"

    echo
    log "Next steps:"
    log "1. Review the differences between raw TLS and Sigul app behavior"
    log "2. Check if Sigul is using the correct hostname (sigul-bridge.example.org)"
    log "3. Verify NSS database paths in client.conf match actual locations"
    log "4. Check if there are any Python-level SSL/TLS configuration issues"
    log "5. Review bridge/server logs for connection attempts"
}

# Run main function
main "$@"
