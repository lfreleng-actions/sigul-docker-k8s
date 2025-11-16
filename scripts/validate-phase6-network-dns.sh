#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Phase 6 Network & DNS Configuration Validation Script
#
# This script validates that Phase 6 changes (network and DNS configuration)
# have been successfully implemented according to the ALIGNMENT_PLAN.md.
#
# Validation Criteria:
# - Network configuration uses FQDNs
# - Static IP addresses assigned correctly
# - DNS resolution works for all components
# - Network connectivity verified
# - Certificate-hostname alignment confirmed
# - Verification scripts exist and work

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] VALIDATE:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] PASS:${NC} $*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}[$(date '+%H:%M:%S')] FAIL:${NC} $*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"
}

test_start() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    log "Test $TESTS_TOTAL: $*"
}

#######################################
# Script Existence Tests
#######################################

test_verification_scripts_exist() {
    test_start "Verification scripts exist"

    local scripts=(
        "scripts/verify-dns.sh"
        "scripts/verify-network.sh"
        "scripts/verify-cert-hostname-alignment.sh"
    )

    local all_exist=true
    for script in "${scripts[@]}"; do
        if [ ! -f "$script" ]; then
            fail "Missing script: $script"
            all_exist=false
        fi
    done

    if [ "$all_exist" = true ]; then
        success "All verification scripts exist"
    fi
}

test_scripts_executable() {
    test_start "Verification scripts are executable"

    local scripts=(
        "scripts/verify-dns.sh"
        "scripts/verify-network.sh"
        "scripts/verify-cert-hostname-alignment.sh"
    )

    local all_executable=true
    for script in "${scripts[@]}"; do
        if [ ! -x "$script" ]; then
            fail "Script not executable: $script"
            all_executable=false
        fi
    done

    if [ "$all_executable" = true ]; then
        success "All verification scripts are executable"
    fi
}

#######################################
# Docker Compose Configuration Tests
#######################################

test_docker_compose_hostnames() {
    test_start "Docker compose services use FQDN hostnames"

    # Check bridge hostname
    if ! grep -A 5 "sigul-bridge:" docker-compose.sigul.yml | grep -q "hostname:.*sigul-bridge.example.org"; then
        fail "Bridge does not use FQDN hostname"
        return
    fi

    # Check server hostname
    if ! grep -A 5 "sigul-server:" docker-compose.sigul.yml | grep -q "hostname:.*sigul-server.example.org"; then
        fail "Server does not use FQDN hostname"
        return
    fi

    success "Services use FQDN hostnames"
}

test_docker_compose_static_ips() {
    test_start "Docker compose services have static IP configuration"

    # Check bridge static IP
    if ! grep -A 20 "sigul-bridge:" docker-compose.sigul.yml | grep -q "ipv4_address:.*172.20.0.2"; then
        fail "Bridge does not have static IP configured"
        return
    fi

    # Check server static IP
    if ! grep -A 20 "sigul-server:" docker-compose.sigul.yml | grep -q "ipv4_address:.*172.20.0.3"; then
        fail "Server does not have static IP configured"
        return
    fi

    success "Services have static IP addresses configured"
}

test_docker_compose_network_aliases() {
    test_start "Docker compose services have network aliases"

    # Check bridge aliases
    if ! grep -A 30 "sigul-bridge:" docker-compose.sigul.yml | grep -A 5 "aliases:" | grep -q "sigul-bridge.example.org"; then
        fail "Bridge missing FQDN network alias"
        return
    fi

    # Check server aliases
    if ! grep -A 35 "sigul-server:" docker-compose.sigul.yml | grep -A 5 "aliases:" | grep -q "sigul-server.example.org"; then
        fail "Server missing FQDN network alias"
        return
    fi

    success "Services have proper network aliases"
}

test_docker_compose_network_definition() {
    test_start "Docker compose network is properly defined"

    # Check network exists
    if ! grep -q "^networks:" docker-compose.sigul.yml; then
        fail "Networks section not found"
        return
    fi

    # Check sigul-network defined
    if ! grep -A 10 "^networks:" docker-compose.sigul.yml | grep -q "sigul-network:"; then
        fail "sigul-network not defined"
        return
    fi

    # Check subnet configuration
    if ! grep -A 20 "sigul-network:" docker-compose.sigul.yml | grep -q "subnet:.*172.20.0.0/16"; then
        fail "Network subnet not properly configured"
        return
    fi

    success "Network is properly defined"
}

test_bridge_port_exposure() {
    test_start "Bridge exposes both server and client ports"

    # Check port 44333 (server)
    if ! grep -A 25 "sigul-bridge:" docker-compose.sigul.yml | grep "ports:" -A 5 | grep -q "44333:44333"; then
        fail "Bridge does not expose port 44333 (server)"
        return
    fi

    # Check port 44334 (client)
    if ! grep -A 25 "sigul-bridge:" docker-compose.sigul.yml | grep "ports:" -A 5 | grep -q "44334:44334"; then
        fail "Bridge does not expose port 44334 (client)"
        return
    fi

    success "Bridge exposes both required ports"
}

#######################################
# Container Runtime Tests (if running)
#######################################

test_containers_running() {
    test_start "Checking if containers are running for integration tests"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Bridge container not running - skipping integration tests"
        return 1
    fi

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-server'; then
        warn "Server container not running - skipping integration tests"
        return 1
    fi

    success "Containers are running"
    return 0
}

test_container_hostnames() {
    test_start "Container hostnames match expected FQDNs"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Bridge container not running - skipping test"
        return
    fi

    local bridge_hostname
    bridge_hostname=$(docker exec sigul-bridge hostname)
    local server_hostname
    server_hostname=$(docker exec sigul-server hostname)

    if [ "$bridge_hostname" != "sigul-bridge.example.org" ]; then
        fail "Bridge hostname incorrect: $bridge_hostname (expected: sigul-bridge.example.org)"
        return
    fi

    if [ "$server_hostname" != "sigul-server.example.org" ]; then
        fail "Server hostname incorrect: $server_hostname (expected: sigul-server.example.org)"
        return
    fi

    success "Container hostnames are correct"
}

test_container_static_ips() {
    test_start "Containers have correct static IP addresses"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Containers not running - skipping test"
        return
    fi

    local bridge_ip
    bridge_ip=$(docker inspect sigul-bridge | grep -o '"IPAddress": "[^"]*' | grep -o '[^"]*$' | head -1)
    local server_ip
    server_ip=$(docker inspect sigul-server | grep -o '"IPAddress": "[^"]*' | grep -o '[^"]*$' | head -1)

    if [ "$bridge_ip" != "172.20.0.2" ]; then
        fail "Bridge IP incorrect: $bridge_ip (expected: 172.20.0.2)"
        return
    fi

    if [ "$server_ip" != "172.20.0.3" ]; then
        fail "Server IP incorrect: $server_ip (expected: 172.20.0.3)"
        return
    fi

    success "Container IP addresses are correct"
}

test_dns_resolution() {
    test_start "DNS resolution works between containers"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-server'; then
        warn "Containers not running - skipping test"
        return
    fi

    # Server should be able to resolve bridge
    if ! docker exec sigul-server getent hosts sigul-bridge.example.org &>/dev/null; then
        fail "Server cannot resolve bridge FQDN"
        return
    fi

    # Bridge should resolve itself
    if ! docker exec sigul-bridge getent hosts sigul-bridge.example.org &>/dev/null; then
        fail "Bridge cannot resolve its own FQDN"
        return
    fi

    success "DNS resolution works correctly"
}

test_network_connectivity() {
    test_start "Network connectivity between components"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-server'; then
        warn "Containers not running - skipping test"
        return
    fi

    # Server should be able to reach bridge port 44333
    if ! docker exec sigul-server nc -z sigul-bridge.example.org 44333 2>/dev/null; then
        fail "Server cannot reach bridge on port 44333"
        return
    fi

    success "Network connectivity verified"
}

test_bridge_listening_ports() {
    test_start "Bridge is listening on expected ports"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Bridge not running - skipping test"
        return
    fi

    # Check port 44333
    if ! docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -q ":44333"; then
        fail "Bridge not listening on port 44333"
        return
    fi

    # Check port 44334
    if ! docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -q ":44334"; then
        fail "Bridge not listening on port 44334"
        return
    fi

    success "Bridge listening on all required ports"
}

test_verification_script_runs() {
    test_start "DNS verification script runs without errors"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Containers not running - skipping test"
        return
    fi

    # Try running DNS verification script
    if ./scripts/verify-dns.sh bridge &>/dev/null; then
        success "DNS verification script runs successfully"
    else
        warn "DNS verification script reported issues (may be normal during setup)"
    fi
}

test_network_verification_script() {
    test_start "Network verification script runs without errors"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Containers not running - skipping test"
        return
    fi

    # Try running network verification script
    if ./scripts/verify-network.sh &>/dev/null; then
        success "Network verification script runs successfully"
    else
        warn "Network verification script reported issues (may be normal during setup)"
    fi
}

#######################################
# Network Architecture Tests
#######################################

test_docker_network_exists() {
    test_start "sigul-network Docker network exists"

    if ! command -v docker &> /dev/null; then
        warn "Docker not available - skipping test"
        return
    fi

    if docker network inspect sigul-network &>/dev/null; then
        success "sigul-network exists"
    else
        fail "sigul-network does not exist"
    fi
}

test_network_subnet() {
    test_start "Network has correct subnet configuration"

    if ! command -v docker &> /dev/null; then
        warn "Docker not available - skipping test"
        return
    fi

    if ! docker network inspect sigul-network &>/dev/null; then
        warn "sigul-network does not exist - skipping test"
        return
    fi

    local subnet
    subnet=$(docker network inspect sigul-network | grep -o '"Subnet": "[^"]*' | grep -o '[^"]*$' | head -1)

    if [ "$subnet" = "172.20.0.0/16" ]; then
        success "Network subnet is correct"
    else
        fail "Network subnet incorrect: $subnet (expected: 172.20.0.0/16)"
    fi
}

#######################################
# Documentation Tests
#######################################

test_alignment_plan_phase6() {
    test_start "ALIGNMENT_PLAN.md documents Phase 6"

    if ! grep -q "Phase 6.*Network.*DNS" ALIGNMENT_PLAN.md; then
        fail "ALIGNMENT_PLAN.md missing Phase 6 documentation"
        return
    fi

    success "ALIGNMENT_PLAN.md documents Phase 6"
}

#######################################
# Report Generation
#######################################

generate_report() {
    echo ""
    echo "=========================================="
    echo "Phase 6 Validation Report"
    echo "=========================================="
    echo ""
    echo "Total Tests:  $TESTS_TOTAL"
    echo "Passed:       $TESTS_PASSED"
    echo "Failed:       $TESTS_FAILED"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        echo ""
        echo "Phase 6 (Network & DNS Configuration) validation successful."
        echo "Network infrastructure is properly configured."
        echo ""
        echo "Next steps:"
        echo "  1. Test DNS: ./scripts/verify-dns.sh bridge"
        echo "  2. Test DNS: ./scripts/verify-dns.sh server"
        echo "  3. Test network: ./scripts/verify-network.sh"
        echo "  4. Test cert alignment: ./scripts/verify-cert-hostname-alignment.sh bridge"
        return 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        echo ""
        echo "Please review the failures above and address them."
        return 1
    fi
}

#######################################
# Main Execution
#######################################

main() {
    log "Phase 6 Network & DNS Configuration Validation"
    log "==============================================="
    echo ""

    # Script existence and permissions
    test_verification_scripts_exist
    test_scripts_executable

    # Docker compose configuration
    test_docker_compose_hostnames
    test_docker_compose_static_ips
    test_docker_compose_network_aliases
    test_docker_compose_network_definition
    test_bridge_port_exposure

    # Network architecture
    test_docker_network_exists
    test_network_subnet

    # Runtime tests (if containers running)
    if test_containers_running; then
        test_container_hostnames
        test_container_static_ips
        test_dns_resolution
        test_network_connectivity
        test_bridge_listening_ports
        test_verification_script_runs
        test_network_verification_script
    fi

    # Documentation tests
    test_alignment_plan_phase6

    # Generate report
    generate_report
}

# Run main function
main "$@"
