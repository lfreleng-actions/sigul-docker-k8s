#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Server Configuration Generator
#
# Generates server configuration with proper certificate nicknames
# for the new PKI architecture where server imports pre-generated certs.
#
# Usage:
#   BRIDGE_FQDN=sigul-bridge.example.org SERVER_FQDN=sigul-server.example.org NSS_PASSWORD=secret ./generate-server-config.sh
#
# Environment Variables:
#   BRIDGE_FQDN - Bridge FQDN (default: sigul-bridge.example.org)
#   SERVER_FQDN - Server FQDN (default: sigul-server.example.org)
#   NSS_PASSWORD - NSS database password (required)
#   DEBUG - Enable debug output (default: false)

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}"
SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}"
NSS_PASSWORD="${NSS_PASSWORD:-}"
DEBUG="${DEBUG:-false}"

# Paths
readonly CONFIG_FILE="/etc/sigul/server.conf"
readonly NSS_DIR="/etc/pki/sigul/server"

# Certificate nicknames
readonly CA_NICKNAME="sigul-ca"
readonly SERVER_CERT_NICKNAME="sigul-server-cert"

# Logging
log() { echo -e "${BLUE}[SERVER-CONFIG]${NC} $*"; }
success() { echo -e "${GREEN}[SERVER-CONFIG]${NC} $*"; }
error() { echo -e "${RED}[SERVER-CONFIG]${NC} $*"; }
fatal() { error "$*"; exit 1; }

# Validate environment
if [[ -z "$NSS_PASSWORD" ]]; then
    fatal "NSS_PASSWORD environment variable is required"
fi

log "Generating server configuration..."

# Create config directory if needed
mkdir -p "$(dirname "$CONFIG_FILE")"

# Generate configuration
cat > "$CONFIG_FILE" << EOF
# Sigul Server Configuration
# Auto-generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# This server imports pre-generated certificates from bridge.
# Server does NOT have CA private key (security best practice).

[server]
bridge-hostname: ${BRIDGE_FQDN}
bridge-port: 44333

[database]
database-path: /var/lib/sigul/server.sqlite

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
# Server certificate for TLS
server-cert-nickname: ${SERVER_CERT_NICKNAME}
# CA certificate for validating bridge connections (public only)
server-ca-cert-nickname: ${CA_NICKNAME}
# NSS database location
nss-dir: ${NSS_DIR}
nss-password: ${NSS_PASSWORD}
nss-min-tls: tls1.2

[gnupg]
gnupg-bin: /usr/bin/gpg2
gnupg-key-type: RSA
gnupg-key-length: 4096
gnupg-key-usage: sign

# Security notes:
# - Server imports pre-generated certificate from bridge
# - Server has CA public certificate only (for validation)
# - Server does NOT have CA private key
# - Server cannot sign new certificates
EOF

chmod 644 "$CONFIG_FILE"
success "Server configuration generated: $CONFIG_FILE"

log "Configuration summary:"
echo "  Bridge hostname: ${BRIDGE_FQDN}"
echo "  Server FQDN: ${SERVER_FQDN}"
echo "  Server cert: ${SERVER_CERT_NICKNAME}"
echo "  CA cert: ${CA_NICKNAME} (public only)"
echo "  NSS database: ${NSS_DIR}"
echo ""
echo "Security: Server does NOT have CA signing authority"
