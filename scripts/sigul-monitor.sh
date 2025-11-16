#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Lightweight Passive Monitor (Sidecar v2)
#
# This script runs as a sidecar container to monitor Sigul infrastructure
# components and emit JSON heartbeats for observability and diagnostics.
#
# Usage:
#   ./sigul-monitor.sh --target <bridge|server> [OPTIONS]
#
# Environment Variables:
#   MONITOR_TARGET         - Component to monitor (bridge|server)
#   MONITOR_INTERVAL       - Heartbeat interval in seconds (default: 30)
#   MONITOR_OUTPUT_DIR     - Directory for heartbeat files (default: /monitor/heartbeats)
#   SIGUL_CONTAINER_NAME   - Name of container to monitor (auto-detected)
#   DEBUG                  - Enable debug logging (default: false)

set -euo pipefail

# Script configuration
readonly SCRIPT_NAME
SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"

# Default configuration
MONITOR_TARGET="${MONITOR_TARGET:-}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-30}"
MONITOR_OUTPUT_DIR="${MONITOR_OUTPUT_DIR:-/monitor/heartbeats}"
SIGUL_CONTAINER_NAME="${SIGUL_CONTAINER_NAME:-}"
DEBUG="${DEBUG:-false}"

# Runtime state
MONITOR_START_TIME=""
HEARTBEAT_COUNT=0
LAST_PID=""
RESTART_COUNT=0

# Colors for output
RED='\033[0;31m'
# GREEN='\033[0;32m' - removed unused variable
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

debug() {
    if [[ "${DEBUG}" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

# Show help message
show_help() {
    cat << EOF
Sigul Lightweight Passive Monitor (Sidecar v2)

USAGE:
    $SCRIPT_NAME --target <bridge|server> [OPTIONS]

OPTIONS:
    --target TARGET         Component to monitor (bridge|server)
    --interval SECONDS      Heartbeat interval (default: 30)
    --output-dir DIR        Output directory for heartbeats (default: /monitor/heartbeats)
    --container-name NAME   Container name to monitor (auto-detected if not specified)
    --debug                 Enable debug logging
    --help                  Show this help message

DESCRIPTION:
    This monitor runs as a passive sidecar container that observes Sigul
    infrastructure components and emits JSON heartbeats every N seconds.

    Heartbeat files are named: {target}-YYYYMMDD_HHMM.json
    Each heartbeat contains:
    - Timestamp and sequence information
    - Container status and restart counts
    - Process information (PID stability, memory usage)
    - Resource metrics (open file descriptors, RSS memory)
    - Network connectivity status

EXAMPLES:
    # Monitor bridge component with default settings
    $SCRIPT_NAME --target bridge

    # Monitor server with custom interval
    $SCRIPT_NAME --target server --interval 60

    # Monitor with debug logging
    $SCRIPT_NAME --target bridge --debug

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --target)
                MONITOR_TARGET="$2"
                shift 2
                ;;
            --interval)
                MONITOR_INTERVAL="$2"
                shift 2
                ;;
            --output-dir)
                MONITOR_OUTPUT_DIR="$2"
                shift 2
                ;;
            --container-name)
                SIGUL_CONTAINER_NAME="$2"
                shift 2
                ;;
            --debug)
                DEBUG="true"
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo
                show_help
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$MONITOR_TARGET" ]]; then
        error "Target component must be specified with --target"
        echo
        show_help
        exit 1
    fi

    if [[ "$MONITOR_TARGET" != "bridge" && "$MONITOR_TARGET" != "server" ]]; then
        error "Target must be 'bridge' or 'server', got: $MONITOR_TARGET"
        exit 1
    fi

    # Validate interval
    if ! [[ "$MONITOR_INTERVAL" =~ ^[0-9]+$ ]] || (( MONITOR_INTERVAL < 5 )); then
        error "Interval must be a number >= 5 seconds, got: $MONITOR_INTERVAL"
        exit 1
    fi

    # Auto-detect container name if not provided
    if [[ -z "$SIGUL_CONTAINER_NAME" ]]; then
        SIGUL_CONTAINER_NAME="sigul-${MONITOR_TARGET}"
        debug "Auto-detected container name: $SIGUL_CONTAINER_NAME"
    fi
}

# Initialize monitoring environment
initialize_monitor() {
    log "Initializing Sigul monitor v$VERSION"
    log "Target: $MONITOR_TARGET"
    log "Container: $SIGUL_CONTAINER_NAME"
    log "Interval: ${MONITOR_INTERVAL}s"
    log "Output: $MONITOR_OUTPUT_DIR"

    # Create output directory
    mkdir -p "$MONITOR_OUTPUT_DIR"
    if [[ ! -d "$MONITOR_OUTPUT_DIR" ]]; then
        error "Failed to create output directory: $MONITOR_OUTPUT_DIR"
        exit 1
    fi

    # Test write permissions
    local test_file="$MONITOR_OUTPUT_DIR/.monitor-test"
    if ! touch "$test_file" 2>/dev/null; then
        error "Cannot write to output directory: $MONITOR_OUTPUT_DIR"
        exit 1
    fi
    rm -f "$test_file"

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required but not installed"
        exit 1
    fi

    # Record start time
    MONITOR_START_TIME=$(date +%s)

    log "Monitor initialization complete"
}

# Collect container metrics
collect_container_metrics() {
    local metrics='{}'

    # Container status and basic info
    local container_status container_restart_count container_exit_code
    container_status=$(docker container inspect "$SIGUL_CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "not_found")
    container_restart_count=$(docker container inspect "$SIGUL_CONTAINER_NAME" --format '{{.RestartCount}}' 2>/dev/null || echo "0")
    container_exit_code=$(docker container inspect "$SIGUL_CONTAINER_NAME" --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")

    metrics=$(echo "$metrics" | jq --arg status "$container_status" \
        --argjson restart_count "$container_restart_count" \
        --arg exit_code "$container_exit_code" \
        '.container = {
            "status": $status,
            "restartCount": $restart_count,
            "exitCode": $exit_code
        }')

    # Process information (if container is running)
    if [[ "$container_status" == "running" ]]; then
        local process_info
        process_info=$(collect_process_info)
        metrics=$(echo "$metrics" | jq --argjson process "$process_info" '.process = $process')

        # Resource metrics
        local resource_info
        resource_info=$(collect_resource_info)
        metrics=$(echo "$metrics" | jq --argjson resources "$resource_info" '.resources = $resources')

        # Network connectivity
        local network_info
        network_info=$(collect_network_info)
        metrics=$(echo "$metrics" | jq --argjson network "$network_info" '.network = $network')
    else
        metrics=$(echo "$metrics" | jq '.process = null | .resources = null | .network = null')
    fi

    echo "$metrics"
}

# Collect process information
collect_process_info() {
    local process_info='{}'

    # Find the main sigul process
    local sigul_process_name
    case "$MONITOR_TARGET" in
        "bridge")
            sigul_process_name="sigul_bridge"
            ;;
        "server")
            sigul_process_name="sigul_server"
            ;;
    esac

    local current_pid
    if current_pid=$(docker exec "$SIGUL_CONTAINER_NAME" pgrep -f "$sigul_process_name" 2>/dev/null | head -1); then
        process_info=$(echo "$process_info" | jq --arg pid "$current_pid" '.pid = $pid')

        # Check for PID stability
        local pid_stable="false"
        if [[ "$current_pid" == "$LAST_PID" ]]; then
            pid_stable="true"
        elif [[ -n "$LAST_PID" && "$current_pid" != "$LAST_PID" ]]; then
            # PID changed - indicates process restart
            ((RESTART_COUNT++))
            debug "Process restart detected: PID changed from $LAST_PID to $current_pid"
        fi

        process_info=$(echo "$process_info" | jq --argjson stable "$pid_stable" \
            --argjson restart_count "$RESTART_COUNT" \
            '.stable = $stable | .restartCount = $restart_count')

        LAST_PID="$current_pid"

        # Get process start time
        local process_start_time
        if process_start_time=$(docker exec "$SIGUL_CONTAINER_NAME" stat -c %Y "/proc/$current_pid" 2>/dev/null); then
            process_info=$(echo "$process_info" | jq --argjson start_time "$process_start_time" '.startTime = $start_time')
        fi

    else
        process_info=$(echo "$process_info" | jq '.pid = null | .stable = false')
        LAST_PID=""
    fi

    echo "$process_info"
}

# Collect resource information
collect_resource_info() {
    local resource_info='{}'

    if [[ -n "$LAST_PID" ]]; then
        # Memory usage (RSS)
        local rss_kb
        if rss_kb=$(docker exec "$SIGUL_CONTAINER_NAME" awk '/^VmRSS:/ {print $2}' "/proc/$LAST_PID/status" 2>/dev/null); then
            resource_info=$(echo "$resource_info" | jq --argjson rss "$rss_kb" '.rssKB = $rss')
        fi

        # Open file descriptors
        local open_fds
        if open_fds=$(docker exec "$SIGUL_CONTAINER_NAME" ls "/proc/$LAST_PID/fd" 2>/dev/null | wc -l); then
            resource_info=$(echo "$resource_info" | jq --argjson fds "$open_fds" '.openFDs = $fds')
        fi

        # CPU time
        local cpu_time
        if cpu_time=$(docker exec "$SIGUL_CONTAINER_NAME" awk '{print $14+$15}' "/proc/$LAST_PID/stat" 2>/dev/null); then
            resource_info=$(echo "$resource_info" | jq --argjson cpu "$cpu_time" '.cpuTime = $cpu')
        fi
    fi

    echo "$resource_info"
}

# Collect network connectivity information
collect_network_info() {
    local network_info='{}'

    case "$MONITOR_TARGET" in
        "bridge")
            # Check if bridge is listening on port 44334
            local listening_44334="false"
            if docker exec "$SIGUL_CONTAINER_NAME" ss -tlnp 2>/dev/null | grep -q ":44334"; then
                listening_44334="true"
            fi
            network_info=$(echo "$network_info" | jq --argjson listening "$listening_44334" '.listening44334 = $listening')

            # Test external connectivity
            local external_reachable="false"
            if nc -z localhost 44334 2>/dev/null; then
                external_reachable="true"
            fi
            network_info=$(echo "$network_info" | jq --argjson reachable "$external_reachable" '.externalReachable = $reachable')
            ;;

        "server")
            # Server doesn't expose external ports, check internal connectivity to bridge
            local bridge_reachable="false"
            if docker exec "$SIGUL_CONTAINER_NAME" nc -z sigul-bridge 44334 2>/dev/null; then
                bridge_reachable="true"
            fi
            network_info=$(echo "$network_info" | jq --argjson reachable "$bridge_reachable" '.bridgeReachable = $reachable')
            ;;
    esac

    echo "$network_info"
}

# Generate heartbeat filename
get_heartbeat_filename() {
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M')
    echo "$MONITOR_OUTPUT_DIR/${MONITOR_TARGET}-${timestamp}.json"
}

# Emit heartbeat JSON
emit_heartbeat() {
    ((HEARTBEAT_COUNT++))

    local heartbeat_file
    heartbeat_file=$(get_heartbeat_filename)

    debug "Emitting heartbeat #$HEARTBEAT_COUNT to: $heartbeat_file"

    # Collect all metrics
    local metrics
    metrics=$(collect_container_metrics)

    # Calculate uptime
    local current_time uptime
    current_time=$(date +%s)
    uptime=$((current_time - MONITOR_START_TIME))

    # Generate heartbeat JSON
    local heartbeat
    heartbeat=$(jq -n \
        --arg target "$MONITOR_TARGET" \
        --arg container_name "$SIGUL_CONTAINER_NAME" \
        --argjson sequence "$HEARTBEAT_COUNT" \
        --argjson uptime "$uptime" \
        --argjson metrics "$metrics" \
        '{
            "monitor": {
                "target": $target,
                "containerName": $container_name,
                "version": "'$VERSION'",
                "sequence": $sequence,
                "uptime": $uptime,
                "timestamp": (now | todate)
            },
            "metrics": $metrics
        }')

    # Write heartbeat file
    echo "$heartbeat" > "$heartbeat_file"
    chmod 644 "$heartbeat_file" 2>/dev/null || true

    # Log heartbeat summary
    local container_status
    container_status=$(echo "$metrics" | jq -r '.container.status // "unknown"')
    log "Heartbeat #$HEARTBEAT_COUNT: $MONITOR_TARGET ($container_status) - uptime ${uptime}s"
}

# Cleanup old heartbeat files
cleanup_old_heartbeats() {
    # Keep only the last 24 hours of heartbeats (based on 30s interval = ~2880 files max)
    # Clean up files older than 24 hours
    find "$MONITOR_OUTPUT_DIR" -name "${MONITOR_TARGET}-*.json" -type f -mtime +1 -delete 2>/dev/null || true
}

# Signal handlers for graceful shutdown
cleanup_on_exit() {
    log "Monitor shutting down gracefully..."
    log "Total heartbeats emitted: $HEARTBEAT_COUNT"
    local uptime=$(($(date +%s) - MONITOR_START_TIME))
    log "Monitor uptime: ${uptime}s"
}

# Set up signal handlers
trap cleanup_on_exit EXIT INT TERM

# Main monitoring loop
main() {
    parse_args "$@"
    initialize_monitor

    log "Starting monitoring loop..."
    log "Monitoring $MONITOR_TARGET every ${MONITOR_INTERVAL} seconds"

    local next_cleanup=0

    while true; do
        # Emit heartbeat
        emit_heartbeat

        # Periodic cleanup (every hour)
        local current_time
        current_time=$(date +%s)
        if (( current_time >= next_cleanup )); then
            debug "Performing periodic cleanup of old heartbeat files"
            cleanup_old_heartbeats
            next_cleanup=$((current_time + 3600))  # Next cleanup in 1 hour
        fi

        # Sleep until next heartbeat
        debug "Sleeping ${MONITOR_INTERVAL}s until next heartbeat..."
        sleep "$MONITOR_INTERVAL"
    done
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
