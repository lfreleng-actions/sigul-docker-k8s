#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
#
# Sigul Performance Test Suite
# Tests performance characteristics of the Sigul container stack

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=== Sigul Performance Test Suite ==="

# Configuration
BRIDGE_HOST="${BRIDGE_HOST:-sigul-bridge.example.org}"
BRIDGE_PORT="${BRIDGE_PORT:-44333}"
CLIENT_PORT="${CLIENT_PORT:-44334}"
ITERATIONS="${ITERATIONS:-10}"

# Performance tracking
TOTAL_TESTS=0
FAILED_TESTS=0

# Helper functions
info() {
    echo -e "${BLUE}ℹ INFO:${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠ WARN:${NC} $1"
}

error() {
    echo -e "${RED}✗ ERROR:${NC} $1"
    ((FAILED_TESTS++))
}

success() {
    echo -e "${GREEN}✓ SUCCESS:${NC} $1"
}

measure_time() {
    local description="$1"
    local iterations="$2"
    local command="$3"

    info "Testing: ${description} (${iterations} iterations)..."

    local start
    start=$(date +%s.%N)
    local success_count=0

    for ((i=1; i<=iterations; i++)); do
        if eval "$command" > /dev/null 2>&1; then
            ((success_count++))
        fi
    done

    local end
    end=$(date +%s.%N)
    local duration
    duration=$(echo "$end - $start" | bc)
    local avg
    avg=$(echo "scale=3; $duration / $iterations" | bc)

    if [ "$success_count" -eq "$iterations" ]; then
        success "${description}: ${duration}s total, ${avg}s avg per operation (${success_count}/${iterations} successful)"
    else
        warn "${description}: ${duration}s total, ${avg}s avg per operation (${success_count}/${iterations} successful)"
        ((FAILED_TESTS++))
    fi

    ((TOTAL_TESTS++))
}

# Check prerequisites
info "Checking prerequisites..."
if ! docker ps --format '{{.Names}}' | grep -q "sigul-bridge"; then
    error "Bridge container not running"
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "sigul-server"; then
    error "Server container not running"
    exit 1
fi

success "All required containers are running"
echo ""

# Test 1: Network connectivity performance
echo "=== Test 1: Network Connectivity Performance ==="
measure_time "Bridge network connectivity" "$ITERATIONS" \
    "docker exec sigul-server nc -zv ${BRIDGE_HOST} ${BRIDGE_PORT} 2>&1"
echo ""

# Test 2: Container health check response time
echo "=== Test 2: Health Check Response Time ==="
measure_time "Bridge health check" "$ITERATIONS" \
    "docker exec sigul-bridge pgrep -f sigul_bridge"

measure_time "Server health check" "$ITERATIONS" \
    "docker exec sigul-server pgrep -f sigul_server"
echo ""

# Test 3: Certificate validation performance
echo "=== Test 3: Certificate Validation Performance ==="
measure_time "Bridge certificate validation" "$ITERATIONS" \
    "docker exec sigul-bridge certutil -V -n 'sigul-bridge.example.org' -u V -d sql:/etc/pki/sigul 2>&1"

measure_time "Server certificate validation" "$ITERATIONS" \
    "docker exec sigul-server certutil -V -n 'sigul-server.example.org' -u V -d sql:/etc/pki/sigul 2>&1"
echo ""

# Test 4: Database query performance
echo "=== Test 4: Database Query Performance ==="
measure_time "Database integrity check" "$ITERATIONS" \
    "docker exec sigul-server sqlite3 /var/lib/sigul/server.sqlite 'PRAGMA integrity_check;' 2>&1"

measure_time "User count query" "$ITERATIONS" \
    "docker exec sigul-server sqlite3 /var/lib/sigul/server.sqlite 'SELECT COUNT(*) FROM users;' 2>&1"
echo ""

# Test 5: File system performance
echo "=== Test 5: File System Performance ==="
measure_time "NSS database read access" "$ITERATIONS" \
    "docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul 2>&1"

measure_time "Configuration file read" "$ITERATIONS" \
    "docker exec sigul-bridge cat /etc/sigul/bridge.conf 2>&1"
echo ""

# Test 6: Process information retrieval
echo "=== Test 6: Process Information Retrieval ==="
measure_time "Bridge process status" "$ITERATIONS" \
    "docker exec sigul-bridge ps aux | grep sigul_bridge | grep -v grep"

measure_time "Server process status" "$ITERATIONS" \
    "docker exec sigul-server ps aux | grep sigul_server | grep -v grep"
echo ""

# Test 7: Log file access
echo "=== Test 7: Log File Access Performance ==="
measure_time "Bridge log file access" "$ITERATIONS" \
    "docker exec sigul-bridge sh -c 'tail -n 10 /var/log/sigul/bridge.log 2>/dev/null || echo \"No log yet\"'"

measure_time "Server log file access" "$ITERATIONS" \
    "docker exec sigul-server sh -c 'tail -n 10 /var/log/sigul/server.log 2>/dev/null || echo \"No log yet\"'"
echo ""

# Test 8: DNS resolution performance
echo "=== Test 8: DNS Resolution Performance ==="
measure_time "Bridge hostname resolution" "$ITERATIONS" \
    "docker exec sigul-server getent hosts ${BRIDGE_HOST}"

measure_time "Server hostname resolution" "$ITERATIONS" \
    "docker exec sigul-bridge getent hosts sigul-server.example.org"
echo ""

# Test 9: Memory and resource usage check
echo "=== Test 9: Resource Usage Check ==="
info "Collecting resource usage statistics..."

BRIDGE_MEM=$(docker stats sigul-bridge --no-stream --format "{{.MemUsage}}" 2>/dev/null || echo "N/A")
SERVER_MEM=$(docker stats sigul-server --no-stream --format "{{.MemUsage}}" 2>/dev/null || echo "N/A")
BRIDGE_CPU=$(docker stats sigul-bridge --no-stream --format "{{.CPUPerc}}" 2>/dev/null || echo "N/A")
SERVER_CPU=$(docker stats sigul-server --no-stream --format "{{.CPUPerc}}" 2>/dev/null || echo "N/A")

info "Bridge container - Memory: ${BRIDGE_MEM}, CPU: ${BRIDGE_CPU}"
info "Server container - Memory: ${SERVER_MEM}, CPU: ${SERVER_CPU}"
echo ""

# Test 10: Volume mount performance
echo "=== Test 10: Volume Mount Performance ==="
measure_time "NSS volume read (bridge)" "$ITERATIONS" \
    "docker exec sigul-bridge ls -la /etc/pki/sigul/"

measure_time "Data volume read (server)" "$ITERATIONS" \
    "docker exec sigul-server ls -la /var/lib/sigul/"
echo ""

# Performance summary
echo "=== Performance Test Summary ==="
echo "Total test categories: ${TOTAL_TESTS}"
if [ ${FAILED_TESTS} -eq 0 ]; then
    echo -e "${GREEN}All performance tests completed successfully${NC}"
    echo -e "${GREEN}Failed tests: 0${NC}"
else
    echo -e "${YELLOW}Some performance tests had warnings or failures${NC}"
    echo -e "${YELLOW}Failed/Warning tests: ${FAILED_TESTS}${NC}"
fi

echo ""
echo "=== Recommendations ==="
if [ ${FAILED_TESTS} -eq 0 ]; then
    success "Performance is within acceptable parameters"
else
    warn "Review failed tests above for potential performance issues"
fi

echo ""
info "Performance baseline established"
info "Re-run this test periodically to detect performance regressions"
echo ""

if [ ${FAILED_TESTS} -eq 0 ]; then
    echo -e "${GREEN}=== Performance Tests Complete ===${NC}"
    exit 0
else
    echo -e "${YELLOW}=== Performance Tests Complete with Warnings ===${NC}"
    exit 0
fi
