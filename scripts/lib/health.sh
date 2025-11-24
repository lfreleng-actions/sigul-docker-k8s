#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# NSS Health Check Library for Sigul Infrastructure
#
# This library provides clean, focused NSS health check functions
# for certificate validation and monitoring.
#
# Key Design Principles:
# - NSS certificate validation
# - Fast execution for monitoring and health checks
# - Simple pass/fail results without complex error handling
# - Minimal dependencies (only certutil and basic shell tools)
#
# Usage:
#   source scripts/lib/health.sh
#   nss_health_check_bridge
#   nss_health_check_server
#   nss_health_check_client
#   nss_health_check_all

# Prevent multiple sourcing
if [[ "${SIGUL_NSS_HEALTH_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly SIGUL_NSS_HEALTH_LIB_LOADED="true"

# Library version
readonly SIGUL_NSS_HEALTH_LIB_VERSION="1.0.0"

# Health status constants
readonly NSS_HEALTH_OK="OK"
readonly NSS_HEALTH_FAIL="FAIL"

# Configuration
readonly NSS_BASE_DIR="${NSS_DIR:-/var/sigul/nss}"
readonly SECRETS_DIR="${SECRETS_DIR:-/var/sigul/secrets}"

# Colors for output (if terminal supports it)
if [[ -t 1 ]]; then
    readonly NSS_RED='\033[0;31m'
    readonly NSS_GREEN='\033[0;32m'
    readonly NSS_YELLOW='\033[1;33m'
    readonly NSS_BLUE='\033[0;34m'
    readonly NSS_NC='\033[0m'
else
    readonly NSS_RED=''
    readonly NSS_GREEN=''
    readonly NSS_YELLOW=''
    readonly NSS_BLUE=''
    readonly NSS_NC=''
fi

#######################################
# Simple logging functions
#######################################

nss_log() {
    echo -e "${NSS_BLUE}[NSS-HEALTH]${NSS_NC} $*"
}

nss_success() {
    echo -e "${NSS_GREEN}[NSS-HEALTH] ✅${NSS_NC} $*"
}

nss_error() {
    echo -e "${NSS_RED}[NSS-HEALTH] ❌${NSS_NC} $*"
}

nss_warn() {
    echo -e "${NSS_YELLOW}[NSS-HEALTH] ⚠️${NSS_NC} $*"
}

#######################################
# Core NSS health check functions
#######################################

# Check if NSS database exists and is accessible
nss_database_exists() {
    local component="$1"
    local nss_dir="$NSS_BASE_DIR/$component"

    # Check directory exists
    [[ -d "$nss_dir" ]] || return 1

    # Check required NSS files exist
    [[ -f "$nss_dir/cert9.db" ]] || return 1
    [[ -f "$nss_dir/key4.db" ]] || return 1
    [[ -f "$nss_dir/pkcs11.txt" ]] || return 1

    return 0
}

# Check if certificate exists in NSS database
nss_certificate_exists() {
    local component="$1"
    local cert_nickname="$2"
    local nss_dir="$NSS_BASE_DIR/$component"

    # Quick check - does certificate exist?
    certutil -d "sql:$nss_dir" -L -n "$cert_nickname" >/dev/null 2>&1
}

# Simple health check for bridge component
nss_health_check_bridge() {
    local result="$NSS_HEALTH_OK"

    # Check NSS database
    if ! nss_database_exists "bridge"; then
        nss_error "Bridge NSS database missing or invalid"
        result="$NSS_HEALTH_FAIL"
    fi

    # Check CA certificate (bridge acts as CA)
    if ! nss_certificate_exists "bridge" "sigul-ca"; then
        nss_error "Bridge CA certificate missing"
        result="$NSS_HEALTH_FAIL"
    fi

    # Check bridge service certificate
    if ! nss_certificate_exists "bridge" "sigul-bridge-cert"; then
        nss_error "Bridge service certificate missing"
        result="$NSS_HEALTH_FAIL"
    fi

    if [[ "$result" == "$NSS_HEALTH_OK" ]]; then
        nss_success "Bridge NSS health check passed"
    else
        nss_error "Bridge NSS health check failed"
    fi

    if [[ "$result" == "$NSS_HEALTH_OK" ]]; then
        return 0
    else
        return 1
    fi
}

# Simple health check for server component
nss_health_check_server() {
    local result="$NSS_HEALTH_OK"

    # Check NSS database
    if ! nss_database_exists "server"; then
        nss_error "Server NSS database missing or invalid"
        result="$NSS_HEALTH_FAIL"
    fi

    # Check CA certificate (to trust bridge)
    if ! nss_certificate_exists "server" "sigul-ca"; then
        nss_error "Server CA certificate missing"
        result="$NSS_HEALTH_FAIL"
    fi

    # Check server service certificate
    if ! nss_certificate_exists "server" "sigul-server-cert"; then
        nss_error "Server service certificate missing"
        result="$NSS_HEALTH_FAIL"
    fi

    if [[ "$result" == "$NSS_HEALTH_OK" ]]; then
        nss_success "Server NSS health check passed"
    else
        nss_error "Server NSS health check failed"
    fi

    if [[ "$result" == "$NSS_HEALTH_OK" ]]; then
        return 0
    else
        return 1
    fi
}

# Simple health check for client component
nss_health_check_client() {
    local result="$NSS_HEALTH_OK"

    # Check NSS database
    if ! nss_database_exists "client"; then
        nss_error "Client NSS database missing or invalid"
        result="$NSS_HEALTH_FAIL"
    fi

    # Check CA certificate (to trust bridge)
    if ! nss_certificate_exists "client" "sigul-ca"; then
        nss_error "Client CA certificate missing"
        result="$NSS_HEALTH_FAIL"
    fi

    # Check client certificate
    if ! nss_certificate_exists "client" "sigul-client-cert"; then
        nss_error "Client certificate missing"
        result="$NSS_HEALTH_FAIL"
    fi

    if [[ "$result" == "$NSS_HEALTH_OK" ]]; then
        nss_success "Client NSS health check passed"
    else
        nss_error "Client NSS health check failed"
    fi

    if [[ "$result" == "$NSS_HEALTH_OK" ]]; then
        return 0
    else
        return 1
    fi
}

# Health check for all components
nss_health_check_all() {
    local overall_result=0

    nss_log "Running NSS health checks for all components"

    # Bridge health check
    if ! nss_health_check_bridge; then
        overall_result=1
    fi

    # Server health check
    if ! nss_health_check_server; then
        overall_result=1
    fi

    # Client health check
    if ! nss_health_check_client; then
        overall_result=1
    fi

    if [[ $overall_result -eq 0 ]]; then
        nss_success "All NSS health checks passed"
    else
        nss_error "One or more NSS health checks failed"
    fi

    return $overall_result
}

#######################################
# Docker health check integration
#######################################

# Docker-compatible health check for bridge
nss_docker_health_bridge() {
    if nss_database_exists "bridge" && \
       nss_certificate_exists "bridge" "sigul-ca" && \
       nss_certificate_exists "bridge" "sigul-bridge-cert"; then
        echo "healthy"
        return 0
    else
        echo "unhealthy"
        return 1
    fi
}

# Docker-compatible health check for server
nss_docker_health_server() {
    if nss_database_exists "server" && \
       nss_certificate_exists "server" "sigul-ca" && \
       nss_certificate_exists "server" "sigul-server-cert"; then
        echo "healthy"
        return 0
    else
        echo "unhealthy"
        return 1
    fi
}

# Docker-compatible health check for client
nss_docker_health_client() {
    if nss_database_exists "client" && \
       nss_certificate_exists "client" "sigul-ca" && \
       nss_certificate_exists "client" "sigul-client-cert"; then
        echo "healthy"
        return 0
    else
        echo "unhealthy"
        return 1
    fi
}

#######################################
# Utility functions
#######################################

# Get current NSS certificate count for component
nss_get_cert_count() {
    local component="$1"
    local nss_dir="$NSS_BASE_DIR/$component"

    if [[ -d "$nss_dir" ]]; then
        certutil -d "sql:$nss_dir" -L 2>/dev/null | grep -c "^[[:space:]]*[^[:space:]]" || echo "0"
    else
        echo "0"
    fi
}

# Quick status check (for monitoring scripts)
nss_quick_status() {
    local component="$1"
    case "$component" in
        "bridge")
            nss_docker_health_bridge >/dev/null 2>&1 && echo "UP" || echo "DOWN"
            ;;
        "server")
            nss_docker_health_server >/dev/null 2>&1 && echo "UP" || echo "DOWN"
            ;;
        "client")
            nss_docker_health_client >/dev/null 2>&1 && echo "UP" || echo "DOWN"
            ;;
        *)
            echo "UNKNOWN"
            return 1
            ;;
    esac
}

# Print library info
nss_health_lib_info() {
    nss_log "NSS Health Check Library v$SIGUL_NSS_HEALTH_LIB_VERSION"
    nss_log "NSS Base Directory: $NSS_BASE_DIR"
    nss_log "Secrets Directory: $SECRETS_DIR"
    nss_log "Available functions:"
    nss_log "  - nss_health_check_bridge"
    nss_log "  - nss_health_check_server"
    nss_log "  - nss_health_check_client"
    nss_log "  - nss_health_check_all"
    nss_log "  - nss_docker_health_*"
}

#######################################
# Docker component health check
#######################################

# Check component health and return JSON with container and NSS status
check_component_health() {
    local component="$1"
    local container_name="sigul-${component}"

    # Get container status using docker inspect
    local container_json
    container_json=$(docker inspect "$container_name" 2>/dev/null || echo '[]')

    # Extract container status fields
    local status running restart_count exit_code
    status=$(echo "$container_json" | jq -r '.[0].State.Status // "unknown"')
    running=$(echo "$container_json" | jq -r '.[0].State.Running // false')
    restart_count=$(echo "$container_json" | jq -r '.[0].RestartCount // 0')
    exit_code=$(echo "$container_json" | jq -r '.[0].State.ExitCode // 0')

    # Check port reachability for bridge
    local port_reachable="false"
    if [[ "$component" == "bridge" ]] && [[ "$running" == "true" ]]; then
        if timeout 2 bash -c "</dev/tcp/localhost/44334" 2>/dev/null; then
            port_reachable="true"
        fi
    fi

    # Get NSS certificate information if container is running
    local nss_certs='[]'
    local nss_missing='[]'

    if [[ "$running" == "true" ]]; then
        # Get list of certificates from NSS database
        local cert_list
        cert_list=$(docker exec "$container_name" certutil -d "sql:/var/lib/sigul/${component}/nss" -L 2>/dev/null | tail -n +4 | awk '{print $1}' | grep -v "^$" || echo "")

        if [[ -n "$cert_list" ]]; then
            nss_certs=$(echo "$cert_list" | jq -R -s 'split("\n") | map(select(length > 0))')
        fi

        # Check for expected certificates based on component
        case "$component" in
            "bridge")
                if ! echo "$cert_list" | grep -q "sigul-bridge-cert"; then
                    nss_missing='["sigul-bridge-cert"]'
                fi
                ;;
            "server")
                if ! echo "$cert_list" | grep -q "sigul-server-cert"; then
                    nss_missing='["sigul-server-cert"]'
                fi
                ;;
        esac
    else
        # Container not running, all certs are missing
        case "$component" in
            "bridge")
                nss_missing='["sigul-bridge-cert"]'
                ;;
            "server")
                nss_missing='["sigul-server-cert"]'
                ;;
        esac
    fi

    # Build JSON response
    cat <<EOF
{
  "containerStatus": {
    "status": "$status",
    "running": $running,
    "restartCount": $restart_count,
    "exitCode": $exit_code
  },
  "portStatus": {
    "reachable": $port_reachable
  },
  "nssMetadata": {
    "certificates": $nss_certs,
    "missingCertificates": $nss_missing
  }
}
EOF
}

# Export functions for use in other scripts
export -f nss_log nss_success nss_error nss_warn
export -f nss_database_exists nss_certificate_exists
export -f nss_health_check_bridge nss_health_check_server nss_health_check_client nss_health_check_all
export -f nss_docker_health_bridge nss_docker_health_server nss_docker_health_client
export -f nss_get_cert_count nss_quick_status nss_health_lib_info
export -f check_component_health

nss_log "NSS Health Check Library loaded (version $SIGUL_NSS_HEALTH_LIB_VERSION)"
