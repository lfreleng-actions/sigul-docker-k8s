#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul NSS Initialization Script
#
# This script provides clean, focused NSS certificate management for Sigul components
# implementing the bridge-centric CA architecture for production deployments.
#
# Key Design Principles:
# - NSS certificate management with certificate nicknames
# - Bridge-centric CA architecture
# - Simple validation focused on certificate existence
# - Fast startup with minimal complexity
# - Clean error handling with NSS-specific diagnostics
#
# Usage:
#   ./sigul-init-nss-only.sh --role bridge [--start-service]
#   ./sigul-init-nss-only.sh --role server [--start-service]
#   ./sigul-init-nss-only.sh --role client
#
# Arguments:
#   --role ROLE         Component role (bridge|server|client)
#   --start-service     Start the Sigul service after initialization
#   --debug             Enable debug logging
#   --validate-only     Only run validation, no initialization

set -euo pipefail

# Script version
readonly SCRIPT_VERSION="2.0.0-nss-only"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Configuration constants - FHS-compliant paths
readonly CONFIG_DIR="/etc/sigul"
readonly NSS_BASE_DIR="/etc/pki/sigul"
readonly DATA_BASE_DIR="/var/lib/sigul"
readonly LOGS_DIR="/var/log/sigul"
readonly RUN_DIR="/run/sigul"
readonly DB_DIR="$DATA_BASE_DIR"
readonly GNUPG_DIR="$DATA_BASE_DIR/server/gnupg"
readonly SECRETS_DIR="$DATA_BASE_DIR/secrets"
readonly CA_EXPORT_DIR="$DATA_BASE_DIR/ca-export"
readonly CA_IMPORT_DIR="$DATA_BASE_DIR/ca-import"

# NSS certificate nicknames (standardized)
readonly CA_NICKNAME="sigul-ca"
readonly BRIDGE_CERT_NICKNAME="sigul-bridge-cert"
readonly SERVER_CERT_NICKNAME="sigul-server-cert"
readonly CLIENT_CERT_NICKNAME="sigul-client-cert"

# Default values
SIGUL_ROLE="${SIGUL_ROLE:-}"
DEBUG="${DEBUG:-false}"
START_SERVICE=false
VALIDATE_ONLY=false

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] NSS-INIT:${NC} $*"
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%H:%M:%S')] NSS-DEBUG:${NC} $*"
    fi
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] NSS-SUCCESS:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] NSS-WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] NSS-ERROR:${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

#######################################
# Directory and File Management
#######################################

create_directory_structure() {
    log "Creating FHS-compliant directory structure for role: ${SIGUL_ROLE}"

    # Create base directories (FHS-compliant)
    local base_dirs=(
        "$CONFIG_DIR"
        "$NSS_BASE_DIR"
        "$DATA_BASE_DIR"
        "$LOGS_DIR"
        "$RUN_DIR"
        "$SECRETS_DIR"
        "$CA_EXPORT_DIR"
        "$CA_IMPORT_DIR"
    )

    for dir in "${base_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || true
            debug "Created base directory: $dir"
        fi
    done

    # Create role-specific directories
    if [[ -n "${SIGUL_ROLE}" ]]; then
        local role_dirs=(
            "$NSS_BASE_DIR/${SIGUL_ROLE}"
            "$DATA_BASE_DIR/${SIGUL_ROLE}"
            "$LOGS_DIR/${SIGUL_ROLE}"
            "$RUN_DIR/${SIGUL_ROLE}"
        )

        for dir in "${role_dirs[@]}"; do
            if [[ ! -d "$dir" ]]; then
                mkdir -p "$dir" 2>/dev/null || true
                debug "Created role-specific directory: $dir"
            fi
        done

        # Set special permissions for specific directories
        if [[ "${SIGUL_ROLE}" == "server" ]]; then
            # GPG directory needs restrictive permissions
            mkdir -p "$GNUPG_DIR" 2>/dev/null || true
            chmod 700 "$GNUPG_DIR" 2>/dev/null || true
            debug "Set secure permissions for GPG directory: $GNUPG_DIR"
        fi
    fi

    # Set permissions for shared directories
    chmod 755 "$CA_EXPORT_DIR" 2>/dev/null || true
    chmod 755 "$CA_IMPORT_DIR" 2>/dev/null || true
    chmod 755 "$SECRETS_DIR" 2>/dev/null || true
    debug "Set permissions for shared directories"

    success "FHS-compliant directory structure created"
}

generate_nss_password() {
    local password_file="$SECRETS_DIR/nss-password"

    if [[ -f "$password_file" ]]; then
        debug "NSS password file already exists"
        return 0
    fi

    log "Generating NSS database password"

    # Generate strong password
    local password
    password=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

    echo "$password" > "$password_file"
    chmod 600 "$password_file"

    success "NSS password generated and saved"
}

get_nss_password() {
    local password_file="$SECRETS_DIR/nss-password"
    if [[ -f "$password_file" ]]; then
        cat "$password_file"
    else
        fatal "NSS password file not found: $password_file"
    fi
}

#######################################
# NSS Database Management
#######################################



#######################################
# Bridge-Specific Operations (CA)
#######################################

setup_bridge_ca() {
    log "Setting up bridge as Certificate Authority (production-aligned)"

    local bridge_nss_dir="$NSS_BASE_DIR/bridge"
    local bridge_fqdn="${BRIDGE_FQDN:-sigul-bridge.example.org}"

    # Check if certificates already exist
    if [[ -f "$bridge_nss_dir/cert9.db" ]] && \
       certutil -d "sql:$bridge_nss_dir" -L -n "$CA_NICKNAME" >/dev/null 2>&1 && \
       certutil -d "sql:$bridge_nss_dir" -L -n "$BRIDGE_CERT_NICKNAME" >/dev/null 2>&1; then
        log "Bridge certificates already exist, skipping generation"
        return 0
    fi

    log "Generating production-aligned certificates for bridge..."

    # Use production-aligned certificate generation script
    if [[ -x "/usr/local/bin/generate-production-aligned-certs.sh" ]]; then
        NSS_DB_DIR="$bridge_nss_dir" \
        NSS_PASSWORD="$(get_nss_password)" \
        COMPONENT="bridge" \
        FQDN="$bridge_fqdn" \
        /usr/local/bin/generate-production-aligned-certs.sh
    elif [[ -x "/workspace/pki/generate-production-aligned-certs.sh" ]]; then
        NSS_DB_DIR="$bridge_nss_dir" \
        NSS_PASSWORD="$(get_nss_password)" \
        COMPONENT="bridge" \
        FQDN="$bridge_fqdn" \
        /workspace/pki/generate-production-aligned-certs.sh
    else
        fatal "Production-aligned certificate generation script not found"
    fi

    success "Bridge certificates generated with FQDN and SAN"
}

#######################################
# Server-Specific Operations
#######################################

setup_server_certificates() {
    log "Setting up server certificates (production-aligned)"

    local server_nss_dir="$NSS_BASE_DIR/server"
    local server_fqdn="${SERVER_FQDN:-sigul-server.example.org}"
    local ca_import_dir="$NSS_BASE_DIR/bridge-shared/ca-export"

    # Check if certificates already exist
    if [[ -f "$server_nss_dir/cert9.db" ]] && \
       certutil -d "sql:$server_nss_dir" -L -n "$CA_NICKNAME" >/dev/null 2>&1 && \
       certutil -d "sql:$server_nss_dir" -L -n "$SERVER_CERT_NICKNAME" >/dev/null 2>&1; then
        log "Server certificates already exist, skipping generation"
        return 0
    fi

    # Wait for CA from bridge to be available
    log "Waiting for CA certificate from bridge..."
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if [[ -d "$ca_import_dir" ]] && [[ -f "$ca_import_dir/ca.crt" ]]; then
            debug "CA certificate found from bridge"
            break
        fi
        if [[ $attempt -eq 1 ]]; then
            debug "Waiting for bridge CA..."
        fi
        sleep 2
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        warn "Bridge CA not available, server will generate with fallback method"
    fi

    log "Generating production-aligned certificates for server..."

    # Use production-aligned certificate generation script
    if [[ -x "/usr/local/bin/generate-production-aligned-certs.sh" ]]; then
        NSS_DB_DIR="$server_nss_dir" \
        NSS_PASSWORD="$(get_nss_password)" \
        COMPONENT="server" \
        FQDN="$server_fqdn" \
        /usr/local/bin/generate-production-aligned-certs.sh
    elif [[ -x "/workspace/pki/generate-production-aligned-certs.sh" ]]; then
        NSS_DB_DIR="$server_nss_dir" \
        NSS_PASSWORD="$(get_nss_password)" \
        COMPONENT="server" \
        FQDN="$server_fqdn" \
        /workspace/pki/generate-production-aligned-certs.sh
    else
        fatal "Production-aligned certificate generation script not found"
    fi

    success "Server certificates generated with FQDN and SAN"

    # Note: Database initialization moved to after configuration generation
}

#######################################
# Client-Specific Operations
#######################################

setup_client_certificates() {
    log "Setting up client certificates (production-aligned)"

    local client_nss_dir="$NSS_BASE_DIR/client"
    local client_fqdn="${CLIENT_FQDN:-sigul-client.example.org}"
    local bridge_ca_export_dir="$NSS_BASE_DIR/bridge-shared/ca-export"
    local client_ca_import_dir="$NSS_BASE_DIR/ca-import"

    # Check if certificates already exist
    if [[ -f "$client_nss_dir/cert9.db" ]] && \
       certutil -d "sql:$client_nss_dir" -L -n "$CA_NICKNAME" >/dev/null 2>&1 && \
       certutil -d "sql:$client_nss_dir" -L -n "$CLIENT_CERT_NICKNAME" >/dev/null 2>&1; then
        log "Client certificates already exist, skipping generation"
        return 0
    fi

    # Wait for CA with private key from bridge to be available
    log "Waiting for CA with private key from bridge..."
    local max_attempts=30
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if [[ -d "$bridge_ca_export_dir" ]] && [[ -f "$bridge_ca_export_dir/ca.p12" ]] && [[ -f "$bridge_ca_export_dir/ca-p12-password" ]]; then
            debug "CA PKCS#12 file found from bridge"
            break
        fi
        if [[ $attempt -eq 1 ]]; then
            debug "Waiting for bridge CA with private key..."
        fi
        sleep 2
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        fatal "Bridge CA not available, cannot generate client certificates"
    fi

    # Copy CA files from bridge export to client import location
    log "Copying CA files from bridge to client import location..."
    mkdir -p "$client_ca_import_dir"
    chmod 755 "$client_ca_import_dir"
    
    if ! cp "$bridge_ca_export_dir/ca.p12" "$client_ca_import_dir/ca.p12" 2>/dev/null; then
        fatal "Failed to copy CA PKCS#12 file"
    fi
    
    if ! cp "$bridge_ca_export_dir/ca-p12-password" "$client_ca_import_dir/ca-p12-password" 2>/dev/null; then
        fatal "Failed to copy CA PKCS#12 password file"
    fi
    
    chmod 600 "$client_ca_import_dir/ca.p12"
    chmod 600 "$client_ca_import_dir/ca-p12-password"
    
    success "CA files copied to client import location"

    log "Generating production-aligned certificates for client..."

    # Use production-aligned certificate generation script
    if [[ -x "/usr/local/bin/generate-production-aligned-certs.sh" ]]; then
        NSS_DB_DIR="$client_nss_dir" \
        NSS_PASSWORD="$(get_nss_password)" \
        COMPONENT="client" \
        FQDN="$client_fqdn" \
        /usr/local/bin/generate-production-aligned-certs.sh
    elif [[ -x "/workspace/pki/generate-production-aligned-certs.sh" ]]; then
        NSS_DB_DIR="$client_nss_dir" \
        NSS_PASSWORD="$(get_nss_password)" \
        COMPONENT="client" \
        FQDN="$client_fqdn" \
        /workspace/pki/generate-production-aligned-certs.sh
    else
        fatal "Production-aligned certificate generation script not found"
    fi

    success "Client certificates generated with FQDN and SAN"
}

#######################################
# Configuration Generation
#######################################

initialize_server_database() {
    log "Initializing server database"

    local db_file="$DB_DIR/server.sqlite"
    local config_file="$CONFIG_DIR/server.conf"
    local admin_user="${SIGUL_ADMIN_USER:-admin}"
    local admin_password="${SIGUL_ADMIN_PASSWORD:-sigul123}"

    # Create database directory if it doesn't exist
    mkdir -p "$DB_DIR"
    chmod 755 "$DB_DIR"

    # Create database schema using sigul_server_create_db
    log "Creating server database schema"
    if sigul_server_create_db -c "$config_file" >/dev/null 2>&1; then
        success "Server database schema created"
    else
        # Database might already exist, check if tables are present
        if sqlite3 "$db_file" ".tables" 2>/dev/null | grep -q "users"; then
            debug "Database schema already exists"
        else
            fatal "Failed to create server database schema"
        fi
    fi

    # Check if admin user already exists
    if sqlite3 "$db_file" "SELECT COUNT(*) FROM users WHERE name='$admin_user' AND admin=1;" 2>/dev/null | grep -q "1"; then
        debug "Admin user '$admin_user' already exists"
        return 0
    fi

    # Create admin user using sigul_server_add_admin
    log "Creating admin user: $admin_user"

    # Use printf to provide password twice (confirmation) in batch mode
    if printf "%s\\0%s\\0" "$admin_password" "$admin_password" | \
       sigul_server_add_admin -c "$config_file" --name "$admin_user" --batch >/dev/null 2>&1; then
        success "Admin user '$admin_user' created successfully"
    else
        error "Failed to create admin user '$admin_user'"
        # Don't fail fatally here as the server might still work for some operations
        log "Server will continue without admin user - manual creation may be required"
    fi

    # Set proper permissions on database file
    chmod 644 "$db_file"
}

generate_configuration() {
    local role="$1"
    local config_file="$CONFIG_DIR/$role.conf"

    log "Generating production-aligned configuration for $role"

    # Configuration variables
    local nss_password
    nss_password=$(get_nss_password)
    local bridge_fqdn="${BRIDGE_FQDN:-sigul-bridge.example.org}"
    local server_fqdn="${SERVER_FQDN:-sigul-server.example.org}"
    local client_port="${CLIENT_PORT:-44334}"
    local server_port="${SERVER_PORT:-44333}"
    local bridge_port="${BRIDGE_PORT:-44333}"

    # Generate role-specific configuration (production-aligned)
    case "$role" in
        "bridge")
            cat > "$config_file" << EOF
# Sigul Bridge Configuration
# Production-aligned configuration

[bridge]
bridge-cert-nickname: ${bridge_fqdn}
client-listen-port: ${client_port}
server-listen-port: ${server_port}

[koji]

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: ${NSS_BASE_DIR}
nss-password: ${nss_password}
nss-min-tls: tls1.2
EOF
            ;;
        "server")
            cat > "$config_file" << EOF
# Sigul Server Configuration
# Production-aligned configuration

[server]
bridge-hostname: ${bridge_fqdn}
bridge-port: ${bridge_port}
max-file-payload-size: 1073741824
max-memory-payload-size: 1048576
max-rpms-payload-size: 10737418240
server-cert-nickname: ${server_fqdn}
signing-timeout: 60

[database]
database-path: ${DATA_BASE_DIR}/server/sigul.db

[gnupg]
gnupg-home: ${DATA_BASE_DIR}/server/gnupg
gnupg-key-type: RSA
gnupg-key-length: 2048
gnupg-key-usage: sign
passphrase-length: 64

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: ${NSS_BASE_DIR}
nss-password: ${nss_password}
nss-min-tls: tls1.2
EOF
            ;;
        "client")
            local admin_user="${SIGUL_ADMIN_USER:-admin}"
            cat > "$config_file" << EOF
# Sigul Client Configuration
# Production-aligned configuration

[client]
bridge-hostname: ${bridge_fqdn}
bridge-port: ${client_port}
user-name: ${admin_user}

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: ${NSS_BASE_DIR}
nss-password: ${nss_password}
nss-min-tls: tls1.2
EOF
            ;;
    esac

    # Set secure permissions
    chmod 600 "$config_file"

    success "Production-aligned configuration generated: $config_file"
}

#######################################
# NSS-Only Validation
#######################################

validate_nss_setup() {
    local role="$1"

    log "Validating NSS setup for $role"

    local nss_dir="$NSS_BASE_DIR/$role"
    local validation_passed=true

    # Check NSS database files
    local required_files=("cert9.db" "key4.db" "pkcs11.txt")
    for file in "${required_files[@]}"; do
        if [[ -f "$nss_dir/$file" ]]; then
            debug "NSS file exists: $file"
        else
            error "Missing NSS file: $file"
            validation_passed=false
        fi
    done

    # Check CA certificate
    if certutil -d "sql:$nss_dir" -L -n "$CA_NICKNAME" >/dev/null 2>&1; then
        debug "CA certificate exists: $CA_NICKNAME"
    else
        error "Missing CA certificate: $CA_NICKNAME"
        validation_passed=false
    fi

    # Check component certificate
    local cert_nickname
    case "$role" in
        "bridge") cert_nickname="$BRIDGE_CERT_NICKNAME" ;;
        "server") cert_nickname="$SERVER_CERT_NICKNAME" ;;
        "client") cert_nickname="$CLIENT_CERT_NICKNAME" ;;
    esac

    if certutil -d "sql:$nss_dir" -L -n "$cert_nickname" >/dev/null 2>&1; then
        debug "Component certificate exists: $cert_nickname"
    else
        error "Missing component certificate: $cert_nickname"
        validation_passed=false
    fi

    if [[ "$validation_passed" == "true" ]]; then
        success "NSS validation passed for $role"
        return 0
    else
        error "NSS validation failed for $role"
        return 1
    fi
}

#######################################
# Service Management
#######################################

start_sigul_service() {
    local role="$1"
    local config_file="$CONFIG_DIR/$role.conf"

    log "Starting Sigul $role service"

    case "$role" in
        "bridge")
            exec sigul_bridge -c "$config_file"
            ;;
        "server")
            exec sigul_server -c "$config_file"
            ;;
        "client")
            log "Client initialized - ready for interactive use"
            exec /bin/bash
            ;;
    esac
}

#######################################
# Main Functions
#######################################

initialize_component() {
    local role="$1"

    log "Initializing Sigul $role with NSS-only approach"

    # Create directory structure
    create_directory_structure

    # Generate NSS password
    generate_nss_password

    # Component-specific setup
    case "$role" in
        "bridge")
            setup_bridge_ca
            ;;
        "server")
            setup_server_certificates
            ;;
        "client")
            setup_client_certificates
            ;;
        *)
            fatal "Invalid role: $role"
            ;;
    esac

    # Generate configuration
    generate_configuration "$role"

    # Initialize server database after configuration is generated
    if [[ "$role" == "server" ]]; then
        initialize_server_database
    fi

    # Validate setup
    if ! validate_nss_setup "$role"; then
        fatal "NSS setup validation failed for $role"
    fi

    success "NSS-only initialization completed for $role"
}

show_usage() {
    cat << EOF
Sigul NSS-Only Initialization Script v$SCRIPT_VERSION

This script initializes Sigul components using NSS certificate management
with bridge-centric CA architecture.

Usage:
  $0 --role ROLE [OPTIONS]

Arguments:
  --role ROLE         Component role (bridge|server|client)

Options:
  --start-service     Start the Sigul service after initialization
  --debug             Enable debug logging
  --validate-only     Only run validation, no initialization
  --help              Show this help message

Examples:
  $0 --role bridge --start-service
  $0 --role server --debug --start-service
  $0 --role client
  $0 --role bridge --validate-only

Environment Variables:
  SIGUL_BRIDGE_HOSTNAME      Bridge hostname (default: sigul-bridge)
  SIGUL_BRIDGE_CLIENT_PORT   Bridge client port (default: 44334)
  SIGUL_BRIDGE_SERVER_PORT   Bridge server port (default: 44333)
  SIGUL_ADMIN_USER          Admin username (default: admin)
  SIGUL_ADMIN_PASSWORD      Admin password (default: sigul123)
  DEBUG                     Enable debug mode (default: false)

EOF
}

main() {
    log "Sigul NSS-Only Initialization Script v$SCRIPT_VERSION"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --role)
                SIGUL_ROLE="$2"
                shift 2
                ;;
            --start-service)
                START_SERVICE=true
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --validate-only)
                VALIDATE_ONLY=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$SIGUL_ROLE" ]]; then
        error "Role is required. Use --role bridge|server|client"
        show_usage
        exit 1
    fi

    if [[ ! "$SIGUL_ROLE" =~ ^(bridge|server|client)$ ]]; then
        error "Invalid role: $SIGUL_ROLE. Must be bridge, server, or client"
        exit 1
    fi

    # Run validation only if requested
    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        log "Running validation only for $SIGUL_ROLE"
        if validate_nss_setup "$SIGUL_ROLE"; then
            success "Validation passed"
            exit 0
        else
            error "Validation failed"
            exit 1
        fi
    fi

    # Initialize component
    initialize_component "$SIGUL_ROLE"

    # Start service if requested
    if [[ "$START_SERVICE" == "true" ]]; then
        start_sigul_service "$SIGUL_ROLE"
    else
        log "Initialization complete. Use --start-service to start the service."
    fi
}

# Run main function
main "$@"
