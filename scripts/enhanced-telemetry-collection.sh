#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Enhanced Telemetry Collection Script for Sigul Stack Debugging
#
# This script addresses the critical telemetry collection gaps that prevent
# effective debugging of the NSS integrity check failures and other startup issues.
#
# Key improvements:
# - Captures NSS database state before containers exit
# - Collects certificate generation and import logs
# - Provides detailed directory structure analysis
# - Handles permission and timing issues in log collection
# - Generates comprehensive failure analysis reports
#
# Usage:
#   ./scripts/enhanced-telemetry-collection.sh [OPTIONS]
#
# Options:
#   --containers <name1,name2>  Comma-separated list of containers to monitor
#   --output-dir <path>         Directory to save telemetry data
#   --real-time                 Enable real-time monitoring mode
#   --capture-volumes           Capture volume state via temporary containers
#   --verbose                   Enable verbose output
#   --help                      Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default options
CONTAINERS=""
OUTPUT_DIR="${PROJECT_ROOT}/enhanced-telemetry-$(date +%Y%m%d-%H%M%S)"
REAL_TIME_MODE=false
CAPTURE_VOLUMES=false
VERBOSE_MODE=false
SHOW_HELP=false

# Monitoring state
MONITORING_ACTIVE=false
MONITOR_PID=""

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
    echo -e "${BLUE}[$(date '+%H:%M:%S')] INFO:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SUCCESS:${NC} $*"
}

verbose() {
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${CYAN}[$(date '+%H:%M:%S')] VERBOSE:${NC} $*"
    fi
}

debug() {
    echo -e "${PURPLE}[$(date '+%H:%M:%S')] DEBUG:${NC} $*"
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --containers)
                CONTAINERS="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --real-time)
                REAL_TIME_MODE=true
                shift
                ;;
            --capture-volumes)
                CAPTURE_VOLUMES=true
                shift
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
                exit 1
                ;;
        esac
    done
}

# Show help
show_help() {
    cat << EOF
Enhanced Telemetry Collection Script for Sigul Stack Debugging

This script provides comprehensive telemetry collection to address gaps
in diagnostic information during container failures and startup issues.

FEATURES:
- Real-time container monitoring with failure detection
- NSS database state capture before containers exit
- Certificate generation and import process logging
- Directory structure and permission analysis
- Volume state capture via temporary containers
- Comprehensive failure analysis reports

OPTIONS:
  --containers <list>     Comma-separated container names (default: auto-detect sigul containers)
  --output-dir <path>     Output directory (default: enhanced-telemetry-TIMESTAMP)
  --real-time            Enable continuous monitoring mode
  --capture-volumes      Capture volume state using temporary inspection containers
  --verbose              Enable detailed logging
  --help                 Show this help message

USAGE EXAMPLES:
  # Monitor specific containers
  ./enhanced-telemetry-collection.sh --containers sigul-server,sigul-bridge --verbose

  # Real-time monitoring with volume capture
  ./enhanced-telemetry-collection.sh --real-time --capture-volumes

  # One-time comprehensive collection
  ./enhanced-telemetry-collection.sh --containers sigul-server,sigul-bridge --capture-volumes --output-dir ./debug-output

OUTPUT STRUCTURE:
  enhanced-telemetry-TIMESTAMP/
  ├── containers/                 # Container-specific telemetry
  │   ├── sigul-server/
  │   │   ├── logs-timeline.txt   # Timestamped log collection
  │   │   ├── nss-state.txt       # NSS database analysis
  │   │   ├── cert-analysis.txt   # Certificate validation
  │   │   └── failure-analysis.txt
  │   └── sigul-bridge/
  │       └── ... (similar structure)
  ├── volumes/                    # Volume state captures
  │   ├── server-volume-state.txt
  │   └── bridge-volume-state.txt
  ├── system/                     # System-level information
  │   ├── docker-state.txt
  │   ├── network-analysis.txt
  │   └── resource-usage.txt
  └── reports/                    # Analysis reports
      ├── failure-summary.md
      ├── nss-integrity-analysis.md
      └── recommendations.md
EOF
}

# Initialize telemetry collection
init_telemetry() {
    log "Initializing enhanced telemetry collection"

    # Create output directory structure
    mkdir -p "$OUTPUT_DIR"/{containers,volumes,system,reports}

    # Set up logging
    exec 1> >(tee -a "$OUTPUT_DIR/telemetry-session.log")
    exec 2> >(tee -a "$OUTPUT_DIR/telemetry-errors.log" >&2)

    # Record session info
    {
        echo "=== Enhanced Telemetry Collection Session ==="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Output Directory: $OUTPUT_DIR"
        echo "Real-time Mode: $REAL_TIME_MODE"
        echo "Volume Capture: $CAPTURE_VOLUMES"
        echo "Target Containers: ${CONTAINERS:-auto-detect}"
        echo ""
        echo "=== Environment Information ==="
        echo "Docker Version: $(docker --version 2>/dev/null || echo 'not available')"
        echo "Docker Compose: $(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo 'not available')"
        echo "Platform: $(uname -a)"
        echo "Working Directory: $(pwd)"
        echo ""
        echo "=== Current Docker State ==="
        docker ps -a 2>/dev/null || echo "Cannot access Docker"
        echo ""
        docker volume ls 2>/dev/null || echo "Cannot list volumes"
        echo ""
        echo "==============================="
    } > "$OUTPUT_DIR/session-info.txt"

    log "Telemetry output directory: $OUTPUT_DIR"
}

# Auto-detect sigul containers
detect_sigul_containers() {
    if [[ -z "$CONTAINERS" ]]; then
        verbose "Auto-detecting sigul containers"
        CONTAINERS=$(docker ps -a --filter "name=sigul" --format "{{.Names}}" | tr '\n' ',' | sed 's/,$//')

        if [[ -z "$CONTAINERS" ]]; then
            warn "No sigul containers found"
            return 1
        fi

        verbose "Detected containers: $CONTAINERS"
    fi

    # Convert comma-separated list to array
    IFS=',' read -ra CONTAINER_LIST <<< "$CONTAINERS"

    log "Monitoring containers: ${CONTAINER_LIST[*]}"
}

# Capture system-level telemetry
capture_system_telemetry() {
    verbose "Capturing system-level telemetry"

    {
        echo "=== Docker System Information ==="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""

        echo "=== Docker System Overview ==="
        docker system df 2>/dev/null || echo "Cannot get system usage"
        echo ""

        echo "=== Container States ==="
        docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>/dev/null || echo "Cannot list containers"
        echo ""

        echo "=== Volume Information ==="
        docker volume ls 2>/dev/null || echo "Cannot list volumes"
        echo ""

        echo "=== Network Information ==="
        docker network ls 2>/dev/null || echo "Cannot list networks"
        echo ""

        echo "=== Sigul Network Details ==="
        for network in $(docker network ls --filter "name=sigul" --format "{{.Name}}" 2>/dev/null); do
            echo "--- Network: $network ---"
            docker network inspect "$network" 2>/dev/null || echo "Cannot inspect network $network"
            echo ""
        done

    } > "$OUTPUT_DIR/system/docker-state.txt"

    # Capture network connectivity state
    {
        echo "=== Network Connectivity Analysis ==="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""

        echo "=== Port Listeners ==="
        netstat -tlnp 2>/dev/null | grep -E ":44334|:44333" || echo "No sigul ports listening"
        echo ""

        echo "=== Container Network Interfaces ==="
        for container in "${CONTAINER_LIST[@]}"; do
            if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
                echo "--- Container: $container ---"
                docker exec "$container" ip addr show 2>/dev/null || echo "Cannot get network interfaces"
                echo ""
            fi
        done

    } > "$OUTPUT_DIR/system/network-analysis.txt"

    # Capture resource usage
    {
        echo "=== System Resource Usage ==="
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""

        echo "=== Container Resource Usage ==="
        docker stats --no-stream 2>/dev/null || echo "Cannot get container stats"
        echo ""

        echo "=== Host System Resources ==="
        echo "Memory:"
        free -h 2>/dev/null || echo "Cannot get memory info"
        echo ""
        echo "Disk:"
        df -h 2>/dev/null || echo "Cannot get disk info"
        echo ""
        echo "Load:"
        uptime 2>/dev/null || echo "Cannot get load info"

    } > "$OUTPUT_DIR/system/resource-usage.txt"
}

# Capture container-specific telemetry
capture_container_telemetry() {
    local container="$1"
    local container_dir="$OUTPUT_DIR/containers/$container"

    verbose "Capturing telemetry for container: $container"
    mkdir -p "$container_dir"

    # Container basic information
    {
        echo "=== Container Information ==="
        echo "Container: $container"
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""

        echo "=== Container Status ==="
        docker inspect "$container" --format '{{json .State}}' 2>/dev/null | jq . 2>/dev/null || \
            docker inspect "$container" --format '{{.State.Status}} (Exit: {{.State.ExitCode}})' 2>/dev/null || \
            echo "Cannot inspect container"
        echo ""

        echo "=== Container Configuration ==="
        docker inspect "$container" --format '{{json .Config}}' 2>/dev/null | jq . 2>/dev/null || \
            echo "Cannot get container config"
        echo ""

        echo "=== Volume Mounts ==="
        docker inspect "$container" --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}} ({{.Mode}}){{"\n"}}{{end}}' 2>/dev/null || \
            echo "Cannot get volume mounts"

    } > "$container_dir/container-info.txt"

    # Container logs with timestamps
    {
        echo "=== Container Logs (Timestamped) ==="
        echo "Container: $container"
        echo "Collection Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""

        docker logs -t "$container" 2>&1 || echo "Cannot retrieve container logs"

    } > "$container_dir/logs-timeline.txt"

    # NSS-specific telemetry
    capture_nss_telemetry "$container" "$container_dir"

    # Certificate analysis
    capture_certificate_telemetry "$container" "$container_dir"

    # Directory structure analysis
    capture_directory_telemetry "$container" "$container_dir"
}

# Capture NSS database telemetry
capture_nss_telemetry() {
    local container="$1"
    local output_dir="$2"

    verbose "Capturing NSS telemetry for $container"

    {
        echo "=== NSS Database State Analysis ==="
        echo "Container: $container"
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""

        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            echo "=== Container Running - Direct NSS Analysis ==="

            # Check NSS directories
            for role in server bridge client; do
                echo "--- NSS Directory: $role ---"
                if docker exec "$container" test -d "/var/sigul/nss/$role" 2>/dev/null; then
                    echo "Directory exists: /var/sigul/nss/$role"
                    docker exec "$container" ls -la "/var/sigul/nss/$role" 2>/dev/null || echo "Cannot list directory"

                    # Check NSS database files
                    for nss_file in cert9.db key4.db pkcs11.txt; do
                        if docker exec "$container" test -f "/var/sigul/nss/$role/$nss_file" 2>/dev/null; then
                            local file_size
                            file_size=$(docker exec "$container" stat -c%s "/var/sigul/nss/$role/$nss_file" 2>/dev/null || echo "unknown")
                            local file_perms
                            file_perms=$(docker exec "$container" stat -c%a "/var/sigul/nss/$role/$nss_file" 2>/dev/null || echo "unknown")
                            echo "  ✓ $nss_file: ${file_size} bytes, permissions: ${file_perms}"
                        else
                            echo "  ✗ $nss_file: missing"
                        fi
                    done

                    # Check NSS password file
                    local nss_pass_file="/var/sigul/secrets/${role}_nss_password"
                    if docker exec "$container" test -f "$nss_pass_file" 2>/dev/null; then
                        local pass_length
                        pass_length=$(docker exec "$container" wc -c < "$nss_pass_file" 2>/dev/null || echo "unknown")
                        echo "  NSS password file: ${pass_length} characters"
                        echo "  Password preview (first 8 chars):"
                        docker exec "$container" head -c 8 "$nss_pass_file" 2>/dev/null | hexdump -C || echo "  Cannot read password"
                    else
                        echo "  ✗ NSS password file missing: $nss_pass_file"
                    fi

                    # Attempt NSS operations
                    echo "  --- NSS Operations Test ---"
                    if docker exec "$container" test -f "$nss_pass_file" 2>/dev/null; then
                        echo "  Certificate listing:"
                        docker exec "$container" sh -c "cat '$nss_pass_file' | certutil -L -d '/var/sigul/nss/$role' -f /dev/stdin" 2>&1 | head -10 || echo "  Certificate listing failed"

                        echo "  Private key listing:"
                        docker exec "$container" sh -c "cat '$nss_pass_file' | certutil -K -d '/var/sigul/nss/$role' -f /dev/stdin" 2>&1 | head -10 || echo "  Private key listing failed"
                    else
                        echo "  Cannot perform NSS operations - password file missing"
                    fi

                else
                    echo "Directory missing: /var/sigul/nss/$role"
                fi
                echo ""
            done

        else
            echo "=== Container Not Running - Volume Analysis Required ==="

            # Attempt volume-based analysis
            local volume_name
            volume_name=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/var/sigul"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")

            if [[ -n "$volume_name" ]]; then
                echo "Container volume: $volume_name"
                echo "Attempting volume inspection via temporary container..."

                docker run --rm -v "${volume_name}:/var/sigul" alpine:3.19 sh -c '
                    echo "Volume contents:"
                    find /var/sigul -type d -name nss -exec find {} -type f \; 2>/dev/null | head -20
                    echo ""
                    echo "NSS directory structure:"
                    find /var/sigul/nss -type f -exec ls -la {} \; 2>/dev/null | head -20
                ' 2>/dev/null || echo "Volume inspection failed"
            else
                echo "Cannot determine volume name for container"
            fi
        fi

    } > "$output_dir/nss-state.txt"
}

# Capture certificate telemetry
capture_certificate_telemetry() {
    local container="$1"
    local output_dir="$2"

    verbose "Capturing certificate telemetry for $container"

    {
        echo "=== Certificate Analysis ==="
        echo "Container: $container"
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""

        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then

            echo "=== Certificate Directory Contents ==="
            docker exec "$container" find /var/sigul/secrets/certificates -type f -exec ls -la {} \; 2>/dev/null || echo "Cannot list certificate files"
            echo ""

            echo "=== NSS Certificate Details ==="
            local nss_dir="/var/sigul/nss/${container#sigul-}"
            if docker exec "$container" test -d "$nss_dir" 2>/dev/null; then
                echo "--- NSS Certificates in $nss_dir ---"
                docker exec "$container" certutil -L -d "sql:$nss_dir" 2>/dev/null | head -20 || echo "Cannot read NSS database"
                echo ""
            fi

            echo "=== Private Key Files ==="
            for key_file in ca-key.pem server-key.pem bridge-key.pem client-key.pem; do
                if docker exec "$container" test -f "/var/sigul/secrets/certificates/$key_file" 2>/dev/null; then
                    echo "--- Private Key: $key_file ---"
                    local key_size
                    key_size=$(docker exec "$container" wc -c < "/var/sigul/secrets/certificates/$key_file" 2>/dev/null || echo "unknown")
                    echo "Key file size: ${key_size} bytes"
                    echo "Key type:"
                    docker exec "$container" openssl pkey -in "/var/sigul/secrets/certificates/$key_file" -text -noout 2>/dev/null | head -5 || echo "Cannot read private key"
                    echo ""
                fi
            done

        else
            echo "Container not running - cannot perform certificate analysis"
        fi

    } > "$output_dir/cert-analysis.txt"
}

# Capture directory structure telemetry
capture_directory_telemetry() {
    local container="$1"
    local output_dir="$2"

    verbose "Capturing directory structure for $container"

    {
        echo "=== Directory Structure Analysis ==="
        echo "Container: $container"
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""

        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then

            echo "=== /var/sigul Directory Tree ==="
            docker exec "$container" find /var/sigul -type d 2>/dev/null | sort || echo "Cannot list directories"
            echo ""

            echo "=== Directory Permissions ==="
            for dir in config logs logs/server logs/bridge pids secrets nss database; do
                if docker exec "$container" test -d "/var/sigul/$dir" 2>/dev/null; then
                    local dir_perms
                    dir_perms=$(docker exec "$container" stat -c "%a %U:%G" "/var/sigul/$dir" 2>/dev/null || echo "unknown")
                    echo "/var/sigul/$dir: $dir_perms"
                fi
            done
            echo ""

            echo "=== Log Directory Analysis ==="
            if docker exec "$container" test -d "/var/sigul/logs" 2>/dev/null; then
                echo "Log directory exists"
                docker exec "$container" find /var/sigul/logs -type f -exec ls -la {} \; 2>/dev/null || echo "No log files found"

                # Check for specific log files that should exist
                for role in server bridge; do
                    if docker exec "$container" test -d "/var/sigul/logs/$role" 2>/dev/null; then
                        echo "--- $role log directory ---"
                        docker exec "$container" ls -la "/var/sigul/logs/$role" 2>/dev/null || echo "Cannot list $role log directory"

                        # Check expected log files
                        for log_file in daemon.log daemon.stdout.log startup_errors.log; do
                            if docker exec "$container" test -f "/var/sigul/logs/$role/$log_file" 2>/dev/null; then
                                local log_size
                                log_size=$(docker exec "$container" wc -c < "/var/sigul/logs/$role/$log_file" 2>/dev/null || echo "unknown")
                                echo "  ✓ $log_file: ${log_size} bytes"
                                if [[ "$log_size" != "0" && "$log_size" != "unknown" ]]; then
                                    echo "  Last few lines:"
                                    docker exec "$container" tail -5 "/var/sigul/logs/$role/$log_file" 2>/dev/null | sed 's/^/    /' || true
                                fi
                            else
                                echo "  ✗ $log_file: missing"
                            fi
                        done
                    else
                        echo "--- $role log directory: missing ---"
                    fi
                done
            else
                echo "Log directory missing: /var/sigul/logs"
            fi

        else
            echo "Container not running - cannot analyze directory structure"
        fi

    } > "$output_dir/directory-analysis.txt"
}

# Capture volume state via temporary containers
capture_volume_telemetry() {
    if [[ "$CAPTURE_VOLUMES" != "true" ]]; then
        return 0
    fi

    verbose "Capturing volume state via temporary containers"

    for container in "${CONTAINER_LIST[@]}"; do
        local volume_name
        volume_name=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/var/sigul"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")

        if [[ -n "$volume_name" ]]; then
            verbose "Capturing volume state for $container (volume: $volume_name)"

            {
                echo "=== Volume State Capture ==="
                echo "Container: $container"
                echo "Volume: $volume_name"
                echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                echo ""

                docker run --rm -v "${volume_name}:/var/sigul" alpine:3.19 sh -c '
                    echo "=== Complete Directory Structure ==="
                    find /var/sigul -type f -exec ls -la {} \; 2>/dev/null | sort
                    echo ""

                    echo "=== NSS Database Files ==="
                    find /var/sigul/nss -name "*.db" -o -name "pkcs11.txt" | while read -r file; do
                        if [ -f "$file" ]; then
                            echo "File: $file"
                            echo "Size: $(stat -c%s "$file") bytes"
                            echo "Permissions: $(stat -c%a "$file")"
                            echo "Modified: $(stat -c%y "$file")"
                            echo ""
                        fi
                    done

                    echo "=== Certificate Files ==="
                    find /var/sigul/secrets/certificates -name "*.crt" -o -name "*.pem" | while read -r file; do
                        if [ -f "$file" ]; then
                            echo "File: $file"
                            echo "Size: $(stat -c%s "$file") bytes"
                            echo "Permissions: $(stat -c%a "$file")"
                            echo ""
                        fi
                    done

                    echo "=== Log Files Content ==="
                    find /var/sigul/logs -name "*.log" -type f | while read -r file; do
                        if [ -f "$file" ] && [ -s "$file" ]; then
                            echo "--- $file ---"
                            echo "Size: $(stat -c%s "$file") bytes"
                            echo "Last 20 lines:"
                            tail -20 "$file" 2>/dev/null | sed "s/^/  /" || echo "  Cannot read log file"
                            echo ""
                        fi
                    done
                ' 2>/dev/null || echo "Volume inspection failed"

            } > "$OUTPUT_DIR/volumes/${container}-volume-state.txt"

        else
            warn "Cannot determine volume name for container: $container"
        fi
    done
}

# Analyze failures and generate reports
analyze_failures() {
    verbose "Analyzing failures and generating reports"

    # Generate failure summary
    {
        echo "# Sigul Stack Failure Analysis Report"
        echo ""
        echo "**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "**Containers Analyzed:** ${CONTAINER_LIST[*]}"
        echo ""
        echo "## Container Status Summary"
        echo ""

        for container in "${CONTAINER_LIST[@]}"; do
            echo "### $container"

            local status_info
            status_info=$(docker inspect "$container" --format '{{.State.Status}} (Exit Code: {{.State.ExitCode}})' 2>/dev/null || echo "Container not found")
            echo "- **Status:** $status_info"

            # Check for NSS integrity issues
            local container_dir="$OUTPUT_DIR/containers/$container"
            if [[ -f "$container_dir/logs-timeline.txt" ]]; then
                if grep -q "NSS deep integrity check failed" "$container_dir/logs-timeline.txt"; then
                    echo "- **Issue:** NSS deep integrity check failure detected"

                    # Extract specific error details
                    if grep -q "Missing.*private.*key" "$container_dir/logs-timeline.txt"; then
                        echo "- **Root Cause:** Missing expected private keys in NSS database"
                        grep "Missing.*private.*key" "$container_dir/logs-timeline.txt" | sed 's/^/  - /' || true
                    fi
                fi

                if grep -q "Cannot list.*logs" "$container_dir/logs-timeline.txt"; then
                    echo "- **Issue:** Log directory access problems detected"
                fi
            fi

            # Check NSS state
            if [[ -f "$container_dir/nss-state.txt" ]]; then
                local cert_count
                cert_count=$(grep -c "Certificate listing:" "$container_dir/nss-state.txt" 2>/dev/null || echo "0")
                local key_count
                key_count=$(grep -c "Private key listing:" "$container_dir/nss-state.txt" 2>/dev/null || echo "0")
                echo "- **NSS Analysis:** $cert_count certificate operations, $key_count key operations attempted"
            fi

            echo ""
        done

        echo "## Critical Issues Identified"
        echo ""

        local nss_failures=0
        local log_issues=0

        for container in "${CONTAINER_LIST[@]}"; do
            local container_dir="$OUTPUT_DIR/containers/$container"
            if [[ -f "$container_dir/logs-timeline.txt" ]]; then
                if grep -q "NSS deep integrity check failed" "$container_dir/logs-timeline.txt"; then
                    ((nss_failures++))
                fi
                if grep -q "Cannot list.*logs" "$container_dir/logs-timeline.txt"; then
                    ((log_issues++))
                fi
            fi
        done

        if [[ $nss_failures -gt 0 ]]; then
            echo "### NSS Integrity Check Failures ($nss_failures containers)"
            echo ""
            echo "**Symptoms:**"
            echo "- Containers exit with code 1 during startup"
            echo "- NSS deep integrity check fails to find expected private keys"
            echo "- Container restart loops prevent proper diagnosis"
            echo ""
            echo "**Likely Causes:**"
            echo "1. Private key import process failing during NSS database setup"
            echo "2. Incorrect private key naming conventions"
            echo "3. NSS database corruption or permission issues"
            echo "4. Certificate/key generation process problems"
            echo ""
        fi

        if [[ $log_issues -gt 0 ]]; then
            echo "### Log Directory Access Issues ($log_issues containers)"
            echo ""
            echo "**Symptoms:**"
            echo "- Cannot list /var/sigul/logs/bridge or /var/sigul/logs/server"
            echo "- Missing critical diagnostic information during failures"
            echo "- Log files not being created or accessible"
            echo ""
            echo "**Likely Causes:**"
            echo "1. Log directory not created during initialization"
            echo "2. Permission issues preventing log file creation"
            echo "3. Container exiting before logs can be written"
            echo ""
        fi

        echo "## Recommendations"
        echo ""
        echo "### Immediate Actions"
        echo "1. **Use Local Testing Environment**"
        echo "   - Run \`./local-testing/debug-nss-integrity-issue.sh --verbose --step-by-step\`"
        echo "   - This provides interactive debugging with full container access"
        echo ""
        echo "2. **Focus on NSS Database Setup**"
        echo "   - Examine private key import process in certificate management phase"
        echo "   - Verify expected private key nicknames: sigul-server-cert, sigul-bridge-cert"
        echo "   - Test manual NSS operations with same passwords and directories"
        echo ""
        echo "3. **Enhance Logging Infrastructure**"
        echo "   - Ensure log directories created early in initialization"
        echo "   - Add log directory validation before daemon startup"
        echo "   - Implement log capture even during early failure modes"
        echo ""
        echo "### Development Workflow"
        echo "1. Debug and fix issues locally using enhanced telemetry"
        echo "2. Test complete startup sequence in local environment"
        echo "3. Validate fixes with local integration tests"
        echo "4. Apply fixes to CI deployment scripts"
        echo ""
        echo "## Telemetry Files Generated"
        echo ""
        find "$OUTPUT_DIR" -type f -name "*.txt" -o -name "*.log" -o -name "*.md" | sort | while read -r file; do
            local rel_path="${file#"$OUTPUT_DIR"/}"
            echo "- \`$rel_path\`"
        done

    } > "$OUTPUT_DIR/reports/failure-summary.md"

    # Generate NSS-specific analysis
    {
        echo "# NSS Integrity Analysis Report"
        echo ""
        echo "**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "## NSS Database State Analysis"
        echo ""

        for container in "${CONTAINER_LIST[@]}"; do
            local container_dir="$OUTPUT_DIR/containers/$container"
            if [[ -f "$container_dir/nss-state.txt" ]]; then
                echo "### $container NSS Analysis"
                echo ""

                # Extract NSS operation results
                if grep -q "Certificate listing:" "$container_dir/nss-state.txt"; then
                    echo "**Certificate Operations:**"
                    grep -A10 "Certificate listing:" "$container_dir/nss-state.txt" | head -15 | sed 's/^/- /'
                    echo ""
                fi

                if grep -q "Private key listing:" "$container_dir/nss-state.txt"; then
                    echo "**Private Key Operations:**"
                    grep -A10 "Private key listing:" "$container_dir/nss-state.txt" | head -15 | sed 's/^/- /'
                    echo ""
                fi

                # Check for specific NSS files
                echo "**NSS Database Files:**"
                grep -E "cert9\.db|key4\.db|pkcs11\.txt" "$container_dir/nss-state.txt" | sed 's/^/- /' || echo "- No NSS file information found"
                echo ""
            fi
        done

    } > "$OUTPUT_DIR/reports/nss-integrity-analysis.md"

    success "Analysis reports generated in $OUTPUT_DIR/reports/"
}

# Real-time monitoring mode
start_real_time_monitoring() {
    log "Starting real-time monitoring mode"
    MONITORING_ACTIVE=true

    # Monitor in background
    (
        while [[ "$MONITORING_ACTIVE" == "true" ]]; do
            for container in "${CONTAINER_LIST[@]}"; do
                # Check if container status changed
                local current_status
                current_status=$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "missing")

                # Capture telemetry on status changes
                if [[ "$current_status" == "exited" ]] || [[ "$current_status" == "restarting" ]]; then
                    log "Container $container status: $current_status - capturing telemetry"
                    capture_container_telemetry "$container"
                fi
            done

            sleep 5
        done
    ) &

    MONITOR_PID=$!

    log "Real-time monitoring started (PID: $MONITOR_PID)"
    log "Press Ctrl+C to stop monitoring and generate final report"

    # Set up signal handler
    trap 'stop_real_time_monitoring' INT TERM

    # Wait for monitoring to complete
    wait $MONITOR_PID 2>/dev/null || true
}

# Stop real-time monitoring
stop_real_time_monitoring() {
    log "Stopping real-time monitoring"
    MONITORING_ACTIVE=false

    if [[ -n "$MONITOR_PID" ]]; then
        kill $MONITOR_PID 2>/dev/null || true
        wait $MONITOR_PID 2>/dev/null || true
    fi

    log "Real-time monitoring stopped"
}

# Main execution function
main() {
    parse_arguments "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    log "🔍 Starting Enhanced Telemetry Collection"
    log "========================================"

    # Initialize telemetry collection
    init_telemetry

    # Detect containers to monitor
    detect_sigul_containers || {
        error "No containers to monitor"
        exit 1
    }

    # Capture system-level telemetry
    capture_system_telemetry

    if [[ "$REAL_TIME_MODE" == "true" ]]; then
        # Start real-time monitoring
        start_real_time_monitoring
    else
        # One-time collection
        log "Performing one-time telemetry collection"

        for container in "${CONTAINER_LIST[@]}"; do
            capture_container_telemetry "$container"
        done

        # Capture volume state
        capture_volume_telemetry
    fi

    # Analyze failures and generate reports
    analyze_failures

    # Show summary
    echo ""
    success "🎯 Enhanced Telemetry Collection Complete!"
    log "=========================================="
    log "Output directory: $OUTPUT_DIR"
    log ""
    log "Key reports generated:"
    log "  - $OUTPUT_DIR/reports/failure-summary.md"
    log "  - $OUTPUT_DIR/reports/nss-integrity-analysis.md"
    log ""
    log "Use these reports to identify root causes and develop fixes locally"
    log "before pushing changes to CI environment."
}

# Run main function with all arguments
main "$@"
