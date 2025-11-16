#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Infrastructure Diagnostics Collection Script
#
# This script collects comprehensive diagnostic information from Sigul
# infrastructure components for troubleshooting and analysis.
#
# Usage:
#   ./scripts/collect-sigul-diagnostics.sh [OPTIONS]
#
# Options:
#   --output-dir DIR    Output directory for diagnostics (default: ./diagnostics)
#   --compress          Create compressed archive of diagnostics
#   --include-volumes   Include full volume content snapshots (large)
#   --include-secrets   Include redacted secret information (use with caution)
#   --verbose           Enable verbose output
#   --help              Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default options
OUTPUT_DIR="./diagnostics"
COMPRESS=false
INCLUDE_VOLUMES=false
INCLUDE_SECRETS=false
VERBOSE_MODE=false
SHOW_HELP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
        echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

# Help function
show_help() {
    cat << EOF
Sigul Infrastructure Diagnostics Collection Script

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --output-dir DIR    Output directory for diagnostics (default: ./diagnostics)
    --compress          Create compressed archive of diagnostics
    --include-volumes   Include full volume content snapshots (large files)
    --include-secrets   Include redacted secret information (use with caution)
    --verbose           Enable verbose output
    --help              Show this help message

DESCRIPTION:
    This script collects comprehensive diagnostic information from Sigul
    infrastructure components including:

    - Container states and logs
    - Configuration files and directory structures
    - NSS database inventories and certificate listings
    - Network connectivity and socket states
    - Volume content analysis
    - Performance and resource usage metrics
    - Error patterns and failure analysis

    The collected diagnostics can be used for:
    - Troubleshooting deployment issues
    - Analyzing container restart loops
    - Debugging certificate/NSS problems
    - Performance optimization
    - Issue reporting and support requests

EXAMPLES:
    # Basic diagnostics collection
    $0

    # Full diagnostics with volume snapshots and compression
    $0 --include-volumes --compress --verbose

    # Diagnostics for CI/CD troubleshooting
    $0 --output-dir /tmp/ci-diagnostics --compress

SECURITY NOTE:
    The --include-secrets option will include redacted versions of secret
    files for debugging purposes. Use with caution and ensure proper
    handling of the resulting diagnostic archive.

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --output-dir)
                if [[ -n "${2:-}" ]]; then
                    OUTPUT_DIR="$2"
                    shift 2
                else
                    error "Option --output-dir requires an argument"
                    exit 1
                fi
                ;;
            --compress)
                COMPRESS=true
                shift
                ;;
            --include-volumes)
                INCLUDE_VOLUMES=true
                shift
                ;;
            --include-secrets)
                INCLUDE_SECRETS=true
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
                echo
                show_help
                exit 1
                ;;
        esac
    done
}

# Create output directory structure
setup_output_directory() {
    log "Setting up diagnostics output directory: $OUTPUT_DIR"

    # Create main output directory
    mkdir -p "$OUTPUT_DIR"

    # Create subdirectories for organized diagnostics
    mkdir -p "$OUTPUT_DIR"/{containers,volumes,configs,logs,network,nss,certificates,system,analysis}

    # Create timestamp file
    date '+%Y-%m-%d %H:%M:%S %Z' > "$OUTPUT_DIR/collection-timestamp.txt"

    # Create collection metadata
    cat > "$OUTPUT_DIR/collection-metadata.txt" << EOF
Sigul Diagnostics Collection Metadata
=====================================

Collection Time: $(date '+%Y-%m-%d %H:%M:%S %Z')
Script Version: $(grep "# SPDX-FileCopyrightText" "$0" | head -1 || echo "Unknown")
Project Root: $PROJECT_ROOT
Output Directory: $OUTPUT_DIR
Compress Output: $COMPRESS
Include Volumes: $INCLUDE_VOLUMES
Include Secrets: $INCLUDE_SECRETS

System Information:
- Hostname: $(hostname)
- Kernel: $(uname -a)
- Docker Version: $(docker --version 2>/dev/null || echo "Not available")
- Docker Compose Version: $(docker compose version --short 2>/dev/null || docker-compose version --short 2>/dev/null || echo "Not available")

EOF

    verbose "Output directory structure created"
}

# Collect container information
collect_container_info() {
    log "Collecting container information..."

    local containers_dir="$OUTPUT_DIR/containers"

    # List all containers
    docker ps -a > "$containers_dir/docker-ps-all.txt" 2>&1 || true
    docker ps > "$containers_dir/docker-ps-running.txt" 2>&1 || true

    # Collect information for each Sigul container
    for container in sigul-server sigul-bridge sigul-client-test sigul-client-integration; do
        if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            verbose "Collecting info for container: $container"

            # Container inspect
            docker inspect "$container" > "$containers_dir/${container}.inspect.json" 2>&1 || true

            # Container logs
            docker logs "$container" > "$containers_dir/${container}.log" 2>&1 || true
            docker logs --tail 100 "$container" > "$containers_dir/${container}.recent.log" 2>&1 || true

            # Container stats (if running)
            if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
                timeout 5s docker stats --no-stream "$container" > "$containers_dir/${container}.stats.txt" 2>&1 || true

                # Process information inside container
                docker exec "$container" ps auxf > "$containers_dir/${container}.processes.txt" 2>/dev/null || true

                # Network information inside container
                docker exec "$container" ss -tlpn > "$containers_dir/${container}.sockets.txt" 2>/dev/null || true
                docker exec "$container" netstat -tulpn > "$containers_dir/${container}.netstat.txt" 2>/dev/null || true

                # Disk usage inside container
                docker exec "$container" df -h > "$containers_dir/${container}.diskusage.txt" 2>/dev/null || true

                # Environment variables (filtered)
                docker exec "$container" env | grep -E '^(SIGUL|NSS|DEBUG|PATH)' > "$containers_dir/${container}.env.txt" 2>/dev/null || true
            fi
        else
            verbose "Container not found: $container"
            echo "Container $container not found" > "$containers_dir/${container}.not-found.txt"
        fi
    done

    # Container restart counts and exit codes
    {
        echo "Container Restart Analysis"
        echo "========================="
        for container in sigul-server sigul-bridge sigul-client-test; do
            if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
                echo ""
                echo "Container: $container"
                echo "Status: $(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo 'unknown')"
                echo "Exit Code: $(docker inspect --format='{{.State.ExitCode}}' "$container" 2>/dev/null || echo 'unknown')"
                echo "Restart Count: $(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo 'unknown')"
                echo "Started At: $(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null || echo 'unknown')"
                echo "Finished At: $(docker inspect --format='{{.State.FinishedAt}}' "$container" 2>/dev/null || echo 'unknown')"
            fi
        done
    } > "$containers_dir/restart-analysis.txt"

    verbose "Container information collected"
}

# Collect volume information
collect_volume_info() {
    log "Collecting volume information..."

    local volumes_dir="$OUTPUT_DIR/volumes"

    # List all volumes
    docker volume ls > "$volumes_dir/docker-volumes.txt" 2>&1 || true

    # Find Sigul-related volumes
    local sigul_volumes=()
    while IFS= read -r volume_name; do
        if [[ "$volume_name" =~ sigul ]]; then
            sigul_volumes+=("$volume_name")
        fi
    done < <(docker volume ls --format "{{.Name}}" 2>/dev/null | grep sigul || true)

    verbose "Found ${#sigul_volumes[@]} Sigul-related volumes"

    # Collect information for each Sigul volume
    for volume in "${sigul_volumes[@]}"; do
        verbose "Collecting info for volume: $volume"

        # Volume inspect
        docker volume inspect "$volume" > "$volumes_dir/${volume}.inspect.json" 2>&1 || true

        # Volume directory listing
        docker run --rm -v "${volume}":/volume_data alpine:3.19 sh -c '
            echo "=== Volume Directory Structure ==="
            find /volume_data -type f -exec ls -la {} \; 2>/dev/null || true
            echo ""
            echo "=== Volume Directory Tree ==="
            find /volume_data -type d 2>/dev/null | sort || true
            echo ""
            echo "=== Volume File Sizes ==="
            find /volume_data -type f -exec du -h {} \; 2>/dev/null | sort -hr | head -20 || true
        ' > "$volumes_dir/${volume}.listing.txt" 2>&1 || true

        # Volume content snapshot (if requested)
        if [[ "$INCLUDE_VOLUMES" == "true" ]]; then
            verbose "Creating volume content snapshot for: $volume"
            docker run --rm -v "${volume}":/volume_data alpine:3.19 tar -czf - -C /volume_data . > "$volumes_dir/${volume}.content.tar.gz" 2>/dev/null || true
        fi
    done

    # Dynamic volume name resolution for containers
    for container in sigul-server sigul-bridge sigul-client-test; do
        if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            local container_volume
            container_volume=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/var/sigul"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")
            if [[ -n "$container_volume" ]]; then
                echo "$container -> $container_volume" >> "$volumes_dir/container-volume-mapping.txt"
            fi
        fi
    done

    verbose "Volume information collected"
}

# Collect configuration information
collect_config_info() {
    log "Collecting configuration information..."

    local configs_dir="$OUTPUT_DIR/configs"

    # Copy configuration files (if they exist)
    local config_files=(
        "configs/server.conf"
        "configs/bridge.conf"
        "configs/client.conf"
        "docker-compose.sigul.yml"
    )

    for config_file in "${config_files[@]}"; do
        local source_file="$PROJECT_ROOT/$config_file"
        if [[ -f "$source_file" ]]; then
            verbose "Copying config file: $config_file"
            cp "$source_file" "$configs_dir/$(basename "$config_file")" 2>/dev/null || true

            # Create redacted version (remove passwords)
            if [[ "$INCLUDE_SECRETS" == "false" ]]; then
                sed 's/password[[:space:]]*=.*/password = [REDACTED]/gi' "$source_file" > "$configs_dir/$(basename "$config_file").redacted" 2>/dev/null || true
            fi
        else
            echo "Config file not found: $config_file" > "$configs_dir/$(basename "$config_file").not-found.txt"
        fi
    done

    # Collect configuration from containers
    for container in sigul-server sigul-bridge sigul-client-test; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            verbose "Collecting config from container: $container"

            # Configuration files from container
            docker exec "$container" find /var/sigul/config -type f -name "*.conf" -exec cat {} \; > "$configs_dir/${container}.config.txt" 2>/dev/null || true

            # Configuration directory listing
            docker exec "$container" ls -la /var/sigul/config/ > "$configs_dir/${container}.config-listing.txt" 2>/dev/null || true
        fi
    done

    verbose "Configuration information collected"
}

# Collect NSS database information
collect_nss_info() {
    log "Collecting NSS database information..."

    local nss_dir="$OUTPUT_DIR/nss"

    # Collect NSS information from each container
    for container in sigul-server sigul-bridge sigul-client-test; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            verbose "Collecting NSS info from container: $container"

            # NSS directory listing
            docker exec "$container" find /var/sigul/nss -type f -exec ls -la {} \; > "$nss_dir/${container}.nss-files.txt" 2>/dev/null || true

            # Certificate listings for each role
            for role in server bridge client; do
                local nss_db_dir="/var/sigul/nss/$role"

                {
                    echo "=== NSS Database Listing for $role in $container ==="

                    # Check if NSS database exists
                    docker exec "$container" test -d "$nss_db_dir" 2>/dev/null && echo "NSS directory exists: $nss_db_dir" || echo "NSS directory missing: $nss_db_dir"

                    # List certificates (without password for security)
                    echo ""
                    echo "Certificate listing (may require password):"
                    docker exec "$container" certutil -L -d "$nss_db_dir" 2>/dev/null || echo "Failed to list certificates (password required or DB corrupted)"

                    echo ""
                    echo "NSS database files:"
                    docker exec "$container" ls -la "$nss_db_dir" 2>/dev/null || echo "Failed to list NSS database files"

                } > "$nss_dir/${container}.${role}.nss.txt" 2>&1 || true
            done
        fi
    done

    verbose "NSS database information collected"
}

# Collect certificate information
collect_certificate_info() {
    log "Collecting certificate information..."

    local certs_dir="$OUTPUT_DIR/certificates"

    # Copy PKI files from project
    if [[ -d "$PROJECT_ROOT/pki" ]]; then
        verbose "Copying PKI directory"
        cp -r "$PROJECT_ROOT/pki" "$certs_dir/project-pki" 2>/dev/null || true
    fi

    # Collect certificates from containers
    for container in sigul-server sigul-bridge sigul-client-test; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            verbose "Collecting certificates from container: $container"

            # Certificate directory listing
            docker exec "$container" find /var/sigul/secrets/certificates -type f -exec ls -la {} \; > "$certs_dir/${container}.cert-files.txt" 2>/dev/null || true

            # NSS Certificate analysis from container
            {
                echo "=== Container NSS Certificate Analysis for $container ==="
                local component_name
                component_name=${container#sigul-}
                local nss_db_path="/var/sigul/nss/$component_name"
                docker exec "$container" sh -c "
                    if [ -d '$nss_db_path' ]; then
                        echo ''
                        echo 'NSS Database: $nss_db_path'
                        echo 'Database files:'
                        ls -la '$nss_db_path/'
                        echo ''
                        echo 'Certificates in database:'
                        certutil -L -d 'sql:$nss_db_path' 2>/dev/null || echo 'Cannot read NSS database'
                    else
                        echo 'NSS database not found: $nss_db_path'
                    fi
                " 2>/dev/null || echo "Cannot access NSS database in container"
            } > "$certs_dir/${container}.cert-analysis.txt" 2>&1 || true
        fi
    done

    verbose "Certificate information collected"
}

# Collect network information
collect_network_info() {
    log "Collecting network information..."

    local network_dir="$OUTPUT_DIR/network"

    # Docker network information
    docker network ls > "$network_dir/docker-networks.txt" 2>&1 || true

    # Sigul network details
    local sigul_network
    sigul_network=$(docker network ls --filter "name=sigul" --format "{{.Name}}" | head -1 || echo "")

    if [[ -n "$sigul_network" ]]; then
        verbose "Collecting Sigul network info: $sigul_network"
        docker network inspect "$sigul_network" > "$network_dir/sigul-network.inspect.json" 2>&1 || true
    fi

    # Port connectivity tests
    {
        echo "=== Port Connectivity Tests ==="
        echo "Testing from host system:"

        # Test bridge port
        if nc -z localhost 44334 2>/dev/null; then
            echo "✅ Port 44334 (bridge) is accessible from host"
        else
            echo "❌ Port 44334 (bridge) is NOT accessible from host"
        fi

        echo ""
        echo "Testing from containers:"

        # Test connectivity between containers
        if docker ps --format "{{.Names}}" | grep -q "^sigul-bridge$"; then
            echo "Bridge container network tests:"
            docker exec sigul-bridge ss -tlpn 2>/dev/null || echo "Failed to get socket info from bridge"

            if docker exec sigul-bridge nc -z sigul-bridge 44334 2>/dev/null; then
                echo "✅ Bridge can connect to itself on port 44334"
            else
                echo "❌ Bridge cannot connect to itself on port 44334"
            fi
        fi

        if docker ps --format "{{.Names}}" | grep -q "^sigul-server$"; then
            echo "Server container network tests:"
            if docker exec sigul-server nc -z sigul-bridge 44334 2>/dev/null; then
                echo "✅ Server can connect to bridge on port 44334"
            else
                echo "❌ Server cannot connect to bridge on port 44334"
            fi
        fi

    } > "$network_dir/connectivity-tests.txt" 2>&1

    # Network statistics from containers
    for container in sigul-server sigul-bridge sigul-client-test; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            verbose "Collecting network stats from container: $container"

            {
                echo "=== Network Statistics for $container ==="
                echo "Interface information:"
                docker exec "$container" ip addr show 2>/dev/null || echo "Failed to get interface info"
                echo ""
                echo "Routing table:"
                docker exec "$container" ip route show 2>/dev/null || echo "Failed to get routing info"
                echo ""
                echo "Active connections:"
                docker exec "$container" ss -tuln 2>/dev/null || docker exec "$container" netstat -tuln 2>/dev/null || echo "Failed to get connection info"
            } > "$network_dir/${container}.network-stats.txt" 2>&1 || true
        fi
    done

    verbose "Network information collected"
}

# Collect system information
collect_system_info() {
    log "Collecting system information..."

    local system_dir="$OUTPUT_DIR/system"

    # Host system information
    {
        echo "=== Host System Information ==="
        echo "Hostname: $(hostname)"
        echo "Kernel: $(uname -a)"
        echo "OS Release:"
        cat /etc/os-release 2>/dev/null || echo "OS release info not available"
        echo ""
        echo "CPU Information:"
        lscpu 2>/dev/null | head -20 || echo "CPU info not available"
        echo ""
        echo "Memory Information:"
        free -h 2>/dev/null || echo "Memory info not available"
        echo ""
        echo "Disk Usage:"
        df -h 2>/dev/null || echo "Disk info not available"
        echo ""
        echo "Docker Information:"
        docker info 2>/dev/null | head -30 || echo "Docker info not available"
    } > "$system_dir/host-system.txt" 2>&1

    # Docker resource usage
    {
        echo "=== Docker Resource Usage ==="
        echo "Docker system df:"
        docker system df 2>/dev/null || echo "Docker system df not available"
        echo ""
        echo "Container resource usage:"
        timeout 10s docker stats --no-stream --all 2>/dev/null || echo "Container stats not available"
    } > "$system_dir/docker-resources.txt" 2>&1

    # Process information
    {
        echo "=== Process Information ==="
        echo "Docker-related processes:"
        pgrep -f "(docker|sigul)" >/dev/null && pgrep -af "(docker|sigul)" || echo "No docker-related processes found"
    } > "$system_dir/processes.txt" 2>&1

    verbose "System information collected"
}

# Collect logs and perform analysis
collect_logs_and_analysis() {
    log "Collecting logs and performing analysis..."

    local logs_dir="$OUTPUT_DIR/logs"
    local analysis_dir="$OUTPUT_DIR/analysis"

    # Copy project logs if they exist
    if [[ -d "$PROJECT_ROOT/logs" ]]; then
        cp -r "$PROJECT_ROOT/logs" "$logs_dir/project-logs" 2>/dev/null || true
    fi

    # Collect container logs with timestamps
    for container in sigul-server sigul-bridge sigul-client-test; do
        if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            verbose "Collecting timestamped logs from container: $container"
            docker logs -t "$container" > "$logs_dir/${container}.timestamped.log" 2>&1 || true
        fi
    done

    # Log analysis - common error patterns
    {
        echo "=== Common Error Pattern Analysis ==="
        echo "Analyzing container logs for common error patterns..."
        echo ""

        # Collect all container logs for analysis
        local all_logs_file="$analysis_dir/all-container-logs.txt"
        true > "$all_logs_file"

        for container in sigul-server sigul-bridge sigul-client-test; do
            if [[ -f "$OUTPUT_DIR/containers/${container}.log" ]]; then
                echo "=== Logs from $container ===" >> "$all_logs_file"
                cat "$OUTPUT_DIR/containers/${container}.log" >> "$all_logs_file" 2>/dev/null || true
                echo "" >> "$all_logs_file"
            fi
        done

        if [[ -f "$all_logs_file" && -s "$all_logs_file" ]]; then
            echo "Most common error patterns:"
            grep -i -E "(error|fail|exception|crash|abort)" "$all_logs_file" | sed 's/^.*: //' | sort | uniq -c | sort -nr | head -10 || echo "No error patterns found"

            echo ""
            echo "Certificate/NSS related issues:"
            grep -i -E "(certificate|nss|ssl|tls)" "$all_logs_file" | grep -i -E "(error|fail|invalid)" | head -10 || echo "No cert/NSS issues found"

            echo ""
            echo "Permission related issues:"
            grep -i -E "(permission|denied|access)" "$all_logs_file" | head -10 || echo "No permission issues found"

            echo ""
            echo "Network related issues:"
            grep -i -E "(connect|bind|socket|network|port)" "$all_logs_file" | grep -i -E "(error|fail|refused)" | head -10 || echo "No network issues found"
        else
            echo "No container logs available for analysis"
        fi

    } > "$analysis_dir/error-pattern-analysis.txt" 2>&1

    # Container restart analysis
    {
        echo "=== Container Restart Analysis ==="

        for container in sigul-server sigul-bridge sigul-client-test; do
            if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
                echo ""
                echo "Container: $container"

                local restart_count
                restart_count=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "unknown")

                if [[ "$restart_count" != "0" && "$restart_count" != "unknown" ]]; then
                    echo "⚠️  Restart count: $restart_count"
                    echo "Last exit code: $(docker inspect --format='{{.State.ExitCode}}' "$container" 2>/dev/null || echo "unknown")"
                    echo "Current status: $(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")"

                    # Try to find restart patterns in logs
                    if [[ -f "$OUTPUT_DIR/containers/${container}.log" ]]; then
                        echo "Recent restart-related log entries:"
                        grep -i -E "(restart|exit|start|init)" "$OUTPUT_DIR/containers/${container}.log" | tail -5 || echo "No restart-related entries found"
                    fi
                else
                    echo "✅ No restarts detected"
                fi
            fi
        done

    } > "$analysis_dir/restart-analysis.txt" 2>&1

    verbose "Logs and analysis collected"
}

# Create summary report
create_summary_report() {
    log "Creating summary report..."

    local summary_file="$OUTPUT_DIR/SUMMARY.md"

    cat > "$summary_file" << EOF
# Sigul Infrastructure Diagnostics Summary

**Collection Time:** $(cat "$OUTPUT_DIR/collection-timestamp.txt")
**Collection Script:** $0

## Quick Status Overview

### Containers
EOF

    # Container status summary
    for container in sigul-server sigul-bridge sigul-client-test; do
        if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            local status
            status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
            local restart_count
            restart_count=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "unknown")

            if [[ "$status" == "running" && "$restart_count" == "0" ]]; then
                echo "- ✅ **$container**: Running (no restarts)" >> "$summary_file"
            elif [[ "$status" == "running" ]]; then
                echo "- ⚠️  **$container**: Running (restarts: $restart_count)" >> "$summary_file"
            elif [[ "$status" == "restarting" ]]; then
                echo "- 🔄 **$container**: Restarting (restarts: $restart_count)" >> "$summary_file"
            else
                echo "- ❌ **$container**: $status (restarts: $restart_count)" >> "$summary_file"
            fi
        else
            echo "- ❓ **$container**: Not found" >> "$summary_file"
        fi
    done

    cat >> "$summary_file" << EOF

### Network Connectivity
EOF

    # Network status summary
    if nc -z localhost 44334 2>/dev/null; then
        echo "- ✅ **Bridge Port 44334**: Accessible from host" >> "$summary_file"
    else
        echo "- ❌ **Bridge Port 44334**: Not accessible from host" >> "$summary_file"
    fi

    cat >> "$summary_file" << EOF

### Volume Status
EOF

    # Volume status summary
    local volume_count
    volume_count=$(docker volume ls --format "{{.Name}}" | grep -c sigul 2>/dev/null || echo "0")
    echo "- **Sigul Volumes Found**: $volume_count" >> "$summary_file"

    cat >> "$summary_file" << EOF

## Diagnostic Files Structure

\`\`\`
$OUTPUT_DIR/
├── containers/          # Container logs, stats, and inspection data
├── volumes/            # Volume information and content snapshots
├── configs/            # Configuration files (redacted)
├── logs/              # Timestamped logs and log analysis
├── network/           # Network connectivity and statistics
├── nss/               # NSS database information
├── certificates/      # Certificate analysis and PKI data
├── system/           # Host system and Docker resource information
├── analysis/         # Error patterns and failure analysis
└── SUMMARY.md        # This summary report
\`\`\`

## Key Files to Check

1. **Container Issues**: \`containers/*.inspect.json\` and \`containers/*.log\`
2. **Network Problems**: \`network/connectivity-tests.txt\`
3. **Certificate Issues**: \`certificates/certificate-analysis.txt\`
4. **Error Patterns**: \`analysis/error-pattern-analysis.txt\`
5. **Restart Problems**: \`analysis/restart-analysis.txt\`

## Quick Troubleshooting Commands

\`\`\`bash
# View container status
docker ps -a --filter "name=sigul"

# Check recent container logs
docker logs --tail 50 sigul-bridge

# Test bridge connectivity
nc -z localhost 44334

# Check volume mappings
docker inspect sigul-bridge --format '{{range .Mounts}}{{if eq .Destination "/var/sigul"}}{{.Name}}{{end}}{{end}}'
\`\`\`

## Next Steps

Based on the diagnostic results, consider:

1. Reviewing container restart counts and exit codes
2. Checking network connectivity between components
3. Validating certificate and NSS database integrity
4. Analyzing error patterns for root cause identification
5. Verifying volume mounts and permissions

For detailed analysis, examine the specific diagnostic files mentioned above.

EOF

    success "Summary report created: $summary_file"
}

# Compress diagnostics if requested
compress_diagnostics() {
    if [[ "$COMPRESS" == "true" ]]; then
        log "Compressing diagnostics archive..."

        local archive_name
        local archive_path
        archive_name="sigul-diagnostics-$(date +%Y%m%d-%H%M%S).tar.gz"
        archive_path="$(dirname "$OUTPUT_DIR")/$archive_name"

        if tar -czf "$archive_path" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"; then
            success "Diagnostics compressed to: $archive_path"

            # Show archive size
            local archive_size
            archive_size=$(du -h "$archive_path" | cut -f1)
            log "Archive size: $archive_size"

            # Optionally remove uncompressed directory
            read -p "Remove uncompressed diagnostics directory? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf "$OUTPUT_DIR"
                log "Uncompressed directory removed"
            fi
        else
            error "Failed to compress diagnostics"
            return 1
        fi
    fi
}

# Main function
main() {
    parse_args "$@"

    if [[ "${SHOW_HELP}" == "true" ]]; then
        show_help
        exit 0
    fi

    log "Starting Sigul infrastructure diagnostics collection..."
    log "Output directory: $OUTPUT_DIR"
    log "Include volumes: $INCLUDE_VOLUMES"
    log "Include secrets: $INCLUDE_SECRETS"
    log "Compress output: $COMPRESS"

    # Setup output directory
    setup_output_directory

    # Collect all diagnostic information
    collect_container_info
    collect_volume_info
    collect_config_info
    collect_nss_info
    collect_certificate_info
    collect_network_info
    collect_system_info
    collect_logs_and_analysis

    # Create summary report
    create_summary_report

    # Compress if requested
    compress_diagnostics

    success "Diagnostics collection completed!"

    if [[ "$COMPRESS" == "false" ]]; then
        log "Diagnostics available in: $OUTPUT_DIR"
        log "Summary report: $OUTPUT_DIR/SUMMARY.md"
    fi

    log "Use the collected diagnostics for troubleshooting and issue reporting"
}

# Execute main function with all arguments
main "$@"
