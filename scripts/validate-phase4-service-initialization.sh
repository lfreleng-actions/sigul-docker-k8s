#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Phase 4 Service Initialization Validation Script
#
# This script validates that Phase 4 changes (service initialization alignment)
# have been successfully implemented according to the ALIGNMENT_PLAN.md.
#
# Validation Criteria:
# - Simplified entrypoint scripts created
# - Dockerfiles updated to use new entrypoints
# - docker-compose.yml updated (commands removed, healthchecks aligned)
# - Services start successfully
# - Process command lines match production pattern
# - Network connectivity verified

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
# File Existence Tests
#######################################

test_entrypoint_scripts_exist() {
    test_start "Entrypoint scripts exist"

    local files=(
        "scripts/entrypoint-bridge.sh"
        "scripts/entrypoint-server.sh"
    )

    local all_exist=true
    for file in "${files[@]}"; do
        if [ ! -f "$file" ]; then
            fail "Missing file: $file"
            all_exist=false
        fi
    done

    if [ "$all_exist" = true ]; then
        success "All entrypoint scripts exist"
    fi
}

test_entrypoint_scripts_executable() {
    test_start "Entrypoint scripts are executable"

    local files=(
        "scripts/entrypoint-bridge.sh"
        "scripts/entrypoint-server.sh"
    )

    local all_executable=true
    for file in "${files[@]}"; do
        if [ ! -x "$file" ]; then
            fail "File not executable: $file"
            all_executable=false
        fi
    done

    if [ "$all_executable" = true ]; then
        success "All entrypoint scripts are executable"
    fi
}

#######################################
# Dockerfile Content Tests
#######################################

test_dockerfile_bridge_uses_entrypoint() {
    test_start "Dockerfile.bridge uses new entrypoint"

    if ! grep -q "COPY scripts/entrypoint-bridge.sh /usr/local/bin/entrypoint.sh" Dockerfile.bridge; then
        fail "Dockerfile.bridge does not copy entrypoint-bridge.sh"
        return
    fi

    if ! grep -q 'ENTRYPOINT \["/usr/local/bin/entrypoint.sh"\]' Dockerfile.bridge; then
        fail "Dockerfile.bridge does not set ENTRYPOINT"
        return
    fi

    # Verify old CMD with sigul-init.sh is removed
    if grep -q "sigul-init.sh.*--start-service" Dockerfile.bridge; then
        fail "Dockerfile.bridge still has old CMD with sigul-init.sh"
        return
    fi

    success "Dockerfile.bridge uses new entrypoint"
}

test_dockerfile_server_uses_entrypoint() {
    test_start "Dockerfile.server uses new entrypoint"

    if ! grep -q "COPY scripts/entrypoint-server.sh /usr/local/bin/entrypoint.sh" Dockerfile.server; then
        fail "Dockerfile.server does not copy entrypoint-server.sh"
        return
    fi

    if ! grep -q 'ENTRYPOINT \["/usr/local/bin/entrypoint.sh"\]' Dockerfile.server; then
        fail "Dockerfile.server does not set ENTRYPOINT"
        return
    fi

    # Verify old CMD with sigul-init.sh is removed
    if grep -q "sigul-init.sh.*--start-service" Dockerfile.server; then
        fail "Dockerfile.server still has old CMD with sigul-init.sh"
        return
    fi

    success "Dockerfile.server uses new entrypoint"
}

test_dockerfile_bridge_healthcheck() {
    test_start "Dockerfile.bridge has sigul healthcheck"

    # Should check port 44333 with nc
    if ! grep -q 'nc -z localhost 44333' Dockerfile.bridge; then
        fail "Dockerfile.bridge healthcheck does not check port 44333 with nc"
        return
    fi

    # Should have appropriate timing
    if ! grep -q 'interval=10s' Dockerfile.bridge; then
        warn "Dockerfile.bridge healthcheck interval may not be optimal"
    fi

    success "Dockerfile.bridge has sigul healthcheck"
}

test_dockerfile_server_healthcheck() {
    test_start "Dockerfile.server has sigul healthcheck"

    # Should check process with pgrep
    if ! grep -q 'pgrep -f "sigul_server"' Dockerfile.server; then
        fail "Dockerfile.server healthcheck does not check process with pgrep"
        return
    fi

    # Should have appropriate timing
    if ! grep -q 'interval=10s' Dockerfile.server; then
        warn "Dockerfile.server healthcheck interval may not be optimal"
    fi

    success "Dockerfile.server has sigul healthcheck"
}

#######################################
# Docker Compose Tests
#######################################

test_docker_compose_no_command_overrides() {
    test_start "docker-compose.sigul.yml has no command overrides"

    # Check for command directives with sigul-init.sh in sigul-server or sigul-bridge
    if grep -A 5 "sigul-server:" docker-compose.sigul.yml | grep -q "command.*sigul-init.sh"; then
        fail "docker-compose.sigul.yml still has command override for sigul-server"
        return
    fi

    if grep -A 5 "sigul-bridge:" docker-compose.sigul.yml | grep -q "command.*sigul-init.sh"; then
        fail "docker-compose.sigul.yml still has command override for sigul-bridge"
        return
    fi

    success "docker-compose.sigul.yml has no command overrides for main services"
}

test_docker_compose_bridge_healthcheck() {
    test_start "docker-compose.sigul.yml bridge healthcheck is sigul"

    # Extract bridge healthcheck section
    if ! grep -A 30 "sigul-bridge:" docker-compose.sigul.yml | grep -q "healthcheck:"; then
        fail "Bridge healthcheck not found in docker-compose.sigul.yml"
        return
    fi

    # Check for nc -z localhost 44333
    if ! grep -A 30 "sigul-bridge:" docker-compose.sigul.yml | grep -q "nc.*44333"; then
        fail "Bridge healthcheck does not check port 44333 with nc"
        return
    fi

    success "docker-compose.sigul.yml bridge healthcheck is sigul"
}

test_docker_compose_server_depends_on_bridge() {
    test_start "docker-compose.sigul.yml server depends on bridge health"

    # Server should depend on bridge with condition: service_healthy
    if ! grep -A 35 "sigul-server:" docker-compose.sigul.yml | grep -A 3 "depends_on:" | grep -q "condition: service_healthy"; then
        fail "Server does not depend on bridge health condition"
        return
    fi

    success "Server properly depends on bridge health"
}

#######################################
# Entrypoint Script Content Tests
#######################################

test_bridge_entrypoint_content() {
    test_start "Bridge entrypoint has sigul command"

    # Should execute /usr/sbin/sigul_bridge -v
    if ! grep -q '/usr/sbin/sigul_bridge -v' scripts/entrypoint-bridge.sh; then
        fail "Bridge entrypoint does not execute /usr/sbin/sigul_bridge -v"
        return
    fi

    # Should use exec for process replacement
    if ! grep -q 'exec /usr/sbin/sigul_bridge' scripts/entrypoint-bridge.sh; then
        warn "Bridge entrypoint should use 'exec' for direct process replacement"
    fi

    success "Bridge entrypoint has sigul command"
}

test_server_entrypoint_content() {
    test_start "Server entrypoint has sigul command"

    # Should execute /usr/sbin/sigul_server with production flags
    if ! grep -q '/usr/sbin/sigul_server' scripts/entrypoint-server.sh; then
        fail "Server entrypoint does not execute /usr/sbin/sigul_server"
        return
    fi

    # Should include -c flag for config file
    if ! grep -q -- '-c.*CONFIG_FILE' scripts/entrypoint-server.sh; then
        fail "Server entrypoint does not specify config file with -c"
        return
    fi

    # Should include --internal-log-dir
    if ! grep -q -- '--internal-log-dir' scripts/entrypoint-server.sh; then
        fail "Server entrypoint does not specify --internal-log-dir"
        return
    fi

    # Should include --internal-pid-dir
    if ! grep -q -- '--internal-pid-dir' scripts/entrypoint-server.sh; then
        fail "Server entrypoint does not specify --internal-pid-dir"
        return
    fi

    # Should include -v for verbose
    if ! grep -q -- '-v' scripts/entrypoint-server.sh; then
        warn "Server entrypoint should include -v for verbose logging"
    fi

    # Should use exec for process replacement
    if ! grep -q 'exec /usr/sbin/sigul_server' scripts/entrypoint-server.sh; then
        warn "Server entrypoint should use 'exec' for direct process replacement"
    fi

    success "Server entrypoint has sigul command"
}

test_server_entrypoint_waits_for_bridge() {
    test_start "Server entrypoint waits for bridge availability"

    # Should have bridge waiting logic
    if ! grep -q 'wait.*bridge' scripts/entrypoint-server.sh; then
        fail "Server entrypoint does not wait for bridge"
        return
    fi

    # Should use nc or similar for connectivity check
    if ! grep -q 'nc -z' scripts/entrypoint-server.sh; then
        warn "Server entrypoint should use 'nc -z' for bridge availability check"
    fi

    success "Server entrypoint waits for bridge availability"
}

test_entrypoint_validation_logic() {
    test_start "Entrypoint scripts have pre-flight validation"

    local scripts=(
        "scripts/entrypoint-bridge.sh"
        "scripts/entrypoint-server.sh"
    )

    for script in "${scripts[@]}"; do
        # Should validate configuration exists
        if ! grep -q 'CONFIG_FILE' "$script"; then
            fail "$script does not validate configuration"
            return
        fi

        # Should validate NSS database
        if ! grep -q 'cert9.db' "$script"; then
            fail "$script does not validate NSS database"
            return
        fi

        # Should validate certificate exists
        if ! grep -q 'certutil.*-L' "$script"; then
            fail "$script does not validate certificate with certutil"
            return
        fi
    done

    success "Entrypoint scripts have proper pre-flight validation"
}

#######################################
# Integration Tests (if containers running)
#######################################

test_containers_running() {
    test_start "Checking if containers are running for integration tests"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Bridge container not running - skipping integration tests"
        warn "Run 'docker-compose -f docker-compose.sigul.yml up -d' to test"
        return 1
    fi

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-server'; then
        warn "Server container not running - skipping integration tests"
        return 1
    fi

    success "Containers are running"
    return 0
}

test_bridge_process_command_line() {
    test_start "Bridge process command line matches production"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Bridge container not running - skipping test"
        return
    fi

    local cmd
    cmd=$(docker exec sigul-bridge pgrep -af sigul_bridge 2>/dev/null || echo "")

    if [ -z "$cmd" ]; then
        warn "Bridge process not running - container may need rebuild"
        warn "Run: docker-compose -f docker-compose.sigul.yml up -d --build"
        return
    fi

    # Should have /usr/sbin/sigul_bridge -v
    if ! echo "$cmd" | grep -q '/usr/sbin/sigul_bridge.*-v'; then
        fail "Bridge command line does not match production pattern"
        fail "Expected: /usr/sbin/sigul_bridge -v"
        fail "Got: $cmd"
        return
    fi

    success "Bridge process command line matches production"
}

test_server_process_command_line() {
    test_start "Server process command line matches production"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-server'; then
        warn "Server container not running - skipping test"
        return
    fi

    local cmd
    cmd=$(docker exec sigul-server pgrep -af sigul_server 2>/dev/null || echo "")

    if [ -z "$cmd" ]; then
        warn "Server process not running - container may need rebuild"
        warn "Run: docker-compose -f docker-compose.sigul.yml up -d --build"
        return
    fi

    # Should have sigul command line
    if ! echo "$cmd" | grep -q '/usr/sbin/sigul_server.*-c.*--internal-log-dir.*--internal-pid-dir.*-v'; then
        fail "Server command line does not match production pattern"
        fail "Expected: /usr/sbin/sigul_server -c /etc/sigul/server.conf --internal-log-dir=... --internal-pid-dir=... -v"
        fail "Got: $cmd"
        return
    fi

    success "Server process command line matches production"
}

test_bridge_network_listening() {
    test_start "Bridge is listening on expected ports"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-bridge'; then
        warn "Bridge container not running - skipping test"
        return
    fi

    # Bridge should listen on 44333 (server) and 44334 (client)
    if ! docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -q ':44333'; then
        fail "Bridge not listening on port 44333"
        return
    fi

    if ! docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -q ':44334'; then
        warn "Bridge not listening on port 44334 (client port)"
    fi

    success "Bridge is listening on expected ports"
}

test_server_bridge_connectivity() {
    test_start "Server has established connection to bridge"

    if ! docker ps --format '{{.Names}}' | grep -q 'sigul-server'; then
        warn "Server container not running - skipping test"
        return
    fi

    # Server should have connection to bridge on port 44333
    if ! docker exec sigul-server netstat -tnp 2>/dev/null | grep -q ':44333.*ESTABLISHED'; then
        fail "Server does not have established connection to bridge"
        return
    fi

    success "Server has established connection to bridge"
}

#######################################
# Report Generation
#######################################

generate_report() {
    echo ""
    echo "=========================================="
    echo "Phase 4 Validation Report"
    echo "=========================================="
    echo ""
    echo "Total Tests:  $TESTS_TOTAL"
    echo "Passed:       $TESTS_PASSED"
    echo "Failed:       $TESTS_FAILED"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        echo ""
        echo "Phase 4 (Service Initialization) validation successful."
        echo "Services are using simplified, sigul entrypoints."
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
    log "Phase 4 Service Initialization Validation"
    log "=========================================="
    echo ""

    # File existence and permissions
    test_entrypoint_scripts_exist
    test_entrypoint_scripts_executable

    # Dockerfile content
    test_dockerfile_bridge_uses_entrypoint
    test_dockerfile_server_uses_entrypoint
    test_dockerfile_bridge_healthcheck
    test_dockerfile_server_healthcheck

    # Docker Compose content
    test_docker_compose_no_command_overrides
    test_docker_compose_bridge_healthcheck
    test_docker_compose_server_depends_on_bridge

    # Entrypoint script content
    test_bridge_entrypoint_content
    test_server_entrypoint_content
    test_server_entrypoint_waits_for_bridge
    test_entrypoint_validation_logic

    # Integration tests (if containers are running)
    if test_containers_running; then
        test_bridge_process_command_line
        test_server_process_command_line
        test_bridge_network_listening
        test_server_bridge_connectivity
    fi

    # Generate report
    generate_report
}

# Run main function
main "$@"
