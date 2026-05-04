#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Bridge Entrypoint
#
# This script provides the entrypoint for the Sigul bridge container.
# It validates prerequisites and starts the bridge process with proper logging.
#
# Logging Configuration:
#   All bridge processes are started with -vv (DEBUG level) for maximum visibility.
#   This ensures logs are available in both console (docker logs) and file (/var/log/sigul_bridge.log).
#   For production, consider changing to -v (INFO level) to reduce log volume.
#
# Process Management:
#   - Normal mode: Uses 'exec' to replace entrypoint with bridge process (PID 1)
#   - Debug mode: Forks bridge and monitors it (set DEBUG_MODE=1)
#
# Key Design Principles:
# - Minimal wrapper logic
# - Direct service invocation with full logging
# - Fast startup with essential validation
# - Clear, actionable error messages

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# FHS-compliant paths
readonly CONFIG_FILE="/etc/sigul/bridge.conf"
readonly NSS_DIR="/etc/pki/sigul/bridge"

# Runtime directories that need permission fixes
readonly RUN_DIR="/var/run"
readonly LOG_DIR="/var/log/sigul/bridge"

# User to run sigul process as
readonly SIGUL_USER="sigul"
readonly SIGUL_UID=990
readonly SIGUL_GID=987

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] BRIDGE:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] BRIDGE:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] BRIDGE:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] BRIDGE:${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

#######################################
# Pre-flight Validation
#######################################

validate_configuration() {
    log "Validating bridge configuration..."

    # Check configuration file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        fatal "Configuration not found at $CONFIG_FILE"
    fi

    # Verify configuration is readable
    if [ ! -r "$CONFIG_FILE" ]; then
        fatal "Configuration file $CONFIG_FILE is not readable"
    fi

    success "Configuration file validated"
}

validate_nss_database() {
    log "Validating NSS database..."

    # Check NSS directory exists
    if [ ! -d "$NSS_DIR" ]; then
        fatal "NSS database directory not found at $NSS_DIR"
    fi

    # Check for cert9.db (modern NSS format)
    if [ ! -f "$NSS_DIR/cert9.db" ]; then
        error "NSS database not found at $NSS_DIR/cert9.db"
        error ""
        error "This typically means the cert-init container did not run successfully."
        error "Please check:"
        error "  1. The cert-init container completed successfully"
        error "  2. Environment variable NSS_PASSWORD is set"
        error "  3. Volumes are properly mounted"
        error ""
        error "To force certificate regeneration, use:"
        error "  CERT_INIT_MODE=force docker compose up"
        fatal "Cannot start bridge without certificates"
    fi

    success "NSS database validated"
}

validate_certificate() {
    log "Validating bridge certificate..."

    # Extract certificate nickname from configuration
    local cert_nickname
    if ! cert_nickname=$(grep "^bridge-cert-nickname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        fatal "Cannot extract bridge-cert-nickname from configuration"
    fi

    if [ -z "$cert_nickname" ]; then
        fatal "Bridge certificate nickname not configured in $CONFIG_FILE"
    fi

    # Verify certificate exists in NSS database
    if ! certutil -L -d "sql:$NSS_DIR" -n "$cert_nickname" &>/dev/null; then
        error "Certificate '$cert_nickname' not found in NSS database"
        error ""
        error "Available certificates in database:"
        certutil -L -d "sql:$NSS_DIR" | tail -n +4 | awk '{print "  - " $1}' 2>/dev/null || echo "  (none)"
        error ""
        error "This suggests the cert-init container ran but certificate generation failed."
        error "Try regenerating certificates with:"
        error "  CERT_INIT_MODE=force docker compose up"
        fatal "Required certificate missing"
    fi

    success "Bridge certificate '$cert_nickname' validated"
}

validate_ca_certificate() {
    log "Validating CA certificate..."

    # Extract CA nickname from configuration
    local ca_nickname
    if ! ca_nickname=$(grep "^bridge-ca-cert-nickname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        warn "Cannot extract bridge-ca-cert-nickname from configuration, assuming 'sigul-ca'"
        ca_nickname="sigul-ca"
    fi

    if [ -z "$ca_nickname" ]; then
        ca_nickname="sigul-ca"
    fi

    # Verify CA certificate exists in NSS database
    if ! certutil -L -d "sql:$NSS_DIR" -n "$ca_nickname" &>/dev/null; then
        error "CA certificate '$ca_nickname' not found in NSS database"
        error ""
        error "The CA certificate is essential for TLS trust between components."
        error "This suggests incomplete certificate initialization."
        error "Try regenerating certificates with:"
        error "  CERT_INIT_MODE=force docker compose up"
        fatal "CA certificate is required for TLS trust"
    fi

    success "CA certificate '$ca_nickname' validated"
}

#######################################
# Permission Fixing
#######################################

fix_volume_permissions() {
    log "Fixing volume permissions for runtime directories..."

    # Check if running as root (required to fix permissions)
    if [ "$(id -u)" -ne 0 ]; then
        warn "Not running as root - cannot fix volume permissions"
        warn "Container should start as root to fix Docker volume ownership"
        return
    fi

    # Fix ownership of /var/run (Docker creates volumes as root by default)
    if [ -d "$RUN_DIR" ]; then
        log "Fixing ownership of $RUN_DIR..."
        chown -R ${SIGUL_UID}:${SIGUL_GID} "$RUN_DIR" || warn "Failed to chown $RUN_DIR"
        chmod 755 "$RUN_DIR" || warn "Failed to chmod $RUN_DIR"
        success "Fixed ownership of $RUN_DIR"
    else
        warn "Runtime directory $RUN_DIR does not exist"
    fi

    # Fix ownership of /var/log/sigul/bridge (for log files)
    if [ -d "$LOG_DIR" ]; then
        log "Fixing ownership of $LOG_DIR..."
        chown -R ${SIGUL_UID}:${SIGUL_GID} "$LOG_DIR" || warn "Failed to chown $LOG_DIR"
        chmod 755 "$LOG_DIR" || warn "Failed to chmod $LOG_DIR"
        success "Fixed ownership of $LOG_DIR"
    else
        # Create if missing
        log "Creating log directory $LOG_DIR..."
        mkdir -p "$LOG_DIR"
        chown -R ${SIGUL_UID}:${SIGUL_GID} "$LOG_DIR"
        chmod 755 "$LOG_DIR"
        success "Created and configured $LOG_DIR"
    fi

    success "Volume permissions fixed successfully"
}

#######################################
# Service Startup
#######################################

start_bridge_service() {
    log "Starting Sigul Bridge service..."
    log "Command: /usr/sbin/sigul_bridge -c $CONFIG_FILE -vv"
    log "Configuration: $CONFIG_FILE"
    log "Logging: DEBUG level (verbose mode enabled)"

    success "Bridge initialized successfully"

    # Check if we're running as root and need to drop privileges
    if [ "$(id -u)" -eq 0 ]; then
        log "Running as root - will drop privileges to user $SIGUL_USER (UID $SIGUL_UID)"

        # Check if DEBUG_MODE is enabled
        if [[ "${DEBUG_MODE:-0}" == "1" ]]; then
            warn "DEBUG_MODE enabled - entrypoint will monitor sigul process"
            # Use su to drop privileges in debug mode
            exec su -s /bin/bash "$SIGUL_USER" -c "$(declare -f start_bridge_service_debug); start_bridge_service_debug"
        else
            # Drop privileges and exec sigul_bridge
            # Using exec with su to replace shell process with bridge process (becomes PID 1)
            #
            # Logging: -vv enables DEBUG level logging
            #   - Without flags: WARNING level only (errors/warnings)
            #   - With -v: INFO level (informational messages)
            #   - With -vv: DEBUG level (all messages including debug)
            #
            # Output goes to both:
            #   - Console (stdout/stderr) - captured by 'docker logs'
            #   - Log file (/var/log/sigul_bridge.log)
            exec su -s /bin/bash "$SIGUL_USER" -c "exec /usr/sbin/sigul_bridge -c $CONFIG_FILE -vv"
        fi
    else
        # Already running as non-root user
        log "Running as user $(id -un) (UID $(id -u))"

        # Check if DEBUG_MODE is enabled
        if [[ "${DEBUG_MODE:-0}" == "1" ]]; then
            warn "DEBUG_MODE enabled - entrypoint will monitor sigul process"
            start_bridge_service_debug
        else
            exec /usr/sbin/sigul_bridge \
                -c "$CONFIG_FILE" \
                -vv
        fi
    fi
}

start_bridge_service_debug() {
    log "Starting bridge in DEBUG mode (monitoring enabled)"
    log "Entrypoint will remain active to monitor the process"

    # Start sigul_bridge in background and capture its PID
    # -vv enables DEBUG level logging (same as normal mode)
    /usr/sbin/sigul_bridge \
        -c "$CONFIG_FILE" \
        -vv &

    local sigul_pid=$!
    log "Bridge process started with PID: $sigul_pid"

    # Set up signal forwarding
    # shellcheck disable=SC2064  # Variable expansion intentional - captures PID at trap setup
    trap "log 'Received SIGTERM, forwarding to bridge (PID $sigul_pid)'; kill -TERM $sigul_pid 2>/dev/null" TERM
    # shellcheck disable=SC2064  # Variable expansion intentional - captures PID at trap setup
    trap "log 'Received SIGINT, forwarding to bridge (PID $sigul_pid)'; kill -INT $sigul_pid 2>/dev/null" INT

    # Monitor the process
    log "Monitoring bridge process..."
    log "Log file: /var/log/sigul_bridge.log"
    log "=========================================="

    # Tail the log file in background
    if [[ -f "/var/log/sigul_bridge.log" ]]; then
        tail -f /var/log/sigul_bridge.log &
        local tail_pid=$!
    fi

    # Wait for the sigul process and capture exit code
    local exit_code=0
    if wait $sigul_pid; then
        exit_code=$?
        log "Bridge process exited normally with code: $exit_code"
    else
        exit_code=$?
        error "Bridge process exited with error code: $exit_code"
    fi

    # Clean up tail process
    if [[ -n "${tail_pid:-}" ]]; then
        kill "$tail_pid" 2>/dev/null || true
    fi

    # Show final log entries
    log "=========================================="
    log "Final log entries:"
    if [[ -f "/var/log/sigul_bridge.log" ]]; then
        tail -20 /var/log/sigul_bridge.log | while IFS= read -r line; do
            echo "  $line"
        done
    else
        error "Log file not found at /var/log/sigul_bridge.log"
    fi

    exit $exit_code
}

#######################################
# Main Entrypoint
#######################################

main() {
    log "Sigul Bridge Entrypoint"
    log "=============================================="

    if [[ "${DEBUG_MODE:-0}" == "1" ]]; then
        warn "DEBUG_MODE=1 detected"
        warn "Entrypoint will fork sigul process and monitor it"
        warn "This is useful for debugging but NOT recommended for production"
    fi

    # Run pre-flight validation
    validate_configuration
    validate_nss_database
    validate_certificate
    validate_ca_certificate

    # Fix volume permissions (must be done as root)
    fix_volume_permissions

    # Start the service (will drop privileges if running as root)
    start_bridge_service
}

# Execute main function
main "$@"
