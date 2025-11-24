#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Infrastructure Deployment Script for GitHub Workflows
#
# This script handles the deployment of Sigul infrastructure components
# for integration testing with improved permission handling and better
# error diagnosis for GitHub Actions environment.
#
# Usage:
#   ./scripts/deploy-sigul-infrastructure.sh [OPTIONS]
#
# Options:
#   --verbose       Enable verbose output
#   --debug         Enable debug mode with detailed diagnostics
#   --local-debug   Enable local debugging mode (persistent infrastructure)
#   --help          Show this help message

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.sigul.yml"

# Load health library
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/health.sh"

# Default options
VERBOSE_MODE=false
DEBUG_MODE=false
LOCAL_DEBUG_MODE=false
SHOW_HELP=false
DEPLOYMENT_MODE="auto"  # auto, production, local, ci
FORCE_CLEAN_VOLUMES=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
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

debug() {
    if [[ "${DEBUG_MODE}" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

# Function to determine which Docker Compose command to use
get_docker_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker compose"
    fi
}

# Detect GitHub Actions environment and adjust timing accordingly
is_github_actions() {
    [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

# Get timing adjustments for environment
get_timeout_multiplier() {
    if is_github_actions; then
        echo "2"  # GitHub Actions may need more time
    else
        echo "1"  # Local development
    fi
}

# Help function
show_help() {
    cat << EOF
Sigul Infrastructure Deployment Script for GitHub Workflows

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --verbose                Enable verbose output
    --debug                  Enable debug mode with detailed diagnostics
    --local-debug            Enable local debugging mode (persistent infrastructure)
    --mode <MODE>            Set deployment mode: auto, production, local, ci
    --force-clean-volumes    Force clean all volumes before deployment
    --help                   Show this help message

DESCRIPTION:
    This script deploys the Sigul infrastructure for integration testing
    with better permission handling, error diagnosis, and GitHub Actions compatibility.

    The script performs:
    1. Environment analysis and prerequisite checking
    2. Container image loading and validation
    3. Sigul server and bridge container deployment with diagnostics
    6. Comprehensive health checks and connectivity verification

IMPROVEMENTS:
    - Better permission handling for GitHub Actions environment
    - Container-native configuration via sigul-init.sh
    - Enhanced error diagnosis and logging
    - Robust health checks with detailed feedback
    - Container startup diagnostics and troubleshooting

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                VERBOSE_MODE=true  # Debug implies verbose
                shift
                ;;
            --local-debug)
                LOCAL_DEBUG_MODE=true
                VERBOSE_MODE=true  # Local debug implies verbose
                shift
                ;;
            --mode)
                DEPLOYMENT_MODE="$2"
                shift 2
                ;;
            --force-clean-volumes)
                FORCE_CLEAN_VOLUMES=true
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

# Initialize bridge readiness tracking
initialize_bridge_readiness_tracking() {
    local artifacts_dir="${PROJECT_ROOT}/test-artifacts"
    mkdir -p "${artifacts_dir}"

    # Initialize readiness tracking file
    local readiness_file="${artifacts_dir}/bridge-readiness.json"
    cat > "$readiness_file" << EOF
{
    "state": "initializing",
    "attempts": 0,
    "continuous_uptime_secs": 0,
    "restart_count_at_verdict": 0,
    "last_check_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "checks_history": []
}
EOF
    chmod 644 "$readiness_file"
    debug "Bridge readiness tracking initialized: $readiness_file"
}

# Check bridge port and internal socket connectivity with structured output
# shellcheck disable=SC2317  # Function may be called indirectly or in future usage
check_bridge_connectivity() {
    local check_result
    check_result='{
        "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
        "external_port_ok": false,
        "internal_socket_ok": false,
        "container_running": false,
        "details": {}
    }'

    # Check if container is running
    local container_status
    container_status=$(docker container inspect sigul-bridge --format '{{.State.Status}}' 2>/dev/null || echo "not found")

    if [[ "$container_status" == "running" ]]; then
        check_result=$(echo "$check_result" | jq '.container_running = true')

        # Check external port connectivity
        if nc -z localhost 44334 2>/dev/null; then
            check_result=$(echo "$check_result" | jq '.external_port_ok = true')
        fi

        # Check internal socket connectivity using ss inside container
        local internal_check
        if internal_check=$(docker exec sigul-bridge ss -tlnp | grep ":44334" 2>/dev/null); then
            check_result=$(echo "$check_result" | jq '.internal_socket_ok = true')
            check_result=$(echo "$check_result" | jq --arg details "$internal_check" '.details.socket_info = $details')
        fi
    else
        check_result=$(echo "$check_result" | jq --arg status "$container_status" '.details.container_status = $status')
    fi

    echo "$check_result"
}

# Simple bridge readiness check with early diagnostic collection
perform_simple_bridge_readiness_check() {
    local artifacts_dir="${PROJECT_ROOT}/test-artifacts"
    local readiness_file="${artifacts_dir}/bridge-readiness.json"
    local timeout_multiplier
    timeout_multiplier=$(get_timeout_multiplier)
    local max_attempts=$((20 * timeout_multiplier))  # Base 1 minute, adjusted for environment
    local attempt=1
    local check_interval=3

    log "Starting simple bridge readiness check (max $max_attempts attempts)"

    # Collect early diagnostics
    collect_early_bridge_diagnostics

    while [[ $attempt -le $max_attempts ]]; do
        log "Bridge readiness check (attempt $attempt/$max_attempts)..."

        # Check if bridge is accessible
        if nc -z localhost 44334 2>/dev/null; then
            log "✅ Bridge is accessible on port 44334"

            # Update readiness file
            local final_status
            final_status=$(jq '.state = "ready" | .final_verdict_time = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' "$readiness_file")
            echo "$final_status" > "$readiness_file"

            return 0
        fi

        # Log failure details every 5 attempts
        if [[ $((attempt % 5)) -eq 0 ]]; then
            error "Bridge not accessible after $attempt attempts"
            error "Container status: $(docker container inspect sigul-bridge --format '{{.State.Status}}' 2>/dev/null || echo 'not found')"
        fi

        ((attempt++))
        sleep $check_interval
    done

    # Timeout reached - collect final diagnostics
    error "Bridge readiness check timed out after $max_attempts attempts"
    collect_bridge_failure_diagnostics
    return 1
}

# Collect early bridge diagnostics
collect_early_bridge_diagnostics() {
    log "Collecting early bridge diagnostics..."

    local diagnostics_dir="${PROJECT_ROOT}/test-artifacts/early-bridge-diagnostics"
    mkdir -p "$diagnostics_dir"

    # Container status
    docker container inspect sigul-bridge > "$diagnostics_dir/container-inspect.json" 2>/dev/null || echo "Cannot inspect container" > "$diagnostics_dir/container-inspect.json"

    # Container logs
    docker logs sigul-bridge > "$diagnostics_dir/container-logs.txt" 2>&1 || echo "Cannot retrieve logs" > "$diagnostics_dir/container-logs.txt"

    # Network status
    docker exec sigul-bridge ss -tlnp > "$diagnostics_dir/network-sockets.txt" 2>/dev/null || echo "Cannot retrieve network info" > "$diagnostics_dir/network-sockets.txt"

    # Host connectivity test
    {
        echo "=== Host Connectivity Test ==="
        echo "Date: $(date)"
        echo "nc test to localhost:44334: $(nc -z localhost 44334 2>&1 && echo 'SUCCESS' || echo 'FAILED')"
        echo "netstat listening ports:"
        netstat -tlnp 2>/dev/null | grep -E "(44334|LISTEN)" || echo "No listening ports found"
    } > "$diagnostics_dir/host-connectivity.txt"

    debug "Early bridge diagnostics collected in: $diagnostics_dir"
}

# Collect bridge failure diagnostics
collect_bridge_failure_diagnostics() {
    error "Collecting bridge failure diagnostics..."

    local diagnostics_dir="${PROJECT_ROOT}/test-artifacts/bridge-failure-diagnostics"
    mkdir -p "$diagnostics_dir"

    # Container final state
    docker container inspect sigul-bridge > "$diagnostics_dir/final-container-inspect.json" 2>/dev/null || echo "Cannot inspect container" > "$diagnostics_dir/final-container-inspect.json"

    # Full container logs
    docker logs sigul-bridge > "$diagnostics_dir/final-container-logs.txt" 2>&1 || echo "Cannot retrieve logs" > "$diagnostics_dir/final-container-logs.txt"

    # Network final state
    docker exec sigul-bridge ss -tlnp > "$diagnostics_dir/final-network-sockets.txt" 2>/dev/null || echo "Cannot retrieve network info" > "$diagnostics_dir/final-network-sockets.txt"

    # Docker compose services status
    docker-compose -f "${COMPOSE_FILE}" ps > "$diagnostics_dir/compose-services-status.txt" 2>&1 || echo "Cannot retrieve compose status" > "$diagnostics_dir/compose-services-status.txt"

    error "Bridge failure diagnostics collected in: $diagnostics_dir"
}

# Generate unified infrastructure status JSON
generate_infrastructure_status() {
    local artifacts_dir="${PROJECT_ROOT}/test-artifacts"
    local status_file="$artifacts_dir/infrastructure-status.json"

    log "Generating unified infrastructure status JSON using health library"

    # Ensure artifacts directory exists
    mkdir -p "$artifacts_dir"

    # Use health library for comprehensive checks
    local bridge_health server_health
    bridge_health=$(check_component_health "bridge")
    server_health=$(check_component_health "server")

    # Extract key information using health library data
    local bridge_status bridge_restart_count bridge_exit_code bridge_port_ok
    bridge_status=$(echo "$bridge_health" | jq -r '.containerStatus.status')
    bridge_restart_count=$(echo "$bridge_health" | jq -r '.containerStatus.restartCount')
    bridge_exit_code=$(echo "$bridge_health" | jq -r '.containerStatus.exitCode')

    # Check port status from health data
    local bridge_port_status
    bridge_port_status=$(echo "$bridge_health" | jq -r '.portStatus.reachable // false')
    if [[ "$bridge_port_status" == "true" ]]; then
        bridge_port_ok="true"
    else
        bridge_port_ok="false"
    fi

    # Collect server status from health data
    local server_status server_restart_count server_exit_code
    server_status=$(echo "$server_health" | jq -r '.containerStatus.status')
    server_restart_count=$(echo "$server_health" | jq -r '.containerStatus.restartCount')
    server_exit_code=$(echo "$server_health" | jq -r '.containerStatus.exitCode')

    # Extract NSS information from health library data
    local bridge_nss_nicknames bridge_nss_missing
    local server_nss_nicknames server_nss_missing

    if [[ "$bridge_status" == "running" ]]; then
        bridge_nss_nicknames=$(echo "$bridge_health" | jq '.nssMetadata.certificates // []')
        bridge_nss_missing=$(echo "$bridge_health" | jq '.nssMetadata.missingCertificates // []')
    else
        bridge_nss_nicknames='[]'
        bridge_nss_missing='["sigul-bridge-cert"]'
    fi

    if [[ "$server_status" == "running" ]]; then
        server_nss_nicknames=$(echo "$server_health" | jq '.nssMetadata.certificates // []')
        server_nss_missing=$(echo "$server_health" | jq '.nssMetadata.missingCertificates // []')
    else
        server_nss_nicknames='[]'
        server_nss_missing='["sigul-server-cert"]'
    fi

    # Check certificate files for bridge
    local bridge_certs='{}'
    if [[ "$bridge_status" == "running" ]]; then
        local bridge_cert_ca bridge_cert_cert bridge_cert_key
        if docker exec sigul-bridge test -f /var/sigul/secrets/certificates/ca.crt 2>/dev/null; then
            bridge_cert_ca='"ok"'
        else
            bridge_cert_ca='"missing"'
        fi
        if docker exec sigul-bridge test -f /var/sigul/secrets/certificates/bridge.crt 2>/dev/null; then
            bridge_cert_cert='"ok"'
        else
            bridge_cert_cert='"missing"'
        fi
        if docker exec sigul-bridge test -f /var/sigul/secrets/certificates/bridge-key.pem 2>/dev/null; then
            bridge_cert_key='"ok"'
        else
            bridge_cert_key='"missing"'
        fi
        bridge_certs=$(jq -n --arg ca "$bridge_cert_ca" --arg cert "$bridge_cert_cert" --arg key "$bridge_cert_key" '{
            "ca.crt": ($ca | fromjson),
            "bridge.crt": ($cert | fromjson),
            "bridge-key.pem": ($key | fromjson)
        }')
    fi

    # Check certificate files for server
    local server_certs='{}'
    if [[ "$server_status" == "running" ]]; then
        local server_cert_ca server_cert_cert server_cert_key
        if docker exec sigul-server test -f /var/sigul/secrets/certificates/ca.crt 2>/dev/null; then
            server_cert_ca='"ok"'
        else
            server_cert_ca='"missing"'
        fi
        if docker exec sigul-server test -f /var/sigul/secrets/certificates/server.crt 2>/dev/null; then
            server_cert_cert='"ok"'
        else
            server_cert_cert='"missing"'
        fi
        if docker exec sigul-server test -f /var/sigul/secrets/certificates/server-key.pem 2>/dev/null; then
            server_cert_key='"ok"'
        else
            server_cert_key='"missing"'
        fi
        server_certs=$(jq -n --arg ca "$server_cert_ca" --arg cert "$server_cert_cert" --arg key "$server_cert_key" '{
            "ca.crt": ($ca | fromjson),
            "server.crt": ($cert | fromjson),
            "server-key.pem": ($key | fromjson)
        }')
    fi

    # Check for last failure information
    local bridge_last_failure server_last_failure
    local fatal_snapshot="$artifacts_dir/fatal_exit_snapshot.txt"
    if [[ -f "$fatal_snapshot" ]]; then
        local snapshot_component snapshot_timestamp
        snapshot_component=$(grep "^Component:" "$fatal_snapshot" | cut -d' ' -f2 2>/dev/null || echo "unknown")
        snapshot_timestamp=$(grep "^Timestamp:" "$fatal_snapshot" | cut -d' ' -f2- 2>/dev/null || echo "unknown")
        local snapshot_exit_code
        snapshot_exit_code=$(grep "^Exit Code:" "$fatal_snapshot" | cut -d' ' -f3 2>/dev/null || echo "unknown")

        if [[ "$snapshot_component" == "bridge" ]]; then
            bridge_last_failure=$(jq -n --arg ec "$snapshot_exit_code" --arg ts "$snapshot_timestamp" --arg df "fatal_exit_snapshot.txt" '{
                "exitCode": ($ec | tonumber? // $ec),
                "timestamp": $ts,
                "diagnosticFile": $df
            }')
        elif [[ "$snapshot_component" == "server" ]]; then
            server_last_failure=$(jq -n --arg ec "$snapshot_exit_code" --arg ts "$snapshot_timestamp" --arg df "fatal_exit_snapshot.txt" '{
                "exitCode": ($ec | tonumber? // $ec),
                "timestamp": $ts,
                "diagnosticFile": $df
            }')
        fi
    fi

    # Set defaults for last failure if not found
    bridge_last_failure=${bridge_last_failure:-'null'}
    server_last_failure=${server_last_failure:-'null'}

    # Determine overall health using degraded mode classification
    local bridge_health_status server_health_status overall_health_status all_healthy
    bridge_health_status=$(echo "$bridge_health" | jq -r '.overallHealth')
    server_health_status=$(echo "$server_health" | jq -r '.overallHealth')

    # Determine combined health status
    if [[ "$bridge_health_status" == "healthy" && "$server_health_status" == "healthy" ]]; then
        overall_health_status="healthy"
        all_healthy="true"
    elif [[ "$bridge_health_status" == "crashed" || "$server_health_status" == "crashed" ]]; then
        overall_health_status="crashed"
        all_healthy="false"
    elif [[ "$bridge_health_status" == "unreachable" || "$server_health_status" == "unreachable" ]]; then
        overall_health_status="unreachable"
        all_healthy="false"
    else
        # shellcheck disable=SC2034
        overall_health_status="degraded"
        all_healthy="false"
    fi

    # Generate unified JSON
    local unified_status
    unified_status=$(jq -n \
        --arg bridge_status "$bridge_status" \
        --argjson bridge_restart_count "$bridge_restart_count" \
        --argjson bridge_port_ok "$bridge_port_ok" \
        --argjson bridge_nss_nicknames "$bridge_nss_nicknames" \
        --argjson bridge_nss_missing "$bridge_nss_missing" \
        --argjson bridge_certs "$bridge_certs" \
        --argjson bridge_last_failure "$bridge_last_failure" \
        --arg server_status "$server_status" \
        --argjson server_restart_count "$server_restart_count" \
        --argjson server_nss_nicknames "$server_nss_nicknames" \
        --argjson server_nss_missing "$server_nss_missing" \
        --argjson server_certs "$server_certs" \
        --argjson server_last_failure "$server_last_failure" \
        --argjson all_healthy "$all_healthy" \
        --arg overall_health_status "$overall_health_status" \
        '{
            "bridge": {
                "status": $bridge_status,
                "restartCount": $bridge_restart_count,
                "port44334": $bridge_port_ok,
                "nss": {
                    "nicknames": $bridge_nss_nicknames,
                    "missing": $bridge_nss_missing
                },
                "certs": $bridge_certs,
                "lastFailure": $bridge_last_failure
            },
            "server": {
                "status": $server_status,
                "restartCount": $server_restart_count,
                "nss": {
                    "nicknames": $server_nss_nicknames,
                    "missing": $server_nss_missing
                },
                "certs": $server_certs,
                "lastFailure": $server_last_failure
            },
            "summary": {
                "allHealthy": $all_healthy,
                "overallHealthStatus": $overall_health_status,
                "generatedAt": (now | todate)
            }
        }')

    # Write the unified status file
    echo "$unified_status" > "$status_file"
    chmod 644 "$status_file" 2>/dev/null || true

    debug "Infrastructure status JSON generated: $status_file"
    return 0
}

# Enhanced environment analysis
analyze_environment() {
    log "Analyzing deployment environment..."

    debug "System information:"
    debug "  OS: $(uname -a)"
    debug "  User: $(whoami) ($(id))"
    debug "  Working directory: $(pwd)"
    debug "  Docker version: $(docker --version 2>/dev/null || echo 'Not available')"
    debug "  Docker Compose: $($(get_docker_compose_cmd) version --short 2>/dev/null || echo 'Not available')"

    debug "GitHub Actions environment:"
    debug "  GITHUB_ACTIONS: ${GITHUB_ACTIONS:-false}"
    debug "  RUNNER_OS: ${RUNNER_OS:-unknown}"
    debug "  RUNNER_ARCH: ${RUNNER_ARCH:-unknown}"
    debug "  CI: ${CI:-false}"
    debug "  Runner platform: ${SIGUL_RUNNER_PLATFORM:-auto-detect}"
    debug "  Docker platform: ${SIGUL_DOCKER_PLATFORM:-auto-detect}"

    # Check disk space (cross-platform)
    local available_space
    if command -v df >/dev/null 2>&1; then
        # Try Linux format first, fall back to macOS/BSD format
        available_space=$(df -BG . 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || \
                         df -h . | tail -1 | awk '{print $4}' | sed 's/[^0-9]//g')
    else
        available_space="unknown"
    fi
    if [[ "${available_space:-0}" =~ ^[0-9]+$ ]] && [[ "${available_space}" -lt 2 ]]; then
        warn "Low disk space: ${available_space}GB available"
    elif [[ "${available_space}" == "unknown" ]]; then
        verbose "Disk space check skipped (df command unavailable)"
    else
        debug "Available disk space: ${available_space}GB"
    fi

    success "Environment analysis completed"
}

# Check prerequisites with enhanced validation
check_prerequisites() {
    log "Checking prerequisites with enhanced validation..."

    local missing_tools=()

    # Check for required tools
    for tool in docker nc jq; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        else
            debug "$tool: $(command -v "$tool")"
        fi
    done

    # Check for Docker Compose (either v1 standalone or v2 plugin)
    local compose_cmd
    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        missing_tools+=("docker-compose or docker compose")
    else
        compose_cmd=$(get_docker_compose_cmd)
        debug "Docker Compose: $compose_cmd ($(${compose_cmd} version --short 2>/dev/null || echo 'unknown version'))"
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        error "Please install the missing tools and try again"
        exit 1
    fi

    # Check Docker is running and accessible
    if ! docker info >/dev/null 2>&1; then
        error "Docker is not running or not accessible"
        debug "Docker daemon connection test failed"
        exit 1
    fi

    # Test Docker functionality
    if ! docker run --rm alpine:latest echo "Docker test successful" >/dev/null 2>&1; then
        error "Docker container execution test failed"
        exit 1
    fi

    debug "Docker daemon is running and functional"
    success "Prerequisites check passed"
}

# Detect platform based on system architecture
detect_platform() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "linux-amd64"
            ;;
        aarch64|arm64)
            echo "linux-arm64"
            ;;
        *)
            # Default fallback
            echo "linux-amd64"
            ;;
    esac
}

# Load infrastructure images with enhanced validation
load_infrastructure_images() {
    log "Loading pre-built infrastructure images with validation..."

    local platform_id="${SIGUL_RUNNER_PLATFORM:-$(detect_platform)}"
    local loaded_images=()
    local failed_images=()

    # Check if we're running locally (no artifacts in /tmp)
    if ! compgen -G "/tmp/*.tar" > /dev/null; then
        log "Local mode detected - no .tar artifacts found in /tmp"
        log "Assuming images are already built locally"

        # Verify that the expected images exist locally
        local expected_images=(
            "${SIGUL_SERVER_IMAGE:-server-${platform_id}-image:test}"
            "${SIGUL_BRIDGE_IMAGE:-bridge-${platform_id}-image:test}"
        )

        for image in "${expected_images[@]}"; do
            if docker image inspect "$image" >/dev/null 2>&1; then
                log "✅ Local image found: $image"
            else
                error "❌ Local image not found: $image"
                return 1
            fi
        done

        log "✅ All required local images are available"
        return 0
    fi

    # Debug platform detection for artifact loading mode
    debug "Platform ID detection:"
    debug "  SIGUL_RUNNER_PLATFORM: '${SIGUL_RUNNER_PLATFORM:-unset}'"
    debug "  RUNNER_ARCH: '${RUNNER_ARCH:-unset}'"
    debug "  Resolved platform_id: '${platform_id}'"
    debug "  Available .tar files in /tmp:"
    for file in /tmp/*.tar; do
        if [[ -f "$file" ]]; then
            debug "    $(basename "$file")"
        fi
    done

    # Define image mappings based on build output naming convention
    # - Infrastructure builds create: /tmp/server-${platform_id}.tar, /tmp/bridge-${platform_id}.tar
    # - Client image loading removed from infrastructure deployment (only needed for integration tests)
    declare -A image_mappings
    image_mappings["server-${platform_id}-image:test"]="/tmp/server-${platform_id}.tar"
    image_mappings["bridge-${platform_id}-image:test"]="/tmp/bridge-${platform_id}.tar"

    for target_image in "${!image_mappings[@]}"; do
        local artifact_file="${image_mappings[$target_image]}"

        debug "Processing image: $target_image"
        debug "  Artifact file: $artifact_file"

        if [[ -f "$artifact_file" ]]; then
            # Show current images before loading for debugging
            debug "Images before loading:"
            debug "$(docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}' | head -10)"
            verbose "Loading $target_image from artifact: $artifact_file"

            # Capture the docker load output to identify the actual loaded image
            local load_output
            if load_output=$(docker load --input "$artifact_file" 2>&1); then
                debug "Docker load output: $load_output"

                # Extract the loaded image name from docker load output
                # Format: "Loaded image: <image_name>"
                local loaded_image
                loaded_image=$(echo "$load_output" | grep "^Loaded image:" | head -1 | sed 's/^Loaded image: //')

                if [[ -n "$loaded_image" ]]; then
                    debug "Identified loaded image: $loaded_image"

                    # Tag it with our expected name if different
                    if [[ "$loaded_image" != "$target_image" ]]; then
                        debug "Tagging loaded image '$loaded_image' as '$target_image'"
                        docker tag "$loaded_image" "$target_image"
                    fi
                else
                    warn "Could not identify loaded image from output, checking expected patterns"
                    # Fallback: try common patterns based on target image
                    if [[ "$target_image" == "server-"* ]]; then
                        local base_name="${target_image%-*-image:test}"
                        local platform="${base_name#server-}"
                        loaded_image="server:${platform}"
                    elif [[ "$target_image" == "bridge-"* ]]; then
                        local base_name="${target_image%-*-image:test}"
                        local platform="${base_name#bridge-}"
                        loaded_image="bridge:${platform}"
                    fi

                    if [[ -n "$loaded_image" ]] && docker image inspect "$loaded_image" >/dev/null 2>&1; then
                        debug "Found expected image pattern: $loaded_image"
                        docker tag "$loaded_image" "$target_image"
                    fi
                fi

                # Show current images after loading for debugging
                debug "Images after loading and tagging:"
                debug "$(docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}' | grep -E '(server|bridge|client)' | head -10)"

                # Verify the target image exists
                if docker image inspect "$target_image" >/dev/null 2>&1; then
                    success "✅ Successfully loaded: $target_image"
                    loaded_images+=("$target_image")
                else
                    warn "❌ Image loading verification failed: $target_image"
                    failed_images+=("$target_image")
                fi
            else
                error "❌ Failed to load image from artifact: $artifact_file"
                error "Docker load error: $load_output"
                failed_images+=("$target_image")
            fi
        else
            warn "⚠️  Artifact not found: $artifact_file"

            # Check if image already exists locally
            if docker image inspect "$target_image" >/dev/null 2>&1; then
                success "✅ Image already available locally: $target_image"
                loaded_images+=("$target_image")
            else
                warn "❌ Image not available: $target_image"
                failed_images+=("$target_image")
            fi
        fi
    done

    # Report results
    if [[ ${#loaded_images[@]} -gt 0 ]]; then
        success "Successfully loaded ${#loaded_images[@]} images: ${loaded_images[*]}"
    fi

    if [[ ${#failed_images[@]} -gt 0 ]]; then
        error "Failed to load ${#failed_images[@]} images: ${failed_images[*]}"
        error "Infrastructure deployment may fail due to missing images"
        return 1
    fi

    # Show final image status
    debug "Final image inventory:"
    for image in "${!image_mappings[@]}"; do
        if docker image inspect "$image" >/dev/null 2>&1; then
            local size created
            size=$(docker image inspect "$image" --format '{{.Size}}' 2>/dev/null)
            created=$(docker image inspect "$image" --format '{{.Created}}' 2>/dev/null | cut -d'T' -f1)
            debug "  ✅ $image ($(numfmt --to=iec "${size:-0}" 2>/dev/null || echo 'unknown size'), created: ${created:-unknown})"
        else
            debug "  ❌ $image (not available)"
        fi
    done

    success "Infrastructure image loading completed"
}



# Detect deployment mode and manage volumes accordingly
detect_and_configure_deployment_mode() {
    log "Detecting deployment mode and configuring volume management..."

    # Auto-detect deployment mode if not explicitly set
    if [[ "$DEPLOYMENT_MODE" == "auto" ]]; then
        if is_github_actions; then
            DEPLOYMENT_MODE="ci"
        elif [[ "$LOCAL_DEBUG_MODE" == "true" ]]; then
            DEPLOYMENT_MODE="local"
        else
            DEPLOYMENT_MODE="production"
        fi
    fi

    log "Deployment mode: $DEPLOYMENT_MODE"

    # Configure volume management based on deployment mode
    case "$DEPLOYMENT_MODE" in
        ci)
            log "CI/CD mode: Using ephemeral volumes, ensuring clean state"
            FORCE_CLEAN_VOLUMES=true
            ;;
        local)
            log "Local testing mode: Volumes will persist for faster iteration"
            if [[ "$FORCE_CLEAN_VOLUMES" == "true" ]]; then
                log "Force clean requested: Will reset volumes"
            fi
            ;;
        production)
            log "Production mode: Volumes will persist, no automatic cleanup"
            if [[ "$FORCE_CLEAN_VOLUMES" == "true" ]]; then
                warn "Force clean requested in production mode - this will destroy data!"
                warn "Sleeping 5 seconds for confirmation..."
                sleep 5
            fi
            ;;
        *)
            error "Invalid deployment mode: $DEPLOYMENT_MODE"
            return 1
            ;;
    esac
}

# Clean volumes if required by deployment mode
manage_volumes() {
    if [[ "$FORCE_CLEAN_VOLUMES" != "true" ]]; then
        log "Volume persistence enabled - existing volumes will be reused"
        return 0
    fi

    log "Cleaning existing volumes for fresh deployment..."

    local compose_cmd
    compose_cmd=$(get_docker_compose_cmd)

    # Stop and remove containers first
    if docker ps -q --filter "name=sigul" | grep -q .; then
        log "Stopping existing Sigul containers..."
        docker stop "$(docker ps -q --filter "name=sigul")" 2>/dev/null || true
    fi

    if docker ps -aq --filter "name=sigul" | grep -q .; then
        log "Removing existing Sigul containers..."
        docker rm "$(docker ps -aq --filter "name=sigul")" 2>/dev/null || true
    fi

    # Remove volumes
    local volumes_to_remove=(
        "sigul-sign-docker_sigul_server_data"
        "sigul-sign-docker_sigul_bridge_data"
        "sigul-sign-docker_sigul_client_data"
        "sigul-sign-docker_sigul_monitor_data"
    )

    for volume in "${volumes_to_remove[@]}"; do
        if docker volume ls -q | grep -q "^${volume}$"; then
            log "Removing volume: $volume"
            docker volume rm "$volume" 2>/dev/null || warn "Failed to remove volume: $volume"
        fi
    done

    success "Volume cleanup completed"
}

# Deploy Sigul services with comprehensive monitoring
deploy_sigul_services() {
    log "Deploying Sigul server and bridge with comprehensive monitoring..."

    # Configure deployment mode and handle volumes
    detect_and_configure_deployment_mode
    manage_volumes

    local compose_cmd
    compose_cmd=$(get_docker_compose_cmd)

    # Set environment variables for platform-specific images
    local platform_id="${SIGUL_RUNNER_PLATFORM:-$(detect_platform)}"
    export SIGUL_SERVER_IMAGE="server-${platform_id}-image:test"
    export SIGUL_BRIDGE_IMAGE="bridge-${platform_id}-image:test"
    # SIGUL_CLIENT_IMAGE removed from infrastructure deployment (only needed for integration tests)

    # Generate ephemeral admin password BEFORE starting containers
    log "Setting up ephemeral credentials for deployment..."
    local ephemeral_admin_password
    ephemeral_admin_password=$(head -c 12 /dev/urandom | base64)
    export SIGUL_ADMIN_PASSWORD="$ephemeral_admin_password"
    export SIGUL_SKIP_ADMIN_USER="false"

    # Generate ephemeral NSS password as well
    local ephemeral_nss_password
    ephemeral_nss_password=$(head -c 18 /dev/urandom | base64)
    export NSS_PASSWORD="$ephemeral_nss_password"

    verbose "Generated ephemeral credentials for deployment"

    # Store passwords for integration tests to use
    mkdir -p "${PROJECT_ROOT}/test-artifacts"
    printf '%s' "$ephemeral_admin_password" > "${PROJECT_ROOT}/test-artifacts/admin-password"
    printf '%s' "$ephemeral_nss_password" > "${PROJECT_ROOT}/test-artifacts/nss-password"
    chmod 600 "${PROJECT_ROOT}/test-artifacts/admin-password"
    chmod 600 "${PROJECT_ROOT}/test-artifacts/nss-password"

    # Initialize bridge readiness tracking
    initialize_bridge_readiness_tracking

    verbose "Deploying Sigul services for platform: $platform_id"
    verbose "Using server image: ${SIGUL_SERVER_IMAGE}"
    verbose "Using bridge image: ${SIGUL_BRIDGE_IMAGE}"
    verbose "Admin user creation: enabled"

    # Start cert-init container first to pre-generate all certificates
    log "Starting certificate initialization (cert-init)..."
    if ${compose_cmd} -f "${COMPOSE_FILE}" up cert-init; then
        success "Certificate initialization completed"

        # Verify cert-init completed successfully
        local cert_init_exit_code
        cert_init_exit_code=$(docker inspect sigul-cert-init --format '{{.State.ExitCode}}' 2>/dev/null || echo "1")

        if [[ "$cert_init_exit_code" != "0" ]]; then
            error "Certificate initialization failed with exit code: $cert_init_exit_code"
            error "Certificate initialization logs:"
            docker logs sigul-cert-init 2>&1 | tail -50
            return 1
        fi

        verbose "All certificates pre-generated successfully on bridge"
    else
        error "Failed to run certificate initialization"
        return 1
    fi

    # Start Sigul server
    log "Starting Sigul server..."
    if ${compose_cmd} -f "${COMPOSE_FILE}" up -d sigul-server; then
        success "Sigul server container started"

        # Wait briefly for container to initialize before IP detection
        sleep 2

        # Capture Sigul server container IP (with retry logic)
        local server_ip=""
        local ip_attempts=0
        local max_ip_attempts=10

        while [[ -z "$server_ip" && $ip_attempts -lt $max_ip_attempts ]]; do
            server_ip=$(docker inspect sigul-server --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
            if [[ -n "$server_ip" ]]; then
                export SIGUL_SERVER_IP="$server_ip"
                verbose "Sigul server container IP: $server_ip"
                # Export to GitHub Actions environment if available
                if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
                    echo "server-ip=$server_ip" >> "$GITHUB_OUTPUT"
                fi
                break
            else
                ((ip_attempts++))
                debug "IP detection attempt $ip_attempts/$max_ip_attempts failed, retrying in 1 second..."
                sleep 1
            fi
        done

        if [[ -z "$server_ip" ]]; then
            warn "Could not determine Sigul server container IP after $max_ip_attempts attempts"
            debug "Container may still be initializing - this won't affect functionality"
        fi
    else
        error "Failed to start Sigul server container"
        return 1
    fi

    # Enhanced server readiness check with detailed monitoring
    log "Waiting for Sigul server with detailed monitoring..."
    local timeout_multiplier
    timeout_multiplier=$(get_timeout_multiplier)
    local max_attempts=$((60 * timeout_multiplier))
    local attempt=1
    local startup_errors=0

    if is_github_actions; then
        log "GitHub Actions environment detected - using extended timeouts"
    fi

    while [[ $attempt -le $max_attempts ]]; do
        verbose "Sigul server readiness check (attempt $attempt/$max_attempts)..."

        # Check container status
        local container_status exit_code
        container_status=$(docker container inspect sigul-server --format '{{.State.Status}}' 2>/dev/null || echo "not found")
        exit_code=$(docker container inspect sigul-server --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")

        debug "Server container status: $container_status (exit code: $exit_code)"

        if [[ "$container_status" == "exited" ]]; then
            error "Sigul server container has exited (exit code: $exit_code)"

            # Get detailed logs for diagnosis
            error "Server container logs:"
            docker logs sigul-server 2>&1 | tail -30 | while read -r line; do
                error "  $line"
            done

            # Get additional container information
            debug "Container inspect output:"
            docker container inspect sigul-server --format '{{json .State}}' 2>/dev/null | \
                python3 -m json.tool 2>/dev/null | while read -r line; do
                debug "  $line"
            done

            return 1
        elif [[ "$container_status" != "running" ]]; then
            warn "Server container not running (status: $container_status)"
            ((startup_errors++))

            # If container is stuck restarting for too long, treat as failure
            if [[ "$container_status" == "restarting" && $startup_errors -gt 10 ]]; then
                error "Server container stuck in restart loop (status: $container_status)"
                error "Container has failed to start properly after $startup_errors restart attempts"

                # Get container logs for diagnosis
                error "Recent server container logs:"
                docker logs sigul-server 2>&1 | tail -20 | while read -r line; do
                    error "  $line"
                done

                return 1
            fi
        else
            # Container is running, test both port connectivity and process health
            # (matching Docker health check requirements)
            local port_ok=false
            local process_ok=false

            # Test port connectivity
            # Server connects to bridge, doesn't listen on a port
            # Check for healthy processes instead
            port_ok=true
            debug "✅ Server connectivity check skipped (server connects to bridge)"

            # Test process health (matching Docker health check)
            if docker exec sigul-server pgrep -f server >/dev/null 2>&1; then
                process_ok=true
                debug "✅ Sigul server process is running"
            else
                debug "❌ Sigul processes not found"
            fi

            # Both checks must pass
            if [[ "$port_ok" == "true" && "$process_ok" == "true" ]]; then
                success "✅ Sigul server is running with healthy processes"
                break
            else
                debug "Server not fully ready yet (processes: $process_ok)"
            fi
        fi

        # Show progress and recent logs every 15 attempts
        if [[ $((attempt % 15)) -eq 0 ]]; then
            log "Still waiting for Sigul server... (attempt $attempt/$max_attempts, startup errors: $startup_errors)"
            debug "Recent server logs:"
            docker logs sigul-server 2>&1 | tail -5 | while read -r line; do
                debug "  $line"
            done
        fi

        sleep 3
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        error "Sigul server failed to start within expected time ($max_attempts attempts)"
        error "Cannot proceed with bridge deployment - server is required"
        return 1
    fi

    success "Sigul server deployed and ready (took $((attempt-1)) attempts)"

    # Additional validation to ensure container will pass Docker health checks
    debug "Performing final health validation..."
    local health_check_result
    health_check_result=$(docker exec sigul-server sh -c "echo 'Health check: Looking for server process...' && pgrep -f server && echo 'Health check: PASSED'" 2>&1 || echo "HEALTH_CHECK_FAILED")

    if [[ "$health_check_result" == *"HEALTH_CHECK_FAILED"* ]]; then
        warn "Server passed readiness but may fail Docker health checks"
        debug "Health check output:"
        echo "$health_check_result" | while read -r line; do
            debug "  $line"
        done
    else
        debug "Server passes both readiness and health checks"
    fi

    # Start Sigul bridge
    log "Starting Sigul bridge..."
    if ${compose_cmd} -f "${COMPOSE_FILE}" up -d sigul-bridge; then
        success "Sigul bridge container started"

        # Capture Sigul bridge container IP
        local bridge_ip
        bridge_ip=$(docker inspect sigul-bridge --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || echo "")
        if [[ -n "$bridge_ip" ]]; then
            export SIGUL_BRIDGE_IP="$bridge_ip"
            verbose "Sigul bridge container IP: $bridge_ip"
            # Export to GitHub Actions environment if available
            if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
                echo "bridge-ip=$bridge_ip" >> "$GITHUB_OUTPUT"
            fi
        else
            warn "Could not determine Sigul bridge container IP"
        fi

        success "Sigul bridge container started"

        # Wait for bridge to be fully ready
        log "Waiting for bridge to be fully operational..."
        local bridge_ready=false
        local bridge_attempts=0
        local max_bridge_attempts=30

        while [[ $bridge_attempts -lt $max_bridge_attempts ]]; do
            if nc -z localhost 44334 2>/dev/null; then
                bridge_ready=true
                break
            fi
            ((bridge_attempts++))
            verbose "Bridge readiness check $bridge_attempts/$max_bridge_attempts..."
            sleep 2
        done

        if [[ "$bridge_ready" == "true" ]]; then
            success "Bridge is ready and accepting connections"
        else
            warn "Bridge may not be fully ready, but continuing..."
        fi
    else
        error "Failed to start Sigul bridge container"
        return 1
    fi

    # Enhanced bridge readiness check
    log "Waiting for Sigul bridge with monitoring..."
    attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        verbose "Sigul bridge readiness check (attempt $attempt/$max_attempts)..."

        # Check container status
        local bridge_status bridge_exit_code
        bridge_status=$(docker container inspect sigul-bridge --format '{{.State.Status}}' 2>/dev/null || echo "not found")
        bridge_exit_code=$(docker container inspect sigul-bridge --format '{{.State.ExitCode}}' 2>/dev/null || echo "unknown")

        debug "Bridge container status: $bridge_status (exit code: $bridge_exit_code)"

        if [[ "$bridge_status" == "exited" ]]; then
            error "Sigul bridge container has exited (exit code: $bridge_exit_code)"

            error "Bridge container logs:"
            docker logs sigul-bridge 2>&1 | tail -20 | while read -r line; do
                error "  $line"
            done

            return 1
        elif [[ "$bridge_status" == "running" ]]; then
            # Perform provisional connectivity check
            if nc -z localhost 44334 2>/dev/null; then
                verbose "🔄 Bridge provisional OK (performing simple readiness check)"
                # Now perform the simple readiness check
                if perform_simple_bridge_readiness_check; then
                    success "✅ Sigul bridge is ready"
                    break
                else
                    debug "Bridge failed readiness check"
                fi
            else
                debug "Bridge not yet responding on port 44334"
            fi
        fi

        # Show progress every 15 attempts
        if [[ $((attempt % 15)) -eq 0 ]]; then
            log "Still waiting for Sigul bridge... (attempt $attempt/$max_attempts)"
        fi

        sleep 3
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        error "Sigul bridge failed to start within expected time ($max_attempts attempts)"
        return 1
    fi

    success "Sigul bridge deployed and ready (took $((attempt-1)) attempts)"

    success "All Sigul services deployed successfully"
}

# Fix SSL certificate issue by importing client certificate to bridge
# This resolves the "Unexpected EOF in NSPR" error in SSL client authentication
# shellcheck disable=SC2317  # Function may be called indirectly or in future usage
import_client_cert_to_bridge() {
    local client_container="$1"
    local bridge_container="sigul-bridge"

    log "Importing client certificate to bridge for SSL authentication..."

    # Wait for client container to be fully initialized with NSS database
    local max_wait=30
    local wait_count=0
    while [[ $wait_count -lt $max_wait ]]; do
        if docker exec "$client_container" test -f /var/sigul/nss/client/cert9.db 2>/dev/null; then
            break
        fi
        sleep 1
        ((wait_count++))
    done

    if [[ $wait_count -ge $max_wait ]]; then
        error "Client NSS database not ready after ${max_wait}s"
        return 1
    fi

    # Remove any existing/stale client certificate from bridge
    docker exec "$bridge_container" certutil -D -d /var/sigul/nss/bridge -n sigul-client-cert 2>/dev/null || true

    # Export current client certificate from client container
    if ! docker exec "$client_container" certutil -L -d /var/sigul/nss/client -n sigul-client-cert -a > /tmp/current-client-cert.pem 2>/dev/null; then
        error "Failed to export client certificate from client container"
        return 1
    fi

    # Import to bridge with proper trust flags for SSL client authentication
    docker cp /tmp/current-client-cert.pem "$bridge_container":/tmp/

    if docker exec "$bridge_container" certutil -A -d /var/sigul/nss/bridge \
        -n sigul-client-cert \
        -t "P,," \
        -a -i /tmp/current-client-cert.pem \
        -f /var/sigul/secrets/nss-password 2>/dev/null; then

        success "Client certificate imported to bridge NSS database"

        # Verify the import
        if docker exec "$bridge_container" certutil -L -d /var/sigul/nss/bridge -n sigul-client-cert >/dev/null 2>&1; then
            verbose "SSL certificate fix verified: client cert now in bridge NSS database"
        else
            warn "SSL certificate import verification failed"
        fi
    else
        error "Failed to import client certificate to bridge"
        return 1
    fi

    # Cleanup temporary files
    rm -f /tmp/current-client-cert.pem
    docker exec "$bridge_container" rm -f /tmp/current-client-cert.pem 2>/dev/null || true

    return 0
}

# Comprehensive infrastructure health verification
verify_infrastructure() {
    log "Performing comprehensive infrastructure health verification..."

    local services=(
        "44334:Sigul Bridge:sigul-bridge"
    )

    local healthy_services=0
    local total_services=${#services[@]}

    for service in "${services[@]}"; do
        local port="${service%%:*}"
        local remaining="${service#*:}"
        local name="${remaining%%:*}"
        local container="${remaining#*:}"

        log "Testing $name (container: $container, port: $port)..."

        # Check container status
        local status health
        status=$(docker container inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "not found")
        health=$(docker container inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null || echo "no health check")

        debug "Container status: $status, health: $health"

        if [[ "$status" != "running" ]]; then
            error "❌ Container $container is not running (status: $status)"
            continue
        fi

        # Test port connectivity with timeout
        verbose "Testing connectivity to $name on port $port..."
        if timeout 10 bash -c "until nc -z localhost $port; do sleep 1; done" 2>/dev/null; then
            success "✅ $name is accessible on port $port"
            ((healthy_services++))

            # Additional service-specific health checks
            case "$name" in
                "Sigul Bridge")
                    debug "Sigul Bridge port accessibility confirmed"
                    ;;
            esac
        else
            error "❌ $name is not accessible on port $port"
        fi
    done

    # Check server process health separately since it doesn't listen on a port
    log "Testing Sigul Server (process health check)..."

    # First check if the server container is running
    local server_container_status
    server_container_status=$(docker inspect --format='{{.State.Status}}' sigul-server 2>/dev/null || echo "unknown")

    if [[ "$server_container_status" != "running" ]]; then
        error "❌ Sigul Server container is not running (status: $server_container_status)"
        if [[ "$server_container_status" == "restarting" ]]; then
            error "Server container is in restart loop - check container logs for initialization errors"
            debug "Server container logs (last 50 lines):"
            docker logs --tail 50 sigul-server 2>/dev/null || true

            # Check for startup error logs
            debug "Checking for server startup error logs..."
            if docker exec sigul-server test -f /var/sigul/logs/server/startup_errors.log 2>/dev/null; then
                debug "Server startup errors found:"
                docker exec sigul-server cat /var/sigul/logs/server/startup_errors.log 2>/dev/null || true
            else
                debug "No startup error log found at /var/sigul/logs/server/startup_errors.log"
            fi

            # Check container exit code
            local server_exit_code
            server_exit_code=$(docker inspect --format='{{.State.ExitCode}}' sigul-server 2>/dev/null || echo "unknown")
            debug "Server container last exit code: $server_exit_code"

            # Check container restart count
            local server_restart_count
            server_restart_count=$(docker inspect --format='{{.RestartCount}}' sigul-server 2>/dev/null || echo "unknown")
            debug "Server container restart count: $server_restart_count"
        fi
    elif docker exec sigul-server pgrep -f server >/dev/null 2>&1; then
        success "✅ Sigul Server process is running"
        ((healthy_services++))
        ((total_services++))
    else
        error "❌ Sigul Server process is not running"
        ((total_services++))
    fi

    # Overall health assessment
    log "Infrastructure health summary: $healthy_services/$total_services services healthy"

    if [[ $healthy_services -eq $total_services ]]; then
        success "✅ All infrastructure services are healthy and accessible"

        # Verify bridge is ready to accept connections with proper retry logic
        log "Verifying bridge readiness for connections..."
        log "Initial wait: allowing bridge application 10 seconds to start listening..."
        sleep 10

        # Retry logic: check if bridge is listening internally
        local bridge_ready=false
        local max_retries=10
        local retry_interval=3
        local attempt=1

        while [[ $attempt -le $max_retries ]]; do
            debug "Bridge readiness check attempt $attempt/$max_retries..."

            # First check if the container is running before trying to exec into it
            local container_status
            container_status=$(docker inspect --format='{{.State.Status}}' sigul-bridge 2>/dev/null || echo "unknown")

            if [[ "$container_status" != "running" ]]; then
                debug "Bridge container is not running (status: $container_status), waiting ${retry_interval} seconds..."
                if [[ $attempt -lt $max_retries ]]; then
                    sleep $retry_interval
                fi
                ((attempt++))
                continue
            fi

            # Container is running, now check if it's listening on the port
            if docker exec sigul-bridge ss -tlun | grep -q ":44334" 2>/dev/null; then
                bridge_ready=true
                verbose "🔄 Bridge is listening on port 44334 (provisional - final validation pending)"
                break
            else
                debug "Bridge not yet listening on port 44334, waiting ${retry_interval} seconds..."
                if [[ $attempt -lt $max_retries ]]; then
                    sleep $retry_interval
                fi
                ((attempt++))
            fi
        done

        if [[ "$bridge_ready" != "true" ]]; then
            error "❌ Bridge is not listening on port 44334 after $max_retries attempts"
            error "Total wait time: $((10 + (max_retries - 1) * retry_interval)) seconds"

            # Provide additional debugging information
            local final_container_status
            final_container_status=$(docker inspect --format='{{.State.Status}}' sigul-bridge 2>/dev/null || echo "unknown")
            error "Final bridge container status: $final_container_status"

            if [[ "$final_container_status" == "restarting" ]]; then
                error "Container is in restart loop - check container logs for initialization errors"
                debug "Bridge container logs (last 50 lines):"
                docker logs --tail 50 sigul-bridge 2>/dev/null || true

                # Check for startup error logs
                debug "Checking for bridge startup error logs..."
                if docker exec sigul-bridge test -f /var/sigul/logs/bridge/startup_errors.log 2>/dev/null; then
                    debug "Bridge startup errors found:"
                    docker exec sigul-bridge cat /var/sigul/logs/bridge/startup_errors.log 2>/dev/null || true
                else
                    debug "No startup error log found at /var/sigul/logs/bridge/startup_errors.log"
                fi

                # Check container exit code
                local exit_code
                exit_code=$(docker inspect --format='{{.State.ExitCode}}' sigul-bridge 2>/dev/null || echo "unknown")
                debug "Bridge container last exit code: $exit_code"

                # Check container restart count
                local restart_count
                restart_count=$(docker inspect --format='{{.RestartCount}}' sigul-bridge 2>/dev/null || echo "unknown")
                debug "Bridge container restart count: $restart_count"
            fi

            # Always attempt to extract logs from the persistent volume for deeper diagnostics,
            # even if the container already restarted and lost its stdout/stderr context.
            debug "Extracting bridge logs from persistent volume (if present)..."

            # Dynamically determine the actual bridge volume name
            local bridge_volume_name=""
            bridge_volume_name=$(docker inspect sigul-bridge --format '{{range .Mounts}}{{if eq .Destination "/var/sigul"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")

            if [[ -z "$bridge_volume_name" ]]; then
                error "Could not determine bridge container volume name, listing all volumes for diagnosis:"
                docker volume ls || true
                error "Cannot extract bridge logs from volume - volume name resolution failed"
                return 1
            else
                debug "Using bridge data volume: $bridge_volume_name"
                docker run --rm -v "${bridge_volume_name}":/var/sigul alpine:3.19 sh -c '
                  set -e
                  echo "===== Bridge Log Directory Listing ====="
                  ls -l /var/sigul/logs/bridge 2>/dev/null || echo "Cannot list /var/sigul/logs/bridge"
                  echo
                  for f in /var/sigul/logs/bridge/daemon.log \
                           /var/sigul/logs/bridge/daemon.stdout.log \
                           /var/sigul/logs/bridge/startup_errors.log; do
                    if [ -f "$f" ]; then
                      echo "----- $f -----"
                      if [ "$(basename "$f")" = "startup_errors.log" ]; then
                        size=$(wc -c < "$f" 2>/dev/null || echo 0)
                        if [ "$size" -le 20000 ]; then
                          cat "$f" || true
                        else
                          echo "(File larger than 20KB, showing last 200 lines)"
                          tail -200 "$f" || true
                        fi
                      else
                        tail -120 "$f" || true
                      fi
                      echo
                    fi
                  done
                  if [ -f /var/sigul/logs/bridge/strace.bridge.txt ]; then
                    echo "----- /var/sigul/logs/bridge/strace.bridge.txt (tail 120) -----"
                    tail -120 /var/sigul/logs/bridge/strace.bridge.txt || true
                  fi
                ' 2>/dev/null || true
            fi

            return 1
        fi

        # Give server more time in GitHub Actions environment
        log "Allowing server initialization time before connectivity test..."
        if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
            log "GitHub Actions environment detected - using extended timing"
            sleep 10
        else
            sleep 3
        fi

        # Test actual connectivity: server connecting to bridge with retry logic
        log "Testing inter-service connectivity..."
        local connectivity_ok=false
        local timeout_multiplier
        timeout_multiplier=$(get_timeout_multiplier)
        # Extended timing for GitHub Actions environment
        if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
            local max_attempts=15
            local sleep_interval=3
            debug "GitHub Actions environment: using 15 attempts with 3-second intervals (45 seconds max)"
        else
            local max_attempts=$((10 * timeout_multiplier))
            local sleep_interval=2
            debug "Local environment: using 10 attempts with 2-second intervals (20 seconds max)"
        fi
        local attempt=1

        while [[ $attempt -le $max_attempts ]]; do
            debug "Connectivity check attempt $attempt/$max_attempts..."

            if docker exec sigul-server ss -tun | grep -q ":44333" 2>/dev/null; then
                connectivity_ok=true
                success "✅ Inter-service network connectivity verified (server connected to bridge)"
                break
            else
                debug "Server not yet connected to bridge, waiting ${sleep_interval} seconds..."
                sleep ${sleep_interval}
                ((attempt++))
            fi
        done

        if [[ "$connectivity_ok" != "true" ]]; then
            local total_wait_time=$((max_attempts * sleep_interval))
            local env_info=""
            if is_github_actions; then
                env_info=" (GitHub Actions environment with extended timeouts)"
            fi
            error "❌ Inter-service connectivity test failed after ${total_wait_time} seconds${env_info} (server not connected to bridge)"
            debug "Environment: $(is_github_actions && echo "GitHub Actions" || echo "Local")"
            debug "Server network connections:"
            docker exec sigul-server ss -tun 2>/dev/null || true
            debug "Bridge network connections:"
            docker exec sigul-bridge ss -tun 2>/dev/null || true
            debug "Testing DNS resolution from server to bridge:"
            docker exec sigul-server nslookup sigul-bridge 2>/dev/null || docker exec sigul-server getent hosts sigul-bridge 2>/dev/null || true
            debug "Server bridge configuration:"
            docker exec sigul-server grep -A 3 -B 3 "bridge-hostname\|bridge-port" /var/sigul/config/server.conf 2>/dev/null || true
            debug "Bridge listening status:"
            docker exec sigul-bridge ss -tlun | grep 44334 2>/dev/null || true
            debug "Testing basic connectivity from server to bridge:"
            if docker exec sigul-server nc -z sigul-bridge 44334 2>/dev/null; then
                debug "✅ Basic TCP connection works"
            else
                debug "❌ Basic TCP connection failed"
            fi
            debug "Container runtime information:"
            docker version --format '{{.Server.Version}}' 2>/dev/null || true
            debug "Network driver information:"
            docker network inspect sigul-sign-docker_sigul-network --format '{{.Driver}}' 2>/dev/null || true
            if is_github_actions; then
                debug "GitHub Actions runner information:"
                echo "Runner OS: ${RUNNER_OS:-unknown}"
                echo "Runner Arch: ${RUNNER_ARCH:-unknown}"
                debug "System resource usage:"
                docker exec sigul-server sh -c "cat /proc/loadavg" 2>/dev/null || true
                debug "Available memory:"
                docker exec sigul-server sh -c "free -h" 2>/dev/null || true
            fi
            return 1
        fi

        # Generate final infrastructure status JSON
        generate_infrastructure_status

        # Use health-aware success message
        local infrastructure_status
        infrastructure_status=$(cat "${PROJECT_ROOT}/test-artifacts/infrastructure-status.json")
        local overall_health
        overall_health=$(echo "$infrastructure_status" | jq -r '.summary.overallHealthStatus')

        case "$overall_health" in
            "healthy")
                success "✅ All infrastructure services verified and fully operational"
                ;;
            "degraded")
                warn "⚠️  Infrastructure services operational but with issues (degraded mode)"
                ;;
            "unreachable")
                error "🔌 Infrastructure services unreachable"
                return 1
                ;;
            "crashed")
                error "❌ Infrastructure services have crashed"
                return 1
                ;;
            *)
                warn "❓ Infrastructure services status unknown"
                ;;
        esac
        return 0
    else
        error "❌ Infrastructure health check failed: only $healthy_services/$total_services services are healthy"

        # Show detailed status of failed services
        log "Detailed container status for debugging:"
        docker ps -a --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | while read -r line; do
            error "  $line"
        done

        return 1
    fi
}

# Main deployment orchestration
deploy_infrastructure() {
    log "Starting comprehensive Sigul infrastructure deployment..."
    local start_time
    start_time=$(date +%s)

    # Enhanced deployment steps with better error handling
    analyze_environment || { error "Environment analysis failed"; return 1; }
    check_prerequisites || { error "Prerequisites check failed"; return 1; }

    load_infrastructure_images || { error "Image loading failed"; return 1; }

    deploy_sigul_services || { error "Sigul services deployment failed"; return 1; }
    verify_infrastructure || { error "Infrastructure verification failed"; return 1; }

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    success "🎉 Sigul infrastructure deployment completed successfully in ${duration} seconds"

    log "Infrastructure components summary:"
    log "  🖥️  Sigul Server: sigul-server (connects to bridge)"
    log "  🌉 Sigul Bridge: sigul-bridge (port 44334)"
    log "  🔐 PKI Certificates: Self-contained in containers"
    log "  ⚙️  Configuration Files: configs/ directory"
    log "  🕒 Total Deployment Time: ${duration} seconds"

    debug "Final container status:"
    docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | while read -r line; do
        debug "  $line"
    done
}

# Main function
main() {
    parse_args "$@"

    if [[ "${SHOW_HELP}" == "true" ]]; then
        show_help
        exit 0
    fi

    log "=== Sigul Infrastructure Deployment ==="
    if [[ "$LOCAL_DEBUG_MODE" == "true" ]]; then
        warn "🔧 --- LOCAL DEBUGGING MODE ENABLED ---"
        warn "   Infrastructure will persist for troubleshooting"
        warn "   Use 'docker compose -f docker-compose.sigul.yml down -v' to cleanup"
        echo
    fi
    log "Verbose mode: $VERBOSE_MODE"
    log "Debug mode: $DEBUG_MODE"
    log "Local debug mode: $LOCAL_DEBUG_MODE"
    log "Project root: $PROJECT_ROOT"
    log "Runner platform: ${SIGUL_RUNNER_PLATFORM:-auto-detect}"
    log "Docker platform: ${SIGUL_DOCKER_PLATFORM:-auto-detect}"

    # Ensure we're in the correct directory
    cd "$PROJECT_ROOT"

    # Run deployment with comprehensive error handling
    if deploy_infrastructure; then
        success "=== Deployment Completed Successfully ==="
        exit 0
    else
        error "=== Deployment Failed ==="

        # Stream container logs immediately for visibility
        stream_container_logs_on_failure "sigul-server"
        stream_container_logs_on_failure "sigul-bridge"

        # Collect detailed diagnostics
        collect_nss_failure_diagnostics

        error "Check the logs above for specific error details"
        error "Consider running with --debug flag for more detailed output"

        exit 1
    fi
}

# Stream container logs on failure for immediate visibility
stream_container_logs_on_failure() {
    local container_name="$1"

    if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
        log "Streaming logs for failed container: $container_name"
        echo "::group::${container_name} container logs (failure dump)"
        docker logs "$container_name" 2>&1 | tail -200 || echo "Unable to fetch logs from $container_name"
        echo "::endgroup::"

        # Also show container status
        local status
        status=$(docker container inspect "$container_name" --format '{{.State.Status}} (exit: {{.State.ExitCode}})' 2>/dev/null || echo 'not found')
        error "Container $container_name final status: $status"
    else
        error "Container $container_name not found for log streaming"
    fi
}

# Collect NSS failure diagnostics on deployment failure
collect_nss_failure_diagnostics() {
    log "Collecting NSS failure diagnostics..."

    local nss_diagnostics_dir="${PROJECT_ROOT}/test-artifacts/nss-diagnostics"
    local container_diagnostics_dir="${PROJECT_ROOT}/test-artifacts/container-diagnostics"

    # Create diagnostics directories
    mkdir -p "$nss_diagnostics_dir" "$container_diagnostics_dir"

    # Collect NSS diagnostic files from containers
    for container in sigul-server sigul-bridge; do
        if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            log "Collecting NSS diagnostics from container: $container"

            # Copy NSS diagnostic files from container if they exist
            docker exec "$container" find /var/sigul -name "*.stderr" -o -name "*nss-import-summary*" 2>/dev/null | while IFS= read -r file; do
                if [[ -n "$file" ]]; then
                    local basename_file
                    basename_file=$(basename "$file")
                    docker cp "$container:$file" "$nss_diagnostics_dir/${container}-${basename_file}" 2>/dev/null || true
                fi
            done

            # Get current NSS database state
            docker exec "$container" sh -c '
                echo "=== NSS Database State for $(hostname) ==="
                echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                echo ""
                for role_dir in /var/sigul/nss/*; do
                    if [[ -d "$role_dir" ]]; then
                        role=$(basename "$role_dir")
                        echo "Role: $role"
                        echo "NSS Directory: $role_dir"
                        ls -la "$role_dir" 2>/dev/null || echo "Cannot list NSS directory"
                        echo ""
                    fi
                done

                echo "=== Certificate Files ==="
                find /var/sigul/secrets/certificates -name "*.crt" -o -name "*.pem" 2>/dev/null | while IFS= read -r cert; do
                    if [[ -f "$cert" ]]; then
                        echo "Certificate: $cert"
                        echo "  Size: $(stat -c%s "$cert" 2>/dev/null || echo unknown) bytes"
                        echo "  Permissions: $(stat -c%a "$cert" 2>/dev/null || echo unknown)"
                    fi
                done
            ' > "$container_diagnostics_dir/${container}-nss-state.txt" 2>&1 || true

            # Collect recent container logs with NSS context
            docker logs --tail 100 "$container" > "$container_diagnostics_dir/${container}-recent-logs.txt" 2>&1 || true
        fi
    done

    # Generate summary of collected diagnostics
    {
        echo "=== NSS Failure Diagnostics Summary ==="
        echo "Collected at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Project root: $PROJECT_ROOT"
        echo ""

        echo "=== NSS Diagnostic Files ==="
        if [[ -d "$nss_diagnostics_dir" ]]; then
            find "$nss_diagnostics_dir" -type f | while IFS= read -r file; do
                echo "File: $(basename "$file")"
                echo "  Size: $(stat -c%s "$file" 2>/dev/null || echo unknown) bytes"
                if [[ -s "$file" ]]; then
                    echo "  First few lines:"
                    head -3 "$file" 2>/dev/null | sed 's/^/    /' || echo "    (unable to read)"
                fi
                echo ""
            done
        else
            echo "No NSS diagnostics directory found"
        fi

        echo "=== Container Diagnostic Files ==="
        if [[ -d "$container_diagnostics_dir" ]]; then
            find "$container_diagnostics_dir" -type f | while IFS= read -r file; do
                echo "File: $(basename "$file")"
                echo "  Size: $(stat -c%s "$file" 2>/dev/null || echo unknown) bytes"
            done
        else
            echo "No container diagnostics directory found"
        fi
    } > "${PROJECT_ROOT}/test-artifacts/nss-failure-summary.txt"

    log "NSS failure diagnostics collected in: ${PROJECT_ROOT}/test-artifacts/"
    error "Key diagnostic files:"
    error "  - NSS diagnostics: test-artifacts/nss-diagnostics/"
    error "  - Container states: test-artifacts/container-diagnostics/"
    error "  - Summary: test-artifacts/nss-failure-summary.txt"
}

# Execute main function with all arguments
main "$@"
