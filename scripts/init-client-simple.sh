#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Simple Client Initialization Script
# 
# This script initializes the Sigul client by importing pre-generated
# certificates that were created and exported by the bridge.
#
# Usage:
#   ./init-client-simple.sh
#
# Environment Variables:
#   BRIDGE_FQDN              - Bridge hostname (default: sigul-bridge.example.org)
#   SERVER_FQDN              - Server hostname for inner TLS (default: sigul-server.example.org)
#   NSS_PASSWORD             - NSS database password (default: sigul)
#   CONFIG_DIR               - Configuration directory (default: /etc/sigul)
#   NSS_DIR                  - NSS database directory (default: /etc/pki/sigul/client)
#   BRIDGE_SHARED_DIR        - Bridge shared directory (default: /etc/pki/sigul/bridge-shared)

set -euo pipefail

# Configuration
BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}"
SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}"
NSS_PASSWORD="${NSS_PASSWORD:-sigul}"
CONFIG_DIR="${CONFIG_DIR:-/etc/sigul}"
NSS_DIR="${NSS_DIR:-/etc/pki/sigul/client}"
BRIDGE_SHARED_DIR="${BRIDGE_SHARED_DIR:-/etc/pki/sigul/bridge}"

# Certificate names
CA_NICKNAME="sigul-ca"
BRIDGE_CERT_NICKNAME="sigul-bridge-cert"
CLIENT_CERT_NICKNAME="sigul-client-cert"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] CLIENT-INIT:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

fatal() {
    error "$*"
    exit 1
}

# Check if certificates already exist
check_existing_certs() {
    if [[ -f "$NSS_DIR/cert9.db" ]]; then
        if certutil -d "sql:$NSS_DIR" -L -n "$CA_NICKNAME" >/dev/null 2>&1 && \
           certutil -d "sql:$NSS_DIR" -L -n "$CLIENT_CERT_NICKNAME" >/dev/null 2>&1; then
            log "Client certificates already exist and are valid"
            return 0
        else
            log "Client NSS database exists but certificates are incomplete, reinitializing..."
            return 1
        fi
    fi
    return 1
}

# Initialize NSS database
init_nss_database() {
    log "Initializing client NSS database at $NSS_DIR"
    
    mkdir -p "$NSS_DIR"
    
    # Create password file
    local password_file="$NSS_DIR/nss-password"
    echo -n "$NSS_PASSWORD" > "$password_file"
    chmod 600 "$password_file"
    
    # Initialize NSS database with password
    if ! certutil -N -d "sql:$NSS_DIR" -f "$password_file" 2>/dev/null; then
        fatal "Failed to initialize NSS database"
    fi
    
    success "NSS database initialized"
}

# Import CA certificate
import_ca_cert() {
    log "Importing CA certificate from bridge export"
    
    local ca_cert="$BRIDGE_SHARED_DIR/ca-export/ca.crt"
    
    if [[ ! -f "$ca_cert" ]]; then
        fatal "CA certificate not found at $ca_cert"
    fi
    
    local password_file="$NSS_DIR/nss-password"
    
    if ! certutil -A -d "sql:$NSS_DIR" \
        -n "$CA_NICKNAME" \
        -t "TC,," \
        -a \
        -i "$ca_cert" \
        -f "$password_file" 2>/dev/null; then
        fatal "Failed to import CA certificate"
    fi
    
    success "CA certificate imported"
}

# Import bridge certificate
import_bridge_cert() {
    log "Importing bridge certificate from bridge export"
    
    local bridge_cert="$BRIDGE_SHARED_DIR/ca-export/bridge-cert.crt"
    
    if [[ ! -f "$bridge_cert" ]]; then
        fatal "Bridge certificate not found at $bridge_cert"
    fi
    
    local password_file="$NSS_DIR/nss-password"
    
    # Import bridge certificate with peer trust for SSL verification
    if ! certutil -A -d "sql:$NSS_DIR" \
        -n "$BRIDGE_CERT_NICKNAME" \
        -t "P,P,P" \
        -a \
        -i "$bridge_cert" \
        -f "$password_file" 2>/dev/null; then
        fatal "Failed to import bridge certificate"
    fi
    
    success "Bridge certificate imported with peer trust"
}

# Import client certificate from PKCS#12
import_client_cert() {
    log "Importing client certificate from bridge export"
    
    local p12_file="$BRIDGE_SHARED_DIR/client-export/client-cert.p12"
    local p12_password_file="$BRIDGE_SHARED_DIR/client-export/client-cert.p12.password"
    
    if [[ ! -f "$p12_file" ]]; then
        fatal "Client PKCS#12 file not found at $p12_file"
    fi
    
    if [[ ! -f "$p12_password_file" ]]; then
        fatal "Client PKCS#12 password file not found at $p12_password_file"
    fi
    
    local nss_password_file="$NSS_DIR/nss-password"
    
    # Import PKCS#12 with pk12util
    # Note: pk12util reads the P12 password from the password file
    if ! pk12util -i "$p12_file" \
        -d "sql:$NSS_DIR" \
        -k "$nss_password_file" \
        -w "$p12_password_file" 2>/dev/null; then
        fatal "Failed to import client certificate from PKCS#12"
    fi
    
    success "Client certificate imported from PKCS#12"
}

# Verify certificates
verify_certificates() {
    log "Verifying imported certificates"
    
    local password_file="$NSS_DIR/nss-password"
    
    # Check CA certificate
    if ! certutil -d "sql:$NSS_DIR" -L -n "$CA_NICKNAME" >/dev/null 2>&1; then
        fatal "CA certificate verification failed"
    fi
    
    # Check bridge certificate
    if ! certutil -d "sql:$NSS_DIR" -L -n "$BRIDGE_CERT_NICKNAME" >/dev/null 2>&1; then
        fatal "Bridge certificate verification failed"
    fi
    
    # Check client certificate
    if ! certutil -d "sql:$NSS_DIR" -L -n "$CLIENT_CERT_NICKNAME" >/dev/null 2>&1; then
        fatal "Client certificate verification failed"
    fi
    
    # Verify certificate can be used for authentication
    if ! certutil -d "sql:$NSS_DIR" -K -f "$password_file" 2>/dev/null | grep -q "$CLIENT_CERT_NICKNAME"; then
        fatal "Client certificate private key verification failed"
    fi
    
    success "All certificates verified successfully"
}

# Generate client configuration
generate_client_config() {
    log "Generating client configuration at $CONFIG_DIR/client.conf"
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "$CONFIG_DIR/client.conf" << EOF
# Sigul Client Configuration
# Auto-generated by init-client-simple.sh

[client]
bridge-hostname: $BRIDGE_FQDN
bridge-port: 44334
server-hostname: $SERVER_FQDN
user-name: admin
max-file-payload-size: 2097152

[nss]
nss-dir: $NSS_DIR
nss-password: $NSS_PASSWORD
client-cert-nickname: $CLIENT_CERT_NICKNAME
ca-cert-nickname: $CA_NICKNAME
nss-min-tls: tls1.2

[gnupg]
gnupg-bin: /usr/bin/gpg2
gnupg-key-type: RSA
gnupg-key-length: 4096
gnupg-key-usage: sign
EOF
    
    chmod 644 "$CONFIG_DIR/client.conf"
    
    success "Client configuration generated"
}

# Display summary
display_summary() {
    echo
    log "Client initialization complete!"
    echo
    log "Configuration:"
    log "  Config file:     $CONFIG_DIR/client.conf"
    log "  NSS database:    $NSS_DIR"
    log "  Bridge hostname: $BRIDGE_FQDN"
    log "  Server hostname: $SERVER_FQDN"
    log "  Bridge port:     44334"
    echo
    log "Certificates installed:"
    certutil -d "sql:$NSS_DIR" -L 2>/dev/null || true
    echo
    log "You can now use the sigul client to connect to the bridge"
    log "Example: sigul -c $CONFIG_DIR/client.conf list-users"
    echo
}

# Main execution
main() {
    log "Starting simple client initialization"
    log "Bridge shared directory: $BRIDGE_SHARED_DIR"
    log "NSS directory: $NSS_DIR"
    log "Config directory: $CONFIG_DIR"
    echo
    
    # Check if already initialized
    if check_existing_certs; then
        log "Client already initialized, regenerating configuration only"
        generate_client_config
        display_summary
        return 0
    fi
    
    # Initialize from scratch
    init_nss_database
    import_ca_cert
    import_bridge_cert
    import_client_cert
    verify_certificates
    generate_client_config
    display_summary
    
    success "Client initialization completed successfully"
}

# Run main function
main "$@"