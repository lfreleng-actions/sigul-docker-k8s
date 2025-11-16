#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Network Connectivity Verification Script
#
# This script verifies network connectivity between Sigul components.
# It checks listening ports, established connections, and network reachability.
#
# Usage:
#   ./verify-network.sh

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] NET-VERIFY:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SUCCESS:${NC} $*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

fatal() {
    error "$*"
    exit 1
}

# Check if containers are running
check_containers_running() {
    log "Checking if containers are running..."

    local missing=false

    if ! docker ps --format '{{.Names}}' | grep -q "^sigul-bridge$"; then
        error "Bridge container is not running"
        missing=true
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^sigul-server$"; then
        error "Server container is not running"
        missing=true
    fi

    if [ "$missing" = true ]; then
        fatal "Required containers are not running"
    fi

    success "All required containers are running"
}

# Verify bridge listening ports
verify_bridge_listening() {
    log "Checking bridge listening ports..."

    local port_44333=false
    local port_44334=false

    # Check port 44333 (server connection)
    if docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -q ":44333"; then
        echo "  ✓ Port 44333 (server) - LISTENING"
        port_44333=true
    else
        echo "  ✗ Port 44333 (server) - NOT LISTENING"
    fi

    # Check port 44334 (client connection)
    if docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -q ":44334"; then
        echo "  ✓ Port 44334 (client) - LISTENING"
        port_44334=true
    else
        echo "  ✗ Port 44334 (client) - NOT LISTENING"
    fi

    if [ "$port_44333" = true ] && [ "$port_44334" = true ]; then
        success "Bridge listening on all expected ports"
    else
        error "Bridge not listening on all required ports"
    fi
}

# Verify server can reach bridge
verify_server_connectivity() {
    log "Checking server connectivity to bridge..."

    # Test connection to port 44333
    if docker exec sigul-server nc -zv sigul-bridge.example.org 44333 2>&1 | grep -q "succeeded\|open"; then
        success "Server can reach bridge on port 44333"
    else
        error "Server cannot reach bridge on port 44333"
    fi
}

# Check established connections
verify_established_connections() {
    log "Checking established connections..."

    echo ""
    echo "  Bridge connections (port 44333):"
    local bridge_conns
    bridge_conns=$(docker exec sigul-bridge netstat -tnp 2>/dev/null | grep ":44333" | grep "ESTABLISHED" || echo "")

    if [ -n "$bridge_conns" ]; then
        echo "$bridge_conns" | while read -r line; do
            echo "    ${line}"
        done
        success "Bridge has established connections"
    else
        warn "No established connections on bridge (services may still be starting)"
    fi

    echo ""
    echo "  Server connections (to port 44333):"
    local server_conns
    server_conns=$(docker exec sigul-server netstat -tnp 2>/dev/null | grep ":44333" | grep "ESTABLISHED" || echo "")

    if [ -n "$server_conns" ]; then
        echo "$server_conns" | while read -r line; do
            echo "    ${line}"
        done
        success "Server has established connection to bridge"
    else
        warn "No established connection from server to bridge (may still be connecting)"
    fi

    echo ""
}

# Verify Docker network configuration
verify_docker_network() {
    log "Verifying Docker network configuration..."

    if ! docker network inspect sigul-network &>/dev/null; then
        error "sigul-network does not exist"
        return
    fi

    # Get network details
    local subnet
    subnet=$(docker network inspect sigul-network | jq -r '.[0].IPAM.Config[0].Subnet' 2>/dev/null)
    local gateway
    gateway=$(docker network inspect sigul-network | jq -r '.[0].IPAM.Config[0].Gateway' 2>/dev/null)

    echo "  Network: sigul-network"
    echo "  Subnet:  ${subnet}"
    echo "  Gateway: ${gateway}"

    success "Docker network is properly configured"
}

# Show container IP addresses
show_container_ips() {
    log "Container IP addresses..."

    local bridge_ip
    bridge_ip=$(docker inspect sigul-bridge | jq -r '.[0].NetworkSettings.Networks."sigul-network".IPAddress' 2>/dev/null)
    local server_ip
    server_ip=$(docker inspect sigul-server | jq -r '.[0].NetworkSettings.Networks."sigul-network".IPAddress' 2>/dev/null)

    echo "  Bridge: ${bridge_ip}"
    echo "  Server: ${server_ip}"

    # Verify expected IPs
    if [ "${bridge_ip}" = "172.20.0.2" ]; then
        echo "  ✓ Bridge has expected static IP"
    else
        echo "  ℹ Bridge using dynamic IP"
    fi

    if [ "${server_ip}" = "172.20.0.3" ]; then
        echo "  ✓ Server has expected static IP"
    else
        echo "  ℹ Server using dynamic IP"
    fi
}

# Test ping between containers
test_container_ping() {
    log "Testing network reachability (ping)..."

    # Server ping bridge
    if docker exec sigul-server ping -c 1 -W 2 sigul-bridge.example.org &>/dev/null; then
        success "Server can ping bridge"
    else
        warn "Server cannot ping bridge (ping may be disabled)"
    fi
}

# Verify port forwarding
verify_port_forwarding() {
    log "Verifying port forwarding to host..."

    # Check if port 44334 is exposed
    local exposed_ports
    exposed_ports=$(docker port sigul-bridge 2>/dev/null || echo "")

    if [ -n "$exposed_ports" ]; then
        echo "  Exposed ports:"
        echo "$exposed_ports" | while read -r line; do
            echo "    ${line}"
        done
        success "Ports are exposed to host"
    else
        warn "No ports exposed to host"
    fi
}

# Check network routing
verify_routing() {
    log "Checking network routing..."

    echo ""
    echo "  Bridge routing table:"
    docker exec sigul-bridge ip route 2>/dev/null | head -5 | while read -r line; do
        echo "    ${line}"
    done

    echo ""
    echo "  Server routing table:"
    docker exec sigul-server ip route 2>/dev/null | head -5 | while read -r line; do
        echo "    ${line}"
    done

    success "Routing tables retrieved"
}

# Generate summary report
generate_report() {
    echo ""
    log "=== Network Verification Summary ==="
    echo ""
    echo "  Tests Passed: ${TESTS_PASSED}"
    echo "  Tests Failed: ${TESTS_FAILED}"
    echo ""

    if [ ${TESTS_FAILED} -eq 0 ]; then
        success "=== All Network Tests Passed ==="
        return 0
    else
        error "=== Some Network Tests Failed ==="
        return 1
    fi
}

# Main verification function
main() {
    echo ""
    log "=== Network Connectivity Verification ==="
    echo ""

    check_containers_running
    echo ""

    verify_bridge_listening
    echo ""

    verify_server_connectivity
    echo ""

    verify_established_connections

    verify_docker_network
    echo ""

    show_container_ips
    echo ""

    test_container_ping
    echo ""

    verify_port_forwarding
    echo ""

    verify_routing
    echo ""

    generate_report
}

# Execute main function
main "$@"
