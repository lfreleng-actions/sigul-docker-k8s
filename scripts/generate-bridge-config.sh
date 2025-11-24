#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Bridge Configuration Generator
#
# Generates bridge configuration with proper certificate nicknames
# for the new PKI architecture where bridge is the CA.
#
# Usage:
#   BRIDGE_FQDN=sigul-bridge.example.org NSS_PASSWORD=secret ./generate-bridge-config.sh
#
# Environment Variables:
#   BRIDGE_FQDN - Bridge FQDN (default: sigul-bridge.example.org)
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
NSS_PASSWORD="${NSS_PASSWORD:-}"
DEBUG="${DEBUG:-false}"

# Paths
readonly CONFIG_FILE="/etc/sigul/bridge.conf"
readonly NSS_DIR="/etc/pki/sigul/bridge"

# Certificate nicknames
readonly CA_NICKNAME="sigul-ca"
readonly BRIDGE_CERT_NICKNAME="sigul-bridge-cert"

# Logging
log() { echo -e "${BLUE}[BRIDGE-CONFIG]${NC} $*"; }
success() { echo -e "${GREEN}[BRIDGE-CONFIG]${NC} $*"; }
error() { echo -e "${RED}[BRIDGE-CONFIG]${NC} $*"; }
fatal() { error "$*"; exit 1; }

# Validate environment
if [[ -z "$NSS_PASSWORD" ]]; then
    fatal "NSS_PASSWORD environment variable is required"
fi

log "Generating bridge configuration..."

# Create config directory if needed
mkdir -p "$(dirname "$CONFIG_FILE")"

# Generate configuration
cat > "$CONFIG_FILE" << EOF
# Sigul Bridge Configuration
# Auto-generated on $(date -u +%Y-%m-%dT%H:%M:%SZ)
#
# This bridge acts as the Certificate Authority and pre-generates
# all certificates for the infrastructure.

[bridge]
server-listen-port: 44333
client-listen-port: 44334

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
# Bridge certificate for TLS
bridge-cert-nickname: ${BRIDGE_CERT_NICKNAME}
# CA certificate for validating client/server connections
bridge-ca-cert-nickname: ${CA_NICKNAME}
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
# - Bridge is the Certificate Authority (has CA private key)
# - Bridge pre-generates certificates for server and client
# - Only CA public certificate is distributed to other components
EOF

chmod 644 "$CONFIG_FILE"
success "Bridge configuration generated: $CONFIG_FILE"

log "Configuration summary:"
echo "  Bridge FQDN: ${BRIDGE_FQDN}"
echo "  Bridge cert: ${BRIDGE_CERT_NICKNAME}"
echo "  CA cert: ${CA_NICKNAME}"
echo "  NSS database: ${NSS_DIR}"
echo ""
echo "Security: Bridge is the CA and has signing authority"
