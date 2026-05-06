#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Server Entrypoint
#
# This script provides the entrypoint for the Sigul server container.
# It validates prerequisites and starts the server process with proper logging.
#
# Logging Configuration:
#   All server processes are started with -vv (DEBUG level) for maximum visibility.
#   This ensures logs are available in both console (docker logs) and file (/var/log/sigul_server.log).
#   For production, consider changing to -v (INFO level) to reduce log volume.
#
# Process Management:
#   - Normal mode: Uses 'exec' to replace entrypoint with server process (PID 1)
#   - Debug mode: Forks server and monitors it (set DEBUG_MODE=1)
#
# Key Design Principles:
# - Minimal wrapper logic
# - Direct service invocation with full logging
# - Fast startup with essential validation
# - Clear, actionable error messages
# - Wait for bridge availability before starting

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# FHS-compliant paths
readonly CONFIG_FILE="/etc/sigul/server.conf"
readonly NSS_DIR="/etc/pki/sigul/server"
readonly DATA_DIR="/var/lib/sigul"
readonly SERVER_DATA_DIR="/var/lib/sigul/server"
readonly GNUPG_DIR="$SERVER_DATA_DIR/gnupg"

# Runtime directories that need permission fixes
readonly RUN_DIR="/var/run"
readonly LOG_DIR="/var/log/sigul/server"

# User to run sigul process as
readonly SIGUL_USER="sigul"
readonly SIGUL_UID=990
readonly SIGUL_GID=987

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] SERVER:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SERVER:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] SERVER:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] SERVER:${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

#######################################
# Bridge Availability Check
#######################################

wait_for_bridge() {
    log "Checking bridge availability..."

    # Extract bridge hostname and port from configuration
    local bridge_hostname bridge_port

    if ! bridge_hostname=$(grep "^bridge-hostname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        fatal "Cannot extract bridge-hostname from configuration"
    fi

    if ! bridge_port=$(grep "^bridge-port:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        fatal "Cannot extract bridge-port from configuration"
    fi

    if [ -z "$bridge_hostname" ]; then
        fatal "Bridge hostname not configured in $CONFIG_FILE"
    fi

    if [ -z "$bridge_port" ]; then
        fatal "Bridge port not configured in $CONFIG_FILE"
    fi

    log "Waiting for bridge at ${bridge_hostname}:${bridge_port}..."

    local max_wait=60
    local elapsed=0

    while ! nc -z "$bridge_hostname" "$bridge_port" 2>/dev/null; do
        if [ $elapsed -ge $max_wait ]; then
            error "Bridge not available after ${max_wait} seconds"
            error "Bridge hostname: $bridge_hostname"
            error "Bridge port: $bridge_port"
            fatal "Cannot connect to bridge"
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    success "Bridge is available at ${bridge_hostname}:${bridge_port}"
}

#######################################
# Pre-flight Validation
#######################################

validate_configuration() {
    log "Validating server configuration..."

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
        fatal "Cannot start server without certificates"
    fi

    success "NSS database validated"
}

validate_certificate() {
    log "Validating server certificate..."

    # Extract certificate nickname from configuration
    local cert_nickname
    if ! cert_nickname=$(grep "^server-cert-nickname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        fatal "Cannot extract server-cert-nickname from configuration"
    fi

    if [ -z "$cert_nickname" ]; then
        fatal "Server certificate nickname not configured in $CONFIG_FILE"
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

    success "Server certificate '$cert_nickname' validated"
}

validate_ca_certificate() {
    log "Validating CA certificate..."

    # Extract CA nickname from configuration
    local ca_nickname
    if ! ca_nickname=$(grep "^server-ca-cert-nickname:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        warn "Cannot extract server-ca-cert-nickname from configuration, assuming 'sigul-ca'"
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

initialize_gnupg_directory() {
    log "Initializing GnuPG directory..."

    if [ ! -d "$GNUPG_DIR" ]; then
        log "Creating GnuPG directory at $GNUPG_DIR"
        mkdir -p "$GNUPG_DIR"
        chmod 700 "$GNUPG_DIR"
        success "GnuPG directory created"
    else
        log "GnuPG directory already exists"
    fi
}

initialize_directories() {
    log "Initializing runtime directories..."

    # Ensure data directory exists
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR"
        chmod 755 "$DATA_DIR"
    fi

    # Ensure server data directory exists
    if [ ! -d "$SERVER_DATA_DIR" ]; then
        log "Creating server data directory at $SERVER_DATA_DIR"
        mkdir -p "$SERVER_DATA_DIR"
        chmod 755 "$SERVER_DATA_DIR"
    fi

    success "Runtime directories initialized"
}

initialize_database() {
    log "Initializing database..."

    # Extract database path from configuration
    local db_path
    if ! db_path=$(grep "^database-path:" "$CONFIG_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' '); then
        warn "Cannot extract database-path from configuration, using default"
        db_path="/var/lib/sigul/server.sqlite"
    fi

    if [ -z "$db_path" ]; then
        warn "Database path not configured, using default"
        db_path="/var/lib/sigul/server.sqlite"
    fi

    log "Database path: $db_path"

    # Ensure database directory exists
    local db_dir
    db_dir=$(dirname "$db_path")
    if [ ! -d "$db_dir" ]; then
        log "Creating database directory at $db_dir"
        mkdir -p "$db_dir"
        chmod 755 "$db_dir"
    fi

    # Check if database needs initialization
    if [ ! -f "$db_path" ] || [ ! -s "$db_path" ]; then
        log "Database does not exist or is empty - initializing schema..."

        # Run database creation script
        if ! sigul_server_create_db -c "$CONFIG_FILE"; then
            fatal "Failed to create database schema"
        fi

        success "Database schema created successfully"

        # Verify schema was actually created
        if command -v sqlite3 &>/dev/null; then
            local table_count
            table_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
            if [ "$table_count" -gt 0 ]; then
                log "Database schema verified: $table_count tables created"
            else
                fatal "Database schema initialization failed - no tables created"
            fi
        else
            warn "sqlite3 not available - cannot verify database schema"
        fi

        # Create admin user if credentials are provided
        if [ -n "${SIGUL_ADMIN_USER:-}" ] && [ -n "${SIGUL_ADMIN_PASSWORD:-}" ]; then
            log "Creating admin user: ${SIGUL_ADMIN_USER}"

            # Use printf with NUL terminator for batch mode
            # In batch mode, sigul_server_add_admin expects NUL-terminated password (only once)
            if ! printf "%s\0" "$SIGUL_ADMIN_PASSWORD" | \
                sigul_server_add_admin --batch -c "$CONFIG_FILE" -n "$SIGUL_ADMIN_USER"; then
                warn "Failed to create admin user - you may need to create it manually"
            else
                success "Admin user '$SIGUL_ADMIN_USER' created successfully"
            fi
        else
            warn "SIGUL_ADMIN_USER or SIGUL_ADMIN_PASSWORD not set"
            warn "No admin user created - you will need to create one manually with:"
            warn "  docker exec -it sigul-server sigul_server_add_admin -c /etc/sigul/server.conf"
        fi
    else
        log "Database already initialized"

        # Verify database has tables (basic sanity check)
        if command -v sqlite3 &>/dev/null; then
            local table_count
            table_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
            if [ "$table_count" -gt 0 ]; then
                log "Database contains $table_count tables"
            else
                warn "Database file exists but appears empty - may need reinitialization"
            fi
        fi
    fi
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

    # Fix ownership of /var/log/sigul/server (for log files)
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

    # Fix ownership of /run/sigul/server (runtime state files)
    local run_sigul_dir="/run/sigul/server"
    if [ -d "$run_sigul_dir" ]; then
        log "Fixing ownership of $run_sigul_dir..."
        chown -R ${SIGUL_UID}:${SIGUL_GID} "$run_sigul_dir" || warn "Failed to chown $run_sigul_dir"
        chmod 755 "$run_sigul_dir" || warn "Failed to chmod $run_sigul_dir"
        success "Fixed ownership of $run_sigul_dir"
    fi

    # Fix ownership of server data directory
    if [ -d "$SERVER_DATA_DIR" ]; then
        log "Fixing ownership of $SERVER_DATA_DIR..."
        chown -R ${SIGUL_UID}:${SIGUL_GID} "$SERVER_DATA_DIR" || warn "Failed to chown $SERVER_DATA_DIR"
        success "Fixed ownership of $SERVER_DATA_DIR"
    fi

    # Fix ownership of GnuPG directory if it exists
    if [ -d "$GNUPG_DIR" ]; then
        log "Fixing ownership of $GNUPG_DIR..."
        chown -R ${SIGUL_UID}:${SIGUL_GID} "$GNUPG_DIR" || warn "Failed to chown $GNUPG_DIR"
        chmod 700 "$GNUPG_DIR" || warn "Failed to chmod $GNUPG_DIR"
        success "Fixed ownership of $GNUPG_DIR"
    fi

    success "Volume permissions fixed successfully"
}

#######################################
# Service Startup
#######################################

start_server_service() {
    log "Starting Sigul Server service..."
    log "Command: /usr/sbin/sigul_server -c $CONFIG_FILE -vv"
    log "Configuration: $CONFIG_FILE"
    log "Logging: DEBUG level (verbose mode enabled)"

    success "Server initialized successfully"

    # Check if we're running as root and need to drop privileges
    if [ "$(id -u)" -eq 0 ]; then
        log "Running as root - will drop privileges to user $SIGUL_USER (UID $SIGUL_UID)"

        # Check if DEBUG_MODE is enabled
        if [[ "${DEBUG_MODE:-0}" == "1" ]]; then
            warn "DEBUG_MODE enabled - entrypoint will monitor sigul process"
            # Use su to drop privileges in debug mode
            exec su -s /bin/bash "$SIGUL_USER" -c "$(declare -f start_server_service_debug); start_server_service_debug"
        else
            # Drop privileges and exec sigul_server
            # Using exec with su to replace shell process with server process (becomes PID 1)
            #
            # Logging: -vv enables DEBUG level logging
            #   - Without flags: WARNING level only (errors/warnings)
            #   - With -v: INFO level (informational messages)
            #   - With -vv: DEBUG level (all messages including debug)
            #
            # Output goes to both:
            #   - Console (stdout/stderr) - captured by 'docker logs'
            #   - Log file (/var/log/sigul_server.log)
            exec su -s /bin/bash "$SIGUL_USER" -c "exec /usr/sbin/sigul_server -c $CONFIG_FILE -vv"
        fi
    else
        # Already running as non-root user
        log "Running as user $(id -un) (UID $(id -u))"

        # Check if DEBUG_MODE is enabled
        if [[ "${DEBUG_MODE:-0}" == "1" ]]; then
            warn "DEBUG_MODE enabled - entrypoint will monitor sigul process"
            start_server_service_debug
        else
            exec /usr/sbin/sigul_server \
                -c "$CONFIG_FILE" \
                -vv
        fi
    fi
}

start_server_service_debug() {
    log "Starting server in DEBUG mode (monitoring enabled)"
    log "Entrypoint will remain active to monitor the process"

    # Start sigul_server in background and capture its PID
    # -vv enables DEBUG level logging (same as normal mode)
    /usr/sbin/sigul_server \
        -c "$CONFIG_FILE" \
        -vv &

    local sigul_pid=$!
    log "Server process started with PID: $sigul_pid"

    # Set up signal forwarding
    # shellcheck disable=SC2064  # Variable expansion intentional - captures PID at trap setup
    trap "log 'Received SIGTERM, forwarding to server (PID $sigul_pid)'; kill -TERM $sigul_pid 2>/dev/null" TERM
    # shellcheck disable=SC2064  # Variable expansion intentional - captures PID at trap setup
    trap "log 'Received SIGINT, forwarding to server (PID $sigul_pid)'; kill -INT $sigul_pid 2>/dev/null" INT

    # Monitor the process
    log "Monitoring server process..."
    log "Log file: /var/log/sigul_server.log"
    log "=========================================="

    # Tail the log file in background
    if [[ -f "/var/log/sigul_server.log" ]]; then
        tail -f /var/log/sigul_server.log &
        local tail_pid=$!
    fi

    # Wait for the sigul process and capture exit code
    local exit_code=0
    if wait $sigul_pid; then
        exit_code=$?
        log "Server process exited normally with code: $exit_code"
    else
        exit_code=$?
        error "Server process exited with error code: $exit_code"
    fi

    # Clean up tail process
    if [[ -n "${tail_pid:-}" ]]; then
        kill "$tail_pid" 2>/dev/null || true
    fi

    # Show final log entries
    log "=========================================="
    log "Final log entries:"
    if [[ -f "/var/log/sigul_server.log" ]]; then
        tail -20 /var/log/sigul_server.log | while IFS= read -r line; do
            echo "  $line"
        done
    else
        error "Log file not found at /var/log/sigul_server.log"
    fi

    exit $exit_code
}

#######################################
# Main Entrypoint
#######################################

main() {
    log "Sigul Server Entrypoint"
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

    # Wait for bridge to be available
    wait_for_bridge

    # Initialize required directories
    initialize_gnupg_directory
    initialize_directories
    initialize_database

    # Fix volume permissions (must be done as root)
    fix_volume_permissions

    # Start the service (will drop privileges if running as root)
    start_server_service
}

# Execute main function
main "$@"
