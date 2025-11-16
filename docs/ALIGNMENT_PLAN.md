<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Container Stack Alignment Plan

**Document Version:** 1.0
**Date:** 2025-01-26
**Reference:** SETUP_GAP_ANALYSIS.md (2025-11-16 Production Extraction)
**Goal:** Align containerized Sigul deployment with verified production configuration patterns

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Alignment Principles](#alignment-principles)
3. [Phase 0: Pre-Alignment Assessment](#phase-0-pre-alignment-assessment)
4. [Phase 1: Directory Structure & File Layout](#phase-1-directory-structure--file-layout)
5. [Phase 2: Certificate Infrastructure](#phase-2-certificate-infrastructure)
6. [Phase 3: Configuration Alignment](#phase-3-configuration-alignment)
7. [Phase 4: Service Initialization](#phase-4-service-initialization)
8. [Phase 5: Volume & Persistence Strategy](#phase-5-volume--persistence-strategy)
9. [Phase 6: Network & DNS Configuration](#phase-6-network--dns-configuration)
10. [Phase 7: Integration Testing](#phase-7-integration-testing)
11. [Phase 8: Documentation & Validation](#phase-8-documentation--validation)
12. [Success Criteria](#success-criteria)
13. [Rollback Strategy](#rollback-strategy)
14. [Appendix A: File Modification Checklist](#appendix-a-file-modification-checklist)
15. [Appendix B: Testing Procedures](#appendix-b-testing-procedures)

---

## Executive Summary

This alignment plan provides a phased approach to bring the containerized Sigul stack into configuration alignment with the verified working production deployment on AWS. The plan is based on comprehensive production data extraction performed on 2025-11-16.

**Key Principles:**

- ✅ **Modernization Supported**: Python 3, modern NSS (cert9.db), GPG 2.x
- ✅ **Configuration Alignment Required**: FHS paths, config structure, PKI patterns
- ❌ **No Downgrades**: No reverting to Python 2, old NSS formats, or deprecated protocols
- ❌ **No Legacy Protocols**: No SSLv2/SSLv3, maintaining TLS 1.2+ (with TLS 1.3 support)

**Critical Gaps Identified:**

1. Directory structure uses non-standard paths (blocking)
2. NSS password storage method differs (blocking)
3. Certificate naming lacks FQDN/SAN (high priority)
4. Complex initialization scripts vs. simple invocation (high priority)
5. Configuration file structure misalignment (critical)

**Estimated Timeline:**

- Phase 0: 1 day (assessment)
- Phases 1-4: 3-5 days (core alignment)
- Phases 5-6: 2-3 days (infrastructure)
- Phases 7-8: 2-3 days (testing & validation)
- **Total: 8-12 days**

---

## Alignment Principles

### What We Will Change

1. **Directory Paths**: Move to FHS-compliant paths
   - `/etc/sigul/` for configuration files
   - `/etc/pki/sigul/` for NSS databases
   - `/var/lib/sigul/` for persistent data
   - `/var/log/sigul/` for logs

2. **Configuration Structure**: Match production patterns
   - Use production-verified section names
   - Match production key-value pairs
   - Store NSS password in config files (not separate files)

3. **Certificate Management**: FQDN-based PKI
   - Use fully qualified domain names in CN
   - Include SAN (Subject Alternative Name) extensions
   - Proper Extended Key Usage (serverAuth + clientAuth)
   - External CA model (self-signed CA + component certs)

4. **Service Initialization**: Simplify startup
   - Direct command invocation (no wrapper scripts)
   - Match production systemd patterns
   - Explicit config file paths

5. **Network Configuration**: Production-aligned networking
   - FQDN-based hostnames
   - DNS resolution via Docker networks
   - Bridge listens on 0.0.0.0 (all interfaces)

### What We Will NOT Change

1. **Software Versions**: Maintain modern stack
   - ✅ Python 3.x (modern, supported)
   - ✅ Modern NSS (cert9.db format)
   - ✅ GPG 2.x (current version)
   - ✅ Current package versions

2. **Security Protocols**: Keep modern security
   - ✅ TLS 1.2+ with TLS 1.3 support (no SSLv2/SSLv3)
   - ✅ Strong key sizes (2048+ bit RSA)
   - ✅ Modern cipher suites

3. **Out-of-Scope Components**: Not implementing
   - ❌ RabbitMQ (not used by Sigul)
   - ❌ LDAP integration (not in production Sigul)
   - ❌ Koji/FAS integration (empty in production)

### Testing Strategy

- **Unit Testing**: Configuration parsing, certificate validation
- **Integration Testing**: Full stack deployment, service communication
- **Regression Testing**: Ensure existing functionality preserved
- **Validation Testing**: Compare behavior with production patterns

---

## Phase 0: Pre-Alignment Assessment

**Goal:** Document current state and prepare for changes

### Tasks

#### 0.1 Create Baseline Documentation

```bash
# Document current configuration
docker-compose -f docker-compose.sigul.yml config > baseline-compose.yml

# Document current volume structure
docker volume ls | grep sigul > baseline-volumes.txt

# Document current network configuration
docker network inspect sigul-network > baseline-network.json
```

**Deliverables:**

- `baseline-compose.yml` - Current docker-compose resolved configuration
- `baseline-volumes.txt` - Current volume listing
- `baseline-network.json` - Current network configuration
- `baseline-paths.md` - Documentation of current directory structure

#### 0.2 Identify Files Requiring Changes

**Dockerfiles:**

- `Dockerfile.bridge` - Directory structure, initialization
- `Dockerfile.server` - Directory structure, initialization
- `Dockerfile.client` - Directory structure (if client component needed)

**Configuration Templates:**

- `scripts/sigul-config-nss-only.template` - Path updates, structure alignment
- Any bridge/server specific config templates

**Scripts:**

- `scripts/sigul-init.sh` - Initialization logic
- `scripts/deploy-sigul-infrastructure.sh` - Deployment orchestration
- Any PKI generation scripts in `pki/` directory

**Docker Compose:**

- `docker-compose.sigul.yml` - Volume mounts, network config, service definitions

**Testing:**

- `scripts/run-integration-tests.sh` - Path updates
- `scripts/test-infrastructure.sh` - Validation updates

#### 0.3 Create Feature Branch

```bash
git checkout -b feature/production-alignment
git commit --allow-empty -m "Start: Production configuration alignment"
```

#### 0.4 Backup Current Working State

```bash
# Create backup branch
git checkout -b backup/pre-alignment-$(date +%Y%m%d)
git push origin backup/pre-alignment-$(date +%Y%m%d)

# Return to feature branch
git checkout feature/production-alignment
```

**Exit Criteria:**

- [ ] Baseline documentation created
- [ ] All files requiring changes identified
- [ ] Feature branch created
- [ ] Backup branch created and pushed

---

## Phase 1: Directory Structure & File Layout

**Goal:** Align container filesystem layout with FHS-compliant production paths

**Priority:** CRITICAL (Blocking Issue)

### 1.1 Update Dockerfile.bridge

**File:** `Dockerfile.bridge`

**Changes Required:**

```dockerfile
# Create FHS-compliant directory structure
RUN mkdir -p \
    /etc/sigul \
    /etc/pki/sigul \
    /var/lib/sigul \
    /var/log/sigul \
    /run/sigul-default && \
    chown -R sigul:sigul \
        /etc/sigul \
        /etc/pki/sigul \
        /var/lib/sigul \
        /var/log/sigul \
        /run/sigul-default

# Set appropriate permissions
RUN chmod 700 /etc/pki/sigul && \
    chmod 755 /var/lib/sigul && \
    chmod 755 /var/log/sigul
```

**Remove:**

- Any references to `/var/sigul/config/`
- Any references to `/var/sigul/nss/bridge/`
- Any references to `/var/sigul/data/`

### 1.2 Update Dockerfile.server

**File:** `Dockerfile.server`

**Changes Required:**

```dockerfile
# Create FHS-compliant directory structure
RUN mkdir -p \
    /etc/sigul \
    /etc/pki/sigul \
    /var/lib/sigul/gnupg \
    /var/log/sigul \
    /run/sigul-default && \
    chown -R sigul:sigul \
        /etc/sigul \
        /etc/pki/sigul \
        /var/lib/sigul \
        /var/log/sigul \
        /run/sigul-default

# Set appropriate permissions
RUN chmod 700 /etc/pki/sigul && \
    chmod 700 /var/lib/sigul/gnupg && \
    chmod 755 /var/lib/sigul && \
    chmod 755 /var/log/sigul

# Ensure GnuPG directory has correct ownership
RUN chown -R sigul:sigul /var/lib/sigul/gnupg && \
    chmod 700 /var/lib/sigul/gnupg
```

**Remove:**

- Any references to `/var/sigul/config/`
- Any references to `/var/sigul/nss/server/`
- Any references to `/var/sigul/database/`
- Any references to `/var/sigul/gnupg/`

### 1.3 Update docker-compose.sigul.yml - Volume Mounts

**File:** `docker-compose.sigul.yml`

**Changes Required:**

```yaml
services:
  sigul-bridge:
    volumes:
      # Configuration (read-only from host)
      - ./configs/bridge.conf:/etc/sigul/bridge.conf:ro

      # NSS database (persistent volume)
      - sigul_bridge_nss:/etc/pki/sigul

      # Logs (persistent volume)
      - sigul_bridge_logs:/var/log/sigul

      # Runtime data
      - sigul_bridge_data:/var/lib/sigul

  sigul-server:
    volumes:
      # Configuration (read-only from host)
      - ./configs/server.conf:/etc/sigul/server.conf:ro

      # NSS database (persistent volume)
      - sigul_server_nss:/etc/pki/sigul

      # Server database and GnuPG (persistent volume)
      - sigul_server_data:/var/lib/sigul

      # Logs (persistent volume)
      - sigul_server_logs:/var/log/sigul

volumes:
  # Bridge volumes
  sigul_bridge_nss:
    driver: local
  sigul_bridge_logs:
    driver: local
  sigul_bridge_data:
    driver: local

  # Server volumes
  sigul_server_nss:
    driver: local
  sigul_server_data:
    driver: local
  sigul_server_logs:
    driver: local
```

**Remove:**

- `sigul_server_database` volume (data now in `sigul_server_data`)
- Any mounts to `/var/sigul/*` paths

### 1.4 Update Configuration Templates

**File:** `scripts/sigul-config-nss-only.template` (or similar)

**Changes Required:**

Update all path references:

```ini
# Before:
# nss-dir: /var/sigul/nss/<component>
# database-path: /var/sigul/database/server.sqlite
# gnupg-home: /var/sigul/gnupg

# After:
[nss]
nss-dir: /etc/pki/sigul

[database]
database-path: /var/lib/sigul/server.sqlite

[gnupg]
gnupg-home: /var/lib/sigul/gnupg
```

### 1.5 Create configs Directory

**New Directory:** `configs/`

This directory will contain template configuration files that get mounted into containers:

```bash
mkdir -p configs
```

Create initial templates (to be populated in Phase 3):

- `configs/bridge.conf.template`
- `configs/server.conf.template`

### 1.6 Validation

**Test Procedure:**

```bash
# Build images with new structure
docker-compose -f docker-compose.sigul.yml build

# Start containers
docker-compose -f docker-compose.sigul.yml up -d

# Verify directory structure in bridge
docker exec sigul-bridge ls -la /etc/sigul
docker exec sigul-bridge ls -la /etc/pki/sigul
docker exec sigul-bridge ls -la /var/lib/sigul
docker exec sigul-bridge ls -la /var/log/sigul

# Verify directory structure in server
docker exec sigul-server ls -la /etc/sigul
docker exec sigul-server ls -la /etc/pki/sigul
docker exec sigul-server ls -la /var/lib/sigul
docker exec sigul-server ls -la /var/lib/sigul/gnupg
docker exec sigul-server ls -la /var/log/sigul

# Verify permissions
docker exec sigul-bridge stat -c "%a %U:%G" /etc/pki/sigul
docker exec sigul-server stat -c "%a %U:%G" /var/lib/sigul/gnupg
```

**Expected Results:**

- All directories exist with correct ownership (`sigul:sigul`)
- NSS directory has 700 permissions
- GnuPG directory has 700 permissions
- Other directories have 755 permissions
- No `/var/sigul/*` directories present

**Exit Criteria:**

- [ ] Dockerfiles updated with FHS paths
- [ ] docker-compose.yml volume mounts updated
- [ ] Configuration templates updated with new paths
- [ ] `configs/` directory created
- [ ] Containers build successfully
- [ ] Directory structure validated in running containers
- [ ] All permissions correct

---

## Phase 2: Certificate Infrastructure

**Goal:** Implement FQDN-based PKI with proper certificate attributes

**Priority:** HIGH (Critical for TLS validation)

### 2.1 Define Certificate Requirements

**Specifications:**

| Component | Common Name (CN) | Subject Alternative Name (SAN) | Extended Key Usage |
|-----------|------------------|--------------------------------|--------------------|
| CA | `CN=Sigul CA` | None | None (CA cert) |
| Bridge | `CN=sigul-bridge.example.org` | `DNS:sigul-bridge.example.org` | serverAuth, clientAuth |
| Server | `CN=sigul-server.example.org` | `DNS:sigul-server.example.org` | serverAuth, clientAuth |

**Trust Flags (NSS):**

- CA: `CT,,` (trusted for issuing SSL/TLS certs)
- Components: `u,u,u` (valid user cert)

**Key Parameters:**

- Algorithm: RSA
- Key size: 2048 bits (minimum)
- Signature: SHA-256

### 2.2 Create Certificate Generation Script

**New File:** `pki/generate-production-aligned-certs.sh`

```bash
#!/bin/bash
set -euo pipefail

# Configuration
NSS_DB_DIR="${NSS_DB_DIR:-/etc/pki/sigul}"
CA_SUBJECT="CN=Sigul CA"
BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}"
SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}"
NSS_PASSWORD="${NSS_PASSWORD:-}"

# Ensure NSS database directory exists
mkdir -p "${NSS_DB_DIR}"
chmod 700 "${NSS_DB_DIR}"

# Create password file if password provided
if [ -n "${NSS_PASSWORD}" ]; then
    echo "${NSS_PASSWORD}" > "${NSS_DB_DIR}/nss-password.txt"
    chmod 600 "${NSS_DB_DIR}/nss-password.txt"
    NSS_PASSWORD_FILE="${NSS_DB_DIR}/nss-password.txt"
else
    echo "ERROR: NSS_PASSWORD must be set"
    exit 1
fi

# Initialize NSS database (modern cert9.db format)
echo "Initializing NSS database..."
certutil -N -d sql:"${NSS_DB_DIR}" -f "${NSS_PASSWORD_FILE}"

# Generate CA certificate
echo "Generating CA certificate..."
certutil -S \
    -n "CA" \
    -s "${CA_SUBJECT}" \
    -x \
    -t "CT,," \
    -k rsa \
    -g 2048 \
    -Z SHA256 \
    -v 120 \
    -d sql:"${NSS_DB_DIR}" \
    -f "${NSS_PASSWORD_FILE}" \
    --keyUsage certSigning,crlSigning

# Generate Bridge certificate with FQDN and SAN
echo "Generating Bridge certificate..."
certutil -S \
    -n "${BRIDGE_FQDN}" \
    -s "CN=${BRIDGE_FQDN}" \
    -c "CA" \
    -t "u,u,u" \
    -k rsa \
    -g 2048 \
    -Z SHA256 \
    -v 120 \
    -d sql:"${NSS_DB_DIR}" \
    -f "${NSS_PASSWORD_FILE}" \
    --extKeyUsage serverAuth,clientAuth \
    --keyUsage digitalSignature,keyEncipherment \
    -8 "${BRIDGE_FQDN}"

# Generate Server certificate with FQDN and SAN
echo "Generating Server certificate..."
certutil -S \
    -n "${SERVER_FQDN}" \
    -s "CN=${SERVER_FQDN}" \
    -c "CA" \
    -t "u,u,u" \
    -k rsa \
    -g 2048 \
    -Z SHA256 \
    -v 120 \
    -d sql:"${NSS_DB_DIR}" \
    -f "${NSS_PASSWORD_FILE}" \
    --extKeyUsage serverAuth,clientAuth \
    --keyUsage digitalSignature,keyEncipherment \
    -8 "${SERVER_FQDN}"

# Verify certificates
echo "Verifying certificates..."
certutil -L -d sql:"${NSS_DB_DIR}"

echo "Certificate generation complete!"
echo "NSS Database: ${NSS_DB_DIR}"
echo "Format: cert9.db (modern)"
```

Make executable:

```bash
chmod +x pki/generate-production-aligned-certs.sh
```

### 2.3 Update Dockerfiles to Use New Certificate Script

**Dockerfile.bridge:**

```dockerfile
# Copy certificate generation script
COPY pki/generate-production-aligned-certs.sh /usr/local/bin/

# Certificate generation will be done during initialization
# (moved to entrypoint/init script)
```

**Dockerfile.server:**

```dockerfile
# Copy certificate generation script
COPY pki/generate-production-aligned-certs.sh /usr/local/bin/

# Certificate generation will be done during initialization
# (moved to entrypoint/init script)
```

### 2.4 Update Initialization to Generate Certificates

Certificates should be generated once during initial setup, not on every container start.

**Option A: Generate during first container startup**

Update initialization script to check if certificates exist:

```bash
# In sigul-init.sh or similar
if [ ! -f "/etc/pki/sigul/cert9.db" ]; then
    echo "Generating certificates (first run)..."
    NSS_DB_DIR=/etc/pki/sigul \
    NSS_PASSWORD="${NSS_PASSWORD}" \
    BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}" \
    SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}" \
    /usr/local/bin/generate-production-aligned-certs.sh
else
    echo "Certificates already exist, skipping generation"
fi
```

**Option B: Generate via deployment script**

Update `scripts/deploy-sigul-infrastructure.sh`:

```bash
# Generate certificates before starting containers
echo "Generating PKI infrastructure..."

# Create temporary directory for certificate generation
TEMP_NSS_DIR=$(mktemp -d)

# Generate certificates
NSS_DB_DIR="${TEMP_NSS_DIR}" \
NSS_PASSWORD="${NSS_PASSWORD}" \
BRIDGE_FQDN="sigul-bridge.example.org" \
SERVER_FQDN="sigul-server.example.org" \
./pki/generate-production-aligned-certs.sh

# Copy to volumes (implementation depends on volume strategy)
# Option: Use temporary container to populate volume
docker run --rm \
    -v sigul_bridge_nss:/etc/pki/sigul \
    -v "${TEMP_NSS_DIR}:/source:ro" \
    alpine:latest \
    sh -c "cp -a /source/* /etc/pki/sigul/ && chown -R 1000:1000 /etc/pki/sigul"

# Cleanup
rm -rf "${TEMP_NSS_DIR}"
```

### 2.5 Certificate Validation Script

**New File:** `scripts/validate-certificates.sh`

```bash
#!/bin/bash
set -euo pipefail

COMPONENT="${1:-bridge}"
NSS_DB_DIR="${NSS_DB_DIR:-/etc/pki/sigul}"

echo "=== Certificate Validation for ${COMPONENT} ==="

# List all certificates
echo "Certificates in database:"
certutil -L -d sql:"${NSS_DB_DIR}"

# Verify CA
echo -e "\n=== CA Certificate ==="
certutil -L -n "CA" -d sql:"${NSS_DB_DIR}"

# Verify component certificate
if [ "${COMPONENT}" = "bridge" ]; then
    FQDN="sigul-bridge.example.org"
elif [ "${COMPONENT}" = "server" ]; then
    FQDN="sigul-server.example.org"
fi

echo -e "\n=== ${FQDN} Certificate ==="
certutil -L -n "${FQDN}" -d sql:"${NSS_DB_DIR}"

# Verify certificate chain
echo -e "\n=== Certificate Chain Validation ==="
certutil -V -n "${FQDN}" -u V -d sql:"${NSS_DB_DIR}"

echo -e "\nValidation complete!"
```

### 2.6 Update docker-compose.sigul.yml - Certificate Environment

```yaml
services:
  sigul-bridge:
    environment:
      - BRIDGE_FQDN=sigul-bridge.example.org
      - NSS_PASSWORD=${NSS_PASSWORD:-changeme}

  sigul-server:
    environment:
      - SERVER_FQDN=sigul-server.example.org
      - NSS_PASSWORD=${NSS_PASSWORD:-changeme}
```

### 2.7 Validation

**Test Procedure:**

```bash
# Generate certificates
NSS_PASSWORD="test-password-123" \
./pki/generate-production-aligned-certs.sh

# Verify certificate database format
file /etc/pki/sigul/cert9.db
# Expected: SQLite 3.x database

# List certificates
certutil -L -d sql:/etc/pki/sigul

# Expected output:
# Certificate Nickname    Trust Attributes
# CA                      CT,,
# sigul-bridge.example.org    u,u,u
# sigul-server.example.org    u,u,u

# Verify CA certificate details
certutil -L -n "CA" -d sql:/etc/pki/sigul

# Verify Bridge certificate with SAN
certutil -L -n "sigul-bridge.example.org" -d sql:/etc/pki/sigul | grep -A5 "DNS name"

# Verify Server certificate with SAN
certutil -L -n "sigul-server.example.org" -d sql:/etc/pki/sigul | grep -A5 "DNS name"
```

**Expected Results:**

- Database is modern cert9.db format (SQLite)
- CA certificate has CT,, trust flags
- Component certificates have u,u,u trust flags
- All certificates include SAN with FQDN
- Extended Key Usage includes both serverAuth and clientAuth
- Key size is 2048 bits
- Signature algorithm is SHA256

**Exit Criteria:**

- [ ] Certificate generation script created and tested
- [ ] Dockerfiles updated to include script
- [ ] Initialization logic updated for certificate generation
- [ ] docker-compose.yml includes certificate environment variables
- [ ] Validation script created
- [ ] All certificates generated successfully
- [ ] Certificate validation passes all checks
- [ ] Modern cert9.db format confirmed

---

## Phase 3: Configuration Alignment

**Goal:** Align configuration file structure with production patterns

**Priority:** CRITICAL

### 3.1 Create Bridge Configuration Template

**New File:** `configs/bridge.conf.template`

```ini
# Sigul Bridge Configuration
# Production-aligned configuration structure

[bridge]
# Certificate nickname must match the FQDN in the NSS database
bridge-cert-nickname: sigul-bridge.example.org

# Client-facing port (for sigul client connections)
client-listen-port: 44334

# Server-facing port (for sigul_server connections)
server-listen-port: 44333

[koji]
# Koji integration - currently not used, included for compatibility

[daemon]
# User and group for privilege dropping
unix-user: sigul
unix-group: sigul

[nss]
# NSS database configuration
nss-dir: /etc/pki/sigul

# NSS password (stored directly in config, production pattern)
nss-password: ${NSS_PASSWORD}

# TLS version constraints (modern TLS only)
# No upper limit - supports TLS 1.3
nss-min-tls: tls1.2
```

### 3.2 Create Server Configuration Template

**New File:** `configs/server.conf.template`

```ini
# Sigul Server Configuration
# Production-aligned configuration structure

[server]
# Bridge connection details
bridge-hostname: sigul-bridge.example.org
bridge-port: 44333

# Payload size limits (matching production)
max-file-payload-size: 1073741824
max-memory-payload-size: 1048576
max-rpms-payload-size: 10737418240

# Certificate nickname must match the FQDN in the NSS database
server-cert-nickname: sigul-server.example.org

# Signing timeout in seconds
signing-timeout: 60

[database]
# SQLite database location
database-path: /var/lib/sigul/server.sqlite

[gnupg]
# GnuPG configuration
gnupg-home: /var/lib/sigul/gnupg

# Key generation parameters
gnupg-key-type: RSA
gnupg-key-length: 2048
gnupg-key-usage: sign

# Passphrase generation
passphrase-length: 64

[daemon]
# User and group for privilege dropping
unix-user: sigul
unix-group: sigul

[nss]
# NSS database configuration
nss-dir: /etc/pki/sigul

# NSS password (stored directly in config, production pattern)
nss-password: ${NSS_PASSWORD}

# TLS version constraints (modern TLS only)
# No upper limit - supports TLS 1.3
nss-min-tls: tls1.2
```

### 3.3 Create Configuration Generation Script

**New File:** `scripts/generate-configs.sh`

```bash
#!/bin/bash
set -euo pipefail

# Configuration variables
NSS_PASSWORD="${NSS_PASSWORD:-changeme}"
BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}"
SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}"
OUTPUT_DIR="${OUTPUT_DIR:-./configs}"

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Generate bridge configuration
echo "Generating bridge configuration..."
sed "s/\${NSS_PASSWORD}/${NSS_PASSWORD}/g" \
    "${OUTPUT_DIR}/bridge.conf.template" > "${OUTPUT_DIR}/bridge.conf"

# Update FQDN in bridge config if different from default
sed -i "s/sigul-bridge\.example\.org/${BRIDGE_FQDN}/g" \
    "${OUTPUT_DIR}/bridge.conf"

# Generate server configuration
echo "Generating server configuration..."
sed "s/\${NSS_PASSWORD}/${NSS_PASSWORD}/g" \
    "${OUTPUT_DIR}/server.conf.template" > "${OUTPUT_DIR}/server.conf"

# Update FQDNs in server config if different from defaults
sed -i "s/sigul-bridge\.example\.org/${BRIDGE_FQDN}/g" \
    "${OUTPUT_DIR}/server.conf"
sed -i "s/sigul-server\.example\.org/${SERVER_FQDN}/g" \
    "${OUTPUT_DIR}/server.conf"

# Set appropriate permissions
chmod 600 "${OUTPUT_DIR}"/bridge.conf
chmod 600 "${OUTPUT_DIR}"/server.conf

echo "Configuration files generated in ${OUTPUT_DIR}"
echo "  - bridge.conf"
echo "  - server.conf"
```

Make executable:

```bash
chmod +x scripts/generate-configs.sh
```

### 3.4 Update Deployment Script

**File:** `scripts/deploy-sigul-infrastructure.sh`

Add configuration generation step:

```bash
# Generate configuration files
echo "Generating configuration files..."
NSS_PASSWORD="${NSS_PASSWORD}" \
BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}" \
SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}" \
OUTPUT_DIR="./configs" \
./scripts/generate-configs.sh
```

### 3.5 Configuration Validation Script

**New File:** `scripts/validate-configs.sh`

```bash
#!/bin/bash
set -euo pipefail

COMPONENT="${1:-bridge}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sigul/${COMPONENT}.conf}"

echo "=== Configuration Validation for ${COMPONENT} ==="

# Check file exists
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}"
    exit 1
fi

# Check file permissions
PERMS=$(stat -c "%a" "${CONFIG_FILE}")
if [ "${PERMS}" != "600" ]; then
    echo "WARNING: Configuration file permissions should be 600, found ${PERMS}"
fi

# Check file ownership
OWNER=$(stat -c "%U:%G" "${CONFIG_FILE}")
if [ "${OWNER}" != "sigul:sigul" ]; then
    echo "WARNING: Configuration file owner should be sigul:sigul, found ${OWNER}"
fi

# Validate configuration can be parsed
echo "Validating configuration syntax..."
python3 << EOF
import configparser
import sys

try:
    config = configparser.ConfigParser()
    config.read('${CONFIG_FILE}')

    # Verify required sections
    required_sections = ['${COMPONENT}', 'nss', 'daemon']
    if '${COMPONENT}' == 'server':
        required_sections.extend(['database', 'gnupg'])

    for section in required_sections:
        if not config.has_section(section):
            print(f"ERROR: Missing required section: [{section}]")
            sys.exit(1)

    print(f"Configuration syntax valid: {len(config.sections())} sections found")
    for section in config.sections():
        print(f"  [{section}]: {len(config.options(section))} options")

except Exception as e:
    print(f"ERROR: Configuration parsing failed: {e}")
    sys.exit(1)
EOF

echo "Configuration validation complete!"
```

Make executable:

```bash
chmod +x scripts/validate-configs.sh
```

### 3.6 Validation

**Test Procedure:**

```bash
# Generate configurations
NSS_PASSWORD="test-password-123" ./scripts/generate-configs.sh

# Verify files created
ls -la configs/bridge.conf configs/server.conf

# Validate bridge configuration
CONFIG_FILE=configs/bridge.conf ./scripts/validate-configs.sh bridge

# Validate server configuration
CONFIG_FILE=configs/server.conf ./scripts/validate-configs.sh server

# Check NSS password is embedded
grep "nss-password:" configs/bridge.conf
grep "nss-password:" configs/server.conf

# Verify FQDNs are correct
grep "bridge-cert-nickname" configs/bridge.conf
grep "server-cert-nickname" configs/server.conf
grep "bridge-hostname" configs/server.conf
```

**Expected Results:**

- Both configuration files created successfully
- Files have 600 permissions
- All required sections present
- NSS password embedded directly in configs (not referencing external file)
- Certificate nicknames use FQDNs
- Bridge hostname uses FQDN
- Configuration parsing succeeds

**Exit Criteria:**

- [ ] Configuration templates created
- [ ] Configuration generation script created and tested
- [ ] Configuration validation script created
- [ ] Deployment script updated to generate configs
- [ ] All configurations validate successfully
- [ ] NSS password storage method matches production
- [ ] Certificate nicknames match FQDN pattern

---

## Phase 4: Service Initialization

**Goal:** Simplify service startup to match production patterns

**Priority:** HIGH

### 4.1 Define Service Startup Requirements

**Production Pattern (from extraction):**

**Bridge:**

```bash
/usr/sbin/sigul_bridge -v
```

- No explicit config file path (uses default `/etc/sigul/bridge.conf`)
- Verbose logging (`-v`)
- Direct invocation, no wrapper scripts

**Server:**

```bash
/usr/sbin/sigul_server -c /etc/sigul/server.conf \
    --internal-log-dir=/var/log/sigul-default \
    --internal-pid-dir=/run/sigul-default \
    -v
```

- Explicit config file path (`-c`)
- Explicit log directory
- Explicit PID directory
- Verbose logging (`-v`)

### 4.2 Create Simplified Entrypoint Scripts

**New File:** `scripts/entrypoint-bridge.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "Starting Sigul Bridge..."

# Wait for dependencies (if any)
# (Network should be ready via Docker)

# Validate configuration exists
if [ ! -f /etc/sigul/bridge.conf ]; then
    echo "ERROR: Bridge configuration not found at /etc/sigul/bridge.conf"
    exit 1
fi

# Validate NSS database exists
if [ ! -f /etc/pki/sigul/cert9.db ]; then
    echo "ERROR: NSS database not found at /etc/pki/sigul/"
    echo "Certificates must be generated before starting the bridge"
    exit 1
fi

# Validate certificate exists
CERT_NICKNAME=$(grep "^bridge-cert-nickname:" /etc/sigul/bridge.conf | cut -d: -f2 | tr -d ' ')
if ! certutil -L -d sql:/etc/pki/sigul -n "${CERT_NICKNAME}" &>/dev/null; then
    echo "ERROR: Certificate '${CERT_NICKNAME}' not found in NSS database"
    exit 1
fi

echo "Configuration validated, starting bridge..."

# Start bridge with production-aligned command
exec /usr/sbin/sigul_bridge -v
```

**New File:** `scripts/entrypoint-server.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "Starting Sigul Server..."

# Wait for bridge to be available
BRIDGE_HOSTNAME=$(grep "^bridge-hostname:" /etc/sigul/server.conf | cut -d: -f2 | tr -d ' ')
BRIDGE_PORT=$(grep "^bridge-port:" /etc/sigul/server.conf | cut -d: -f2 | tr -d ' ')

echo "Waiting for bridge at ${BRIDGE_HOSTNAME}:${BRIDGE_PORT}..."
timeout 60 bash -c "until nc -z ${BRIDGE_HOSTNAME} ${BRIDGE_PORT}; do sleep 1; done" || {
    echo "ERROR: Bridge not available after 60 seconds"
    exit 1
}

echo "Bridge is available"

# Validate configuration exists
if [ ! -f /etc/sigul/server.conf ]; then
    echo "ERROR: Server configuration not found at /etc/sigul/server.conf"
    exit 1
fi

# Validate NSS database exists
if [ ! -f /etc/pki/sigul/cert9.db ]; then
    echo "ERROR: NSS database not found at /etc/pki/sigul/"
    echo "Certificates must be generated before starting the server"
    exit 1
fi

# Validate certificate exists
CERT_NICKNAME=$(grep "^server-cert-nickname:" /etc/sigul/server.conf | cut -d: -f2 | tr -d ' ')
if ! certutil -L -d sql:/etc/pki/sigul -n "${CERT_NICKNAME}" &>/dev/null; then
    echo "ERROR: Certificate '${CERT_NICKNAME}' not found in NSS database"
    exit 1
fi

# Initialize GnuPG directory if needed
if [ ! -d /var/lib/sigul/gnupg ]; then
    echo "Initializing GnuPG directory..."
    mkdir -p /var/lib/sigul/gnupg
    chmod 700 /var/lib/sigul/gnupg
fi

# Initialize database directory if needed
mkdir -p /var/lib/sigul
chmod 755 /var/lib/sigul

# Ensure log and PID directories exist
mkdir -p /var/log/sigul-default
mkdir -p /run/sigul-default
chown sigul:sigul /var/log/sigul-default /run/sigul-default

echo "Configuration validated, starting server..."

# Start server with production-aligned command
exec /usr/sbin/sigul_server \
    -c /etc/sigul/server.conf \
    --internal-log-dir=/var/log/sigul-default \
    --internal-pid-dir=/run/sigul-default \
    -v
```

Make executable:

```bash
chmod +x scripts/entrypoint-bridge.sh scripts/entrypoint-server.sh
```

### 4.3 Update Dockerfiles to Use New Entrypoints

**Dockerfile.bridge:**

```dockerfile
# Copy entrypoint script
COPY scripts/entrypoint-bridge.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Switch to sigul user
USER sigul

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

**Dockerfile.server:**

```dockerfile
# Copy entrypoint script
COPY scripts/entrypoint-server.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Switch to sigul user
USER sigul

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 4.4 Update docker-compose.sigul.yml

Remove any `command:` overrides if present, as we now use entrypoints:

```yaml
services:
  sigul-bridge:
    # Remove any 'command:' directive
    # Entrypoint is defined in Dockerfile

  sigul-server:
    # Remove any 'command:' directive
    # Entrypoint is defined in Dockerfile
    depends_on:
      sigul-bridge:
        condition: service_healthy  # Requires healthcheck
```

### 4.5 Add Healthchecks

**docker-compose.sigul.yml:**

```yaml
services:
  sigul-bridge:
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "44333"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  sigul-server:
    healthcheck:
      test: ["CMD", "pgrep", "-f", "sigul_server"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
```

### 4.6 Remove Complex Initialization Scripts

**Files to Remove or Simplify:**

- `scripts/sigul-init.sh` - If it contains complex initialization logic not matching production
- Any wrapper scripts that add layers between Docker and the actual Sigul process

**Logic to Preserve:**

- Certificate generation (one-time setup, not on every start)
- Configuration validation
- Dependency waiting (bridge availability)

### 4.7 Validation

**Test Procedure:**

```bash
# Build containers with new entrypoints
docker-compose -f docker-compose.sigul.yml build

# Start services
docker-compose -f docker-compose.sigul.yml up -d

# Check bridge startup logs
docker logs sigul-bridge

# Expected: Clean startup, "Starting Sigul Bridge", no wrapper script noise

# Check server startup logs
docker logs sigul-server

# Expected: Wait for bridge, clean startup, connection established

# Verify processes running
docker exec sigul-bridge pgrep -af sigul_bridge

# Expected: /usr/sbin/sigul_bridge -v

docker exec sigul-server pgrep -af sigul_server

# Expected: /usr/sbin/sigul_server -c /etc/sigul/server.conf --internal-log-dir=/var/log/sigul-default --internal-pid-dir=/run/sigul-default -v

# Verify network connectivity
docker exec sigul-bridge netstat -tlnp | grep 44333
docker exec sigul-bridge netstat -tlnp | grep 44334

# Expected: Bridge listening on both ports

docker exec sigul-server netstat -tnp | grep 44333

# Expected: Server has established connection to bridge
```

**Expected Results:**

- Bridge starts with direct command invocation
- Server starts with production-aligned command
- No wrapper script interference
- Clean log output
- Network connections established
- Processes running as expected

**Exit Criteria:**

- [ ] Simplified entrypoint scripts created
- [ ] Dockerfiles updated to use new entrypoints
- [ ] docker-compose.yml updated (commands removed, healthchecks added)
- [ ] Complex initialization scripts removed/simplified
- [ ] Services start successfully
- [ ] Process command lines match production pattern
- [ ] Network connectivity verified

---

## Phase 5: Volume & Persistence Strategy

**Goal:** Properly configure persistent storage for all components

**Priority:** MEDIUM

### 5.1 Define Volume Strategy

**Persistent Data Requirements:**

| Component | Data Type | Volume Mount | Persistence | Backup Priority |
|-----------|-----------|--------------|-------------|-----------------|
| Bridge | NSS DB | `/etc/pki/sigul` | Must persist | HIGH |
| Bridge | Logs | `/var/log/sigul` | Should persist | LOW |
| Bridge | Runtime | `/var/lib/sigul` | Optional | LOW |
| Server | NSS DB | `/etc/pki/sigul` | Must persist | HIGH |
| Server | SQLite DB | `/var/lib/sigul/server.sqlite` | Must persist | CRITICAL |
| Server | GnuPG Keys | `/var/lib/sigul/gnupg` | Must persist | CRITICAL |
| Server | Logs | `/var/log/sigul` | Should persist | MEDIUM |

**Volume Lifecycle:**

1. **Initialization Volumes** (Bridge/Server NSS DB): Generated once during first deployment
2. **Operational Volumes** (Server database, GnuPG): Created by running services
3. **Transient Volumes** (Logs): Can be recreated, useful for debugging

### 5.2 Update docker-compose.sigul.yml - Final Volume Configuration

```yaml
version: '3.8'

services:
  sigul-bridge:
    build:
      context: .
      dockerfile: Dockerfile.bridge
    container_name: sigul-bridge
    hostname: sigul-bridge.example.org
    networks:
      sigul-network:
        aliases:
          - sigul-bridge.example.org
    volumes:
      # Configuration (read-only from host)
      - ./configs/bridge.conf:/etc/sigul/bridge.conf:ro

      # NSS database (persistent, critical)
      - sigul_bridge_nss:/etc/pki/sigul

      # Logs (persistent, for debugging)
      - sigul_bridge_logs:/var/log/sigul

      # Runtime data (optional persistence)
      - sigul_bridge_data:/var/lib/sigul
    environment:
      - BRIDGE_FQDN=sigul-bridge.example.org
    ports:
      - "44333:44333"  # Server connection port
      - "44334:44334"  # Client connection port
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "44333"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  sigul-server:
    build:
      context: .
      dockerfile: Dockerfile.server
    container_name: sigul-server
    hostname: sigul-server.example.org
    networks:
      sigul-network:
        aliases:
          - sigul-server.example.org
    volumes:
      # Configuration (read-only from host)
      - ./configs/server.conf:/etc/sigul/server.conf:ro

      # NSS database (persistent, critical)
      - sigul_server_nss:/etc/pki/sigul

      # Server data: SQLite DB + GnuPG home (persistent, critical)
      - sigul_server_data:/var/lib/sigul

      # Logs (persistent, for debugging)
      - sigul_server_logs:/var/log/sigul

      # Runtime directories
      - sigul_server_run:/run
    environment:
      - SERVER_FQDN=sigul-server.example.org
    depends_on:
      sigul-bridge:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "pgrep", "-f", "sigul_server"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

networks:
  sigul-network:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1

volumes:
  # Bridge volumes
  sigul_bridge_nss:
    driver: local
    labels:
      description: "Bridge NSS certificate database"
      backup: "high"

  sigul_bridge_logs:
    driver: local
    labels:
      description: "Bridge log files"
      backup: "low"

  sigul_bridge_data:
    driver: local
    labels:
      description: "Bridge runtime data"
      backup: "low"

  # Server volumes
  sigul_server_nss:
    driver: local
    labels:
      description: "Server NSS certificate database"
      backup: "high"

  sigul_server_data:
    driver: local
    labels:
      description: "Server database and GnuPG keys"
      backup: "critical"

  sigul_server_logs:
    driver: local
    labels:
      description: "Server log files"
      backup: "medium"

  sigul_server_run:
    driver: local
    labels:
      description: "Server runtime files (PID, sockets)"
      backup: "none"
```

### 5.3 Volume Initialization Strategy

**Option A: Pre-populate volumes via deployment script**

Update `scripts/deploy-sigul-infrastructure.sh`:

```bash
#!/bin/bash
set -euo pipefail

echo "=== Sigul Infrastructure Deployment ==="

# Configuration
NSS_PASSWORD="${NSS_PASSWORD:-$(openssl rand -base64 32)}"
BRIDGE_FQDN="${BRIDGE_FQDN:-sigul-bridge.example.org}"
SERVER_FQDN="${SERVER_FQDN:-sigul-server.example.org}"

export NSS_PASSWORD BRIDGE_FQDN SERVER_FQDN

echo "Step 1: Generate configuration files"
./scripts/generate-configs.sh

echo "Step 2: Create Docker volumes"
docker volume create sigul_bridge_nss
docker volume create sigul_server_nss

echo "Step 3: Generate certificates in volumes"

# Generate bridge certificates
docker run --rm \
    -v sigul_bridge_nss:/etc/pki/sigul \
    -e NSS_PASSWORD="${NSS_PASSWORD}" \
    -e BRIDGE_FQDN="${BRIDGE_FQDN}" \
    -e SERVER_FQDN="${SERVER_FQDN}" \
    --entrypoint /usr/local/bin/generate-production-aligned-certs.sh \
    sigul-bridge:latest

# Copy certificates to server volume
docker run --rm \
    -v sigul_bridge_nss:/source:ro \
    -v sigul_server_nss:/dest \
    alpine:latest \
    sh -c "cp -a /source/* /dest/ && chmod 700 /dest"

echo "Step 4: Start services"
docker-compose -f docker-compose.sigul.yml up -d

echo "Step 5: Wait for services to be healthy"
timeout 120 bash -c 'until docker ps | grep -q "(healthy).*sigul-bridge"; do sleep 2; done'
timeout 120 bash -c 'until docker ps | grep -q "(healthy).*sigul-server"; do sleep 2; done'

echo "=== Deployment Complete ==="
echo "Bridge: sigul-bridge.example.org:44334 (client)"
echo "        sigul-bridge.example.org:44333 (server)"
echo "NSS Password: ${NSS_PASSWORD}"
echo ""
echo "Save the NSS password securely - it's required for operations"
```

**Option B: Initialize on first container start**

Keep certificate generation in entrypoint scripts with conditional logic (already covered in Phase 2.4).

### 5.4 Volume Backup Script

**New File:** `scripts/backup-volumes.sh`

```bash
#!/bin/bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "=== Sigul Volume Backup ==="
echo "Backup directory: ${BACKUP_DIR}"
echo "Timestamp: ${TIMESTAMP}"

mkdir -p "${BACKUP_DIR}"

# Backup critical volumes
for VOLUME in sigul_bridge_nss sigul_server_nss sigul_server_data; do
    echo "Backing up ${VOLUME}..."

    BACKUP_FILE="${BACKUP_DIR}/${VOLUME}-${TIMESTAMP}.tar.gz"

    docker run --rm \
        -v "${VOLUME}:/volume:ro" \
        -v "${BACKUP_DIR}:/backup" \
        alpine:latest \
        tar czf "/backup/$(basename ${BACKUP_FILE})" -C /volume .

    echo "  Saved to: ${BACKUP_FILE}"
done

echo "Backup complete!"
```

### 5.5 Volume Restore Script

**New File:** `scripts/restore-volumes.sh`

```bash
#!/bin/bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./backups}"
VOLUME_NAME="${1:-}"
BACKUP_FILE="${2:-}"

if [ -z "${VOLUME_NAME}" ] || [ -z "${BACKUP_FILE}" ]; then
    echo "Usage: $0 <volume-name> <backup-file>"
    echo "Example: $0 sigul_server_data backups/sigul_server_data-20250126-120000.tar.gz"
    exit 1
fi

if [ ! -f "${BACKUP_FILE}" ]; then
    echo "ERROR: Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

echo "=== Sigul Volume Restore ==="
echo "Volume: ${VOLUME_NAME}"
echo "Backup: ${BACKUP_FILE}"
echo ""
read -p "This will OVERWRITE the existing volume. Continue? (yes/no) " CONFIRM

if [ "${CONFIRM}" != "yes" ]; then
    echo "Restore cancelled"
    exit 0
fi

# Stop services
echo "Stopping services..."
docker-compose -f docker-compose.sigul.yml down

# Remove existing volume
echo "Removing existing volume..."
docker volume rm "${VOLUME_NAME}" || true

# Create fresh volume
echo "Creating fresh volume..."
docker volume create "${VOLUME_NAME}"

# Restore data
echo "Restoring data..."
docker run --rm \
    -v "${VOLUME_NAME}:/volume" \
    -v "$(dirname ${BACKUP_FILE}):/backup:ro" \
    alpine:latest \
    tar xzf "/backup/$(basename ${BACKUP_FILE})" -C /volume

echo "Restore complete!"
echo "Start services with: docker-compose -f docker-compose.sigul.yml up -d"
```

Make scripts executable:

```bash
chmod +x scripts/backup-volumes.sh scripts/restore-volumes.sh
```

### 5.6 Validation

**Test Procedure:**

```bash
# Deploy infrastructure
./scripts/deploy-sigul-infrastructure.sh

# Verify volumes created
docker volume ls | grep sigul

# Expected: 7 volumes (3 bridge + 4 server)

# Inspect critical volumes
docker volume inspect sigul_server_data

# Check volume contents
docker run --rm -v sigul_server_data:/data alpine:latest ls -laR /data

# Expected:
# /data/server.sqlite (after server starts)
# /data/gnupg/ (directory with GPG files)

# Test backup
./scripts/backup-volumes.sh

# Verify backups created
ls -lh backups/

# Test volume persistence
echo "Testing persistence..."
docker-compose -f docker-compose.sigul.yml down
docker-compose -f docker-compose.sigul.yml up -d

# Verify data still exists
docker run --rm -v sigul_server_data:/data alpine:latest ls -la /data/server.sqlite
```

**Expected Results:**

- All volumes created successfully
- Volumes properly labeled
- Critical data persists across container restarts
- Backup script creates valid archives
- Restore script successfully restores data

**Exit Criteria:**

- [ ] docker-compose.yml volume configuration complete
- [ ] Volume initialization strategy implemented
- [ ] Backup script created and tested
- [ ] Restore script created and tested
- [ ] All volumes created successfully
- [ ] Data persistence verified across container restarts
- [ ] Backup/restore cycle tested successfully

---

## Phase 6: Network & DNS Configuration

**Goal:** Ensure proper hostname resolution and network connectivity

**Priority:** HIGH

### 6.1 Network Architecture

**Production Pattern:**

- Bridge listens on `0.0.0.0:44333` (server connections)
- Bridge listens on `0.0.0.0:44334` (client connections)
- Server makes outbound connection to bridge
- Hostnames must resolve to FQDNs for certificate validation

**Container Network Requirements:**

- Bridge must be reachable by server via FQDN
- FQDNs must match certificate CNs
- DNS resolution via Docker network
- Optional: Static IP assignment for predictability

### 6.2 Update docker-compose.sigul.yml - Network Configuration

Already included in Phase 5.2, but highlighting key elements:

```yaml
services:
  sigul-bridge:
    hostname: sigul-bridge.example.org
    networks:
      sigul-network:
        ipv4_address: 172.20.0.2  # Optional: static IP
        aliases:
          - sigul-bridge.example.org
          - sigul-bridge
    ports:
      - "44333:44333"  # Server connection port
      - "44334:44334"  # Client connection port

  sigul-server:
    hostname: sigul-server.example.org
    networks:
      sigul-network:
        ipv4_address: 172.20.0.3  # Optional: static IP
        aliases:
          - sigul-server.example.org
          - sigul-server
    extra_hosts:
      # Ensure bridge FQDN resolves (redundant with DNS, but explicit)
      - "sigul-bridge.example.org:172.20.0.2"

networks:
  sigul-network:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1
```

### 6.3 DNS Resolution Verification Script

**New File:** `scripts/verify-dns.sh`

```bash
#!/bin/bash
set -euo pipefail

COMPONENT="${1:-server}"

echo "=== DNS Resolution Verification for ${COMPONENT} ==="

# Verify hostname
HOSTNAME=$(docker exec sigul-${COMPONENT} hostname)
echo "Container hostname: ${HOSTNAME}"

EXPECTED_HOSTNAME="sigul-${COMPONENT}.example.org"
if [ "${HOSTNAME}" != "${EXPECTED_HOSTNAME}" ]; then
    echo "WARNING: Hostname mismatch. Expected: ${EXPECTED_HOSTNAME}"
fi

# Verify FQDN resolution
echo -e "\nTesting FQDN resolution..."

# Self-resolution
echo "Resolving self (${EXPECTED_HOSTNAME}):"
docker exec sigul-${COMPONENT} getent hosts "${EXPECTED_HOSTNAME}"

# Bridge resolution (from server)
if [ "${COMPONENT}" = "server" ]; then
    echo -e "\nResolving bridge (sigul-bridge.example.org):"
    docker exec sigul-server getent hosts sigul-bridge.example.org

    echo -e "\nTesting connectivity to bridge:"
    docker exec sigul-server nc -zv sigul-bridge.example.org 44333
fi

# Verify /etc/hosts entries
echo -e "\n/etc/hosts entries:"
docker exec sigul-${COMPONENT} cat /etc/hosts

# Verify DNS from Docker network
echo -e "\nDocker DNS resolution:"
docker exec sigul-${COMPONENT} nslookup sigul-${COMPONENT}.example.org

echo -e "\nDNS verification complete!"
```

Make executable:

```bash
chmod +x scripts/verify-dns.sh
```

### 6.4 Network Connectivity Testing Script

**New File:** `scripts/verify-network.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "=== Network Connectivity Verification ==="

# Check bridge is listening
echo "Checking bridge listening ports..."
docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -E "(44333|44334)" || {
    echo "ERROR: Bridge not listening on expected ports"
    exit 1
}

echo "✓ Bridge listening on ports 44333 and 44334"

# Check server can reach bridge
echo -e "\nChecking server connectivity to bridge..."
docker exec sigul-server nc -zv sigul-bridge.example.org 44333 || {
    echo "ERROR: Server cannot reach bridge"
    exit 1
}

echo "✓ Server can reach bridge"

# Check established connections
echo -e "\nChecking established connections..."
echo "Bridge connections:"
docker exec sigul-bridge netstat -tnp 2>/dev/null | grep 44333 || echo "  No connections yet"

echo -e "\nServer connections:"
docker exec sigul-server netstat -tnp 2>/dev/null | grep 44333 || echo "  No connections yet"

# Verify Docker network
echo -e "\nDocker network information:"
docker network inspect sigul-network | jq '.[0].Containers'

echo -e "\nNetwork verification complete!"
```

Make executable:

```bash
chmod +x scripts/verify-network.sh
```

### 6.5 Certificate-Hostname Alignment Verification

**New File:** `scripts/verify-cert-hostname-alignment.sh`

```bash
#!/bin/bash
set -euo pipefail

COMPONENT="${1:-bridge}"

echo "=== Certificate-Hostname Alignment Verification ==="

# Get hostname
HOSTNAME=$(docker exec sigul-${COMPONENT} hostname)
echo "Container hostname: ${HOSTNAME}"

# Get certificate CN
CERT_NICKNAME=$(docker exec sigul-${COMPONENT} \
    grep "^${COMPONENT}-cert-nickname:" /etc/sigul/${COMPONENT}.conf \
    | cut -d: -f2 | tr -d ' ')

echo "Certificate nickname: ${CERT_NICKNAME}"

# Get certificate details
echo -e "\nCertificate details:"
docker exec sigul-${COMPONENT} \
    certutil -L -n "${CERT_NICKNAME}" -d sql:/etc/pki/sigul

# Verify CN matches hostname
if [ "${HOSTNAME}" = "${CERT_NICKNAME}" ]; then
    echo "✓ Hostname matches certificate CN"
else
    echo "ERROR: Hostname/CN mismatch!"
    echo "  Hostname: ${HOSTNAME}"
    echo "  Cert CN:  ${CERT_NICKNAME}"
    exit 1
fi

# Verify SAN includes hostname
echo -e "\nVerifying SAN..."
SAN=$(docker exec sigul-${COMPONENT} \
    certutil -L -n "${CERT_NICKNAME}" -d sql:/etc/pki/sigul \
    | grep -A5 "DNS name" | grep "${HOSTNAME}" || true)

if [ -n "${SAN}" ]; then
    echo "✓ SAN includes hostname"
    echo "  ${SAN}"
else
    echo "ERROR: SAN does not include hostname"
    exit 1
fi

echo -e "\nAlignment verification complete!"
```

Make executable:

```bash
chmod +x scripts/verify-cert-hostname-alignment.sh
```

### 6.6 Validation

**Test Procedure:**

```bash
# Deploy stack
docker-compose -f docker-compose.sigul.yml up -d

# Wait for services to be healthy
sleep 30

# Verify DNS resolution
./scripts/verify-dns.sh bridge
./scripts/verify-dns.sh server

# Verify network connectivity
./scripts/verify-network.sh

# Verify certificate-hostname alignment
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server

# Test actual TLS connection
echo "Testing TLS connection..."
docker exec sigul-server \
    openssl s_client -connect sigul-bridge.example.org:44333 \
    -CAfile /etc/pki/sigul/ca.pem \
    -showcerts < /dev/null

**Exit Criteria:**
- [ ] DNS resolution verified for all components
- [ ] Network connectivity confirmed
- [ ] Bridge listening on correct ports
- [ ] Server can connect to bridge
- [ ] Certificate CNs match hostnames
- [ ] SANs include FQDNs
- [ ] TLS connection validation passes

---

## Phase 7: Integration Testing

**Goal:** Validate complete stack functionality with comprehensive tests

**Priority:** CRITICAL

### 7.1 Update Integration Test Suite

**File:** `scripts/run-integration-tests.sh`

Update test script to work with new directory structure and configuration:

```bash
#!/bin/bash
set -euo pipefail

echo "=== Sigul Integration Test Suite ==="

# Configuration
BRIDGE_HOST="sigul-bridge.example.org"
BRIDGE_PORT="44333"
CLIENT_PORT="44334"
NSS_PASSWORD="${NSS_PASSWORD:-changeme}"

# Phase 1: Infrastructure Tests
echo "Phase 1: Infrastructure Validation"

# Test 1.1: Directory structure
echo "Test 1.1: Verifying directory structure..."
for COMPONENT in bridge server; do
    docker exec sigul-${COMPONENT} test -d /etc/sigul || {
        echo "FAIL: /etc/sigul not found in ${COMPONENT}"
        exit 1
    }
    docker exec sigul-${COMPONENT} test -d /etc/pki/sigul || {
        echo "FAIL: /etc/pki/sigul not found in ${COMPONENT}"
        exit 1
    }
    docker exec sigul-${COMPONENT} test -d /var/lib/sigul || {
        echo "FAIL: /var/lib/sigul not found in ${COMPONENT}"
        exit 1
    }
done
echo "PASS: Directory structure correct"

# Test 1.2: Configuration files
echo "Test 1.2: Verifying configuration files..."
docker exec sigul-bridge test -f /etc/sigul/bridge.conf || {
    echo "FAIL: Bridge configuration not found"
    exit 1
}
docker exec sigul-server test -f /etc/sigul/server.conf || {
    echo "FAIL: Server configuration not found"
    exit 1
}
echo "PASS: Configuration files present"

# Phase 2: Certificate Tests
echo -e "\nPhase 2: Certificate Validation"

# Test 2.1: NSS database format
echo "Test 2.1: Verifying NSS database format..."
for COMPONENT in bridge server; do
    docker exec sigul-${COMPONENT} file /etc/pki/sigul/cert9.db | grep -q "SQLite" || {
        echo "FAIL: cert9.db not in modern format for ${COMPONENT}"
        exit 1
    }
done
echo "PASS: Modern NSS format confirmed"

# Test 2.2: Certificate presence
echo "Test 2.2: Verifying certificates..."
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul | grep -q "sigul-bridge.example.org" || {
    echo "FAIL: Bridge certificate not found"
    exit 1
}
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul | grep -q "sigul-server.example.org" || {
    echo "FAIL: Server certificate not found"
    exit 1
}
echo "PASS: Certificates present"

# Phase 3: Network Tests
echo -e "\nPhase 3: Network Connectivity"

# Test 3.1: Bridge listening
echo "Test 3.1: Verifying bridge listening..."
docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -q "44333" || {
    echo "FAIL: Bridge not listening on port 44333"
    exit 1
}
docker exec sigul-bridge netstat -tlnp 2>/dev/null | grep -q "44334" || {
    echo "FAIL: Bridge not listening on port 44334"
    exit 1
}
echo "PASS: Bridge listening on correct ports"

# Test 3.2: Server connectivity
echo "Test 3.2: Verifying server connectivity..."
docker exec sigul-server nc -zv ${BRIDGE_HOST} ${BRIDGE_PORT} 2>&1 | grep -q "succeeded" || {
    echo "FAIL: Server cannot reach bridge"
    exit 1
}
echo "PASS: Server can reach bridge"

# Phase 4: Service Tests
echo -e "\nPhase 4: Service Functionality"

# Test 4.1: Process running
echo "Test 4.1: Verifying processes..."
docker exec sigul-bridge pgrep -f sigul_bridge > /dev/null || {
    echo "FAIL: Bridge process not running"
    exit 1
}
docker exec sigul-server pgrep -f sigul_server > /dev/null || {
    echo "FAIL: Server process not running"
    exit 1
}
echo "PASS: Services running"

# Test 4.2: Server database created
echo "Test 4.2: Verifying server database..."
docker exec sigul-server test -f /var/lib/sigul/server.sqlite || {
    echo "FAIL: Server database not created"
    exit 1
}
echo "PASS: Server database exists"

# Test 4.3: GnuPG home initialized
echo "Test 4.3: Verifying GnuPG home..."
docker exec sigul-server test -d /var/lib/sigul/gnupg || {
    echo "FAIL: GnuPG home not initialized"
    exit 1
}
echo "PASS: GnuPG home exists"

echo -e "\n=== All Integration Tests Passed ==="
```

### 7.2 Create Functional Test Suite

**New File:** `scripts/test-signing-operations.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "=== Sigul Functional Test Suite ==="

# This script tests actual signing operations
# Requires sigul client to be available

CLIENT_CONTAINER="sigul-client-test"
BRIDGE_HOST="sigul-bridge.example.org"
CLIENT_PORT="44334"
TEST_KEY_NAME="test-signing-key"
TEST_KEY_PASSPHRASE="test-passphrase-12345"

# Test 1: Create signing key
echo "Test 1: Creating test signing key..."
docker exec ${CLIENT_CONTAINER} sigul -vv \
    --batch \
    --gnupg-home=/tmp/test-gnupg \
    new-key \
    --key-admin=admin \
    --key-type=RSA \
    --key-length=2048 \
    ${TEST_KEY_NAME} \
    || {
    echo "FAIL: Could not create signing key"
    exit 1
}
echo "PASS: Signing key created"

# Test 2: List keys
echo "Test 2: Listing signing keys..."
docker exec ${CLIENT_CONTAINER} sigul -vv list-keys | grep -q "${TEST_KEY_NAME}" || {
    echo "FAIL: Created key not found in list"
    exit 1
}
echo "PASS: Key listing works"

# Test 3: Sign test file
echo "Test 3: Signing test file..."
echo "This is a test file" > /tmp/test-file.txt
docker cp /tmp/test-file.txt ${CLIENT_CONTAINER}:/tmp/
docker exec ${CLIENT_CONTAINER} sigul -vv \
    sign-text \
    -o /tmp/test-file.txt.asc \
    ${TEST_KEY_NAME} \
    /tmp/test-file.txt \
    || {
    echo "FAIL: Could not sign test file"
    exit 1
}
echo "PASS: File signing works"

# Test 4: Verify signature
echo "Test 4: Verifying signature..."
docker exec ${CLIENT_CONTAINER} gpg --verify /tmp/test-file.txt.asc /tmp/test-file.txt || {
    echo "FAIL: Signature verification failed"
    exit 1
}
echo "PASS: Signature verification works"

echo -e "\n=== All Functional Tests Passed ==="
```

Make executable:

```bash
chmod +x scripts/test-signing-operations.sh
```

### 7.3 Create Performance Test Suite

**New File:** `scripts/test-performance.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "=== Sigul Performance Test Suite ==="

# Test connection establishment time
echo "Test 1: Connection establishment..."
START=$(date +%s)
for i in {1..10}; do
    docker exec sigul-server nc -zv sigul-bridge.example.org 44333 2>&1 | grep -q "succeeded"
done
END=$(date +%s)
DURATION=$((END - START))
echo "10 connections established in ${DURATION}s (avg: $((DURATION/10))s per connection)"

# Test certificate validation time
echo -e "\nTest 2: Certificate validation..."
START=$(date +%s)
for i in {1..10}; do
    docker exec sigul-bridge certutil -V -n "sigul-bridge.example.org" -u V -d sql:/etc/pki/sigul > /dev/null
done
END=$(date +%s)
DURATION=$((END - START))
echo "10 certificate validations in ${DURATION}s"

# Test database query time
echo -e "\nTest 3: Database operations..."
START=$(date +%s)
for i in {1..10}; do
    docker exec sigul-server sqlite3 /var/lib/sigul/server.sqlite "SELECT COUNT(*) FROM users;" > /dev/null 2>&1 || true
done
END=$(date +%s)
DURATION=$((END - START))
echo "10 database queries in ${DURATION}s"

echo -e "\n=== Performance Tests Complete ==="
```

Make executable:

```bash
chmod +x scripts/test-performance.sh
```

### 7.4 Update Test Infrastructure Script

**File:** `scripts/test-infrastructure.sh`

Update to use new paths and validation:

```bash
#!/bin/bash
set -euo pipefail

echo "=== Sigul Infrastructure Test ==="

# Run all validation scripts
./scripts/verify-dns.sh bridge
./scripts/verify-dns.sh server
./scripts/verify-network.sh
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server
./scripts/validate-configs.sh bridge
./scripts/validate-configs.sh server

# Run integration tests
./scripts/run-integration-tests.sh

echo -e "\n=== Infrastructure Tests Complete ==="
```

### 7.5 Validation

**Test Procedure:**

```bash
# Deploy complete stack
./scripts/deploy-sigul-infrastructure.sh

# Run infrastructure tests
./scripts/test-infrastructure.sh

# Run integration tests
./scripts/run-integration-tests.sh

# Run performance tests (optional)
./scripts/test-performance.sh

# If client container available, run functional tests
# ./scripts/test-signing-operations.sh
```

**Expected Results:**

- All infrastructure tests pass
- All integration tests pass
- Services remain stable under load
- No certificate validation errors
- Network connectivity stable

**Exit Criteria:**

- [ ] Integration test suite updated and working
- [ ] Functional test suite created
- [ ] Performance test suite created
- [ ] Test infrastructure script updated
- [ ] All tests pass consistently
- [ ] No regressions in existing functionality

---

## Phase 8: Documentation & Validation

**Goal:** Comprehensive documentation and final validation

**Priority:** MEDIUM

### 8.1 Update README.md

Update main README with new directory structure and deployment process:

```markdown
# Sigul Container Stack

Production-aligned containerized deployment of Sigul signing infrastructure.

## Architecture

- **Bridge**: Proxy component for client-server communication
- **Server**: Core signing service with GPG key management
- **Client**: Command-line interface for signing operations

## Directory Structure

```

/etc/sigul/          # Configuration files
/etc/pki/sigul/      # NSS certificate database
/var/lib/sigul/      # Persistent data (database, GPG keys)
/var/log/sigul/      # Log files

```

## Quick Start

```bash
# Generate NSS password
export NSS_PASSWORD=$(openssl rand -base64 32)

# Deploy infrastructure
./scripts/deploy-sigul-infrastructure.sh

# Verify deployment
./scripts/test-infrastructure.sh
```

## Configuration

Configuration files are generated from templates in `configs/`:

- `bridge.conf.template` - Bridge configuration
- `server.conf.template` - Server configuration

## Certificate Management

Certificates use FQDN-based naming with SAN extensions:

- CA: `CN=Sigul CA`
- Bridge: `CN=sigul-bridge.example.org`
- Server: `CN=sigul-server.example.org`

Modern NSS database format (cert9.db) is used.

## Volumes

Critical data is stored in Docker volumes:

- `sigul_bridge_nss` - Bridge certificates (backup priority: HIGH)
- `sigul_server_nss` - Server certificates (backup priority: HIGH)
- `sigul_server_data` - Database and GPG keys (backup priority: CRITICAL)

Backup: `./scripts/backup-volumes.sh`
Restore: `./scripts/restore-volumes.sh <volume-name> <backup-file>`

```

### 8.2 Create Deployment Guide

**New File:** `DEPLOYMENT_PRODUCTION_ALIGNED.md`

```markdown
# Production-Aligned Deployment Guide

This guide covers deployment of the production-aligned Sigul container stack.

## Prerequisites

- Docker 20.10+
- Docker Compose 1.29+
- Minimum 2GB RAM
- 10GB disk space

## Deployment Steps

### 1. Clone Repository

```bash
git clone <repository-url>
cd sigul-sign-docker
```

### 2. Generate Secrets

```bash
# Generate NSS password (save securely!)
export NSS_PASSWORD=$(openssl rand -base64 32)
echo "NSS_PASSWORD=${NSS_PASSWORD}" > .env
chmod 600 .env
```

### 3. Customize Configuration (Optional)

```bash
# Edit templates if needed
vi configs/bridge.conf.template
vi configs/server.conf.template

# Update FQDNs if not using defaults
export BRIDGE_FQDN="my-bridge.example.com"
export SERVER_FQDN="my-server.example.com"
```

### 4. Deploy Infrastructure

```bash
./scripts/deploy-sigul-infrastructure.sh
```

### 5. Verify Deployment

```bash
./scripts/test-infrastructure.sh
```

### 6. Check Service Status

```bash
docker-compose -f docker-compose.sigul.yml ps
docker-compose -f docker-compose.sigul.yml logs
```

## Troubleshooting

### Services Not Starting

Check logs:

```bash
docker logs sigul-bridge
docker logs sigul-server
```

Common issues:

- Certificate not found: Re-run certificate generation
- Permission denied: Check volume ownership
- Connection refused: Verify network configuration

### Certificate Issues

Verify certificates:

```bash
./scripts/validate-certificates.sh
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server
```

### Network Issues

Test connectivity:

```bash
./scripts/verify-dns.sh bridge
./scripts/verify-dns.sh server
./scripts/verify-network.sh
```

## Maintenance

### Backup

```bash
# Backup all critical volumes
./scripts/backup-volumes.sh

# Backups stored in: ./backups/
```

### Restore

```bash
# Stop services
docker-compose -f docker-compose.sigul.yml down

# Restore specific volume
./scripts/restore-volumes.sh sigul_server_data backups/sigul_server_data-<timestamp>.tar.gz

# Restart services
docker-compose -f docker-compose.sigul.yml up -d
```

### Upgrade

```bash
# Backup before upgrade
./scripts/backup-volumes.sh

# Pull latest changes
git pull

# Rebuild containers
docker-compose -f docker-compose.sigul.yml build

# Restart services
docker-compose -f docker-compose.sigul.yml up -d

# Verify
./scripts/test-infrastructure.sh
```

```

### 8.3 Create Operations Guide

**New File:** `OPERATIONS_GUIDE.md`

```markdown
# Operations Guide

## Daily Operations

### Monitoring

Check service health:
```bash
docker-compose -f docker-compose.sigul.yml ps
```

View logs:

```bash
docker-compose -f docker-compose.sigul.yml logs -f
```

### Health Checks

```bash
# Quick health check
docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}"

# Detailed infrastructure check
./scripts/test-infrastructure.sh
```

## Common Tasks

### View Signing Keys

```bash
docker exec sigul-server ls -la /var/lib/sigul/gnupg
```

### Check Database

```bash
docker exec sigul-server sqlite3 /var/lib/sigul/server.sqlite "SELECT * FROM users;"
```

### Rotate Certificates

```bash
# Backup current certificates
./scripts/backup-volumes.sh

# Generate new certificates
docker-compose -f docker-compose.sigul.yml down
docker volume rm sigul_bridge_nss sigul_server_nss

# Redeploy
./scripts/deploy-sigul-infrastructure.sh
```

## Incident Response

### Service Crashed

```bash
# View crash logs
docker logs sigul-<component> --tail 100

# Restart service
docker-compose -f docker-compose.sigul.yml restart sigul-<component>
```

### Database Corruption

```bash
# Stop services
docker-compose -f docker-compose.sigul.yml down

# Restore from backup
./scripts/restore-volumes.sh sigul_server_data <backup-file>

# Restart
docker-compose -f docker-compose.sigul.yml up -d
```

### Certificate Expiry

Certificates are valid for 10 years. Monitor expiry:

```bash
docker exec sigul-bridge certutil -L -n "sigul-bridge.example.org" -d sql:/etc/pki/sigul | grep "Not After"
```

```

### 8.4 Update DEPLOYMENT_GUIDE.md

**File:** `DEPLOYMENT_GUIDE.md`

Add section referencing new production-aligned deployment:

```markdown
## Production-Aligned Deployment

For deployment aligned with production configuration patterns, see:
- [DEPLOYMENT_PRODUCTION_ALIGNED.md](DEPLOYMENT_PRODUCTION_ALIGNED.md)
- [ALIGNMENT_PLAN.md](ALIGNMENT_PLAN.md)

This deployment uses:
- FHS-compliant directory structure
- FQDN-based certificates
- Modern NSS format (cert9.db)
- Production-verified configuration patterns
```

### 8.5 Final Validation Checklist

Create comprehensive validation checklist:

**New File:** `VALIDATION_CHECKLIST.md`

```markdown
# Validation Checklist

## Pre-Deployment
- [ ] Docker and Docker Compose installed
- [ ] Required ports available (44333, 44334)
- [ ] Sufficient disk space (10GB+)
- [ ] NSS password generated and saved

## Deployment
- [ ] Configuration files generated
- [ ] Certificates generated successfully
- [ ] Docker volumes created
- [ ] Services started successfully
- [ ] Healthchecks passing

## Infrastructure Validation
- [ ] Directory structure correct (/etc/sigul, /etc/pki/sigul, /var/lib/sigul)
- [ ] Configuration files in correct locations
- [ ] File permissions correct (NSS DB: 700, configs: 600)
- [ ] File ownership correct (sigul:sigul)

## Certificate Validation
- [ ] NSS database in modern format (cert9.db)
- [ ] CA certificate present with CT,, trust flags
- [ ] Component certificates present with u,u,u trust flags
- [ ] Certificate CNs match FQDNs
- [ ] SANs include FQDNs
- [ ] Extended Key Usage includes serverAuth and clientAuth

## Network Validation
- [ ] Bridge listening on 0.0.0.0:44333
- [ ] Bridge listening on 0.0.0.0:44334
- [ ] Server can connect to bridge
- [ ] Hostname resolution working
- [ ] DNS aliases configured

## Service Validation
- [ ] Bridge process running with correct command
- [ ] Server process running with correct command
- [ ] Server database created at /var/lib/sigul/server.sqlite
- [ ] GnuPG home initialized at /var/lib/sigul/gnupg
- [ ] Log files being created
- [ ] No error messages in logs

## Functional Validation
- [ ] Integration tests pass
- [ ] Configuration parsing succeeds
- [ ] Certificate validation succeeds
- [ ] TLS connection established
- [ ] (Optional) Signing operations work

## Backup Validation
- [ ] Backup script executes successfully
- [ ] Backup files created
- [ ] Restore script tested
- [ ] Backup schedule configured

## Documentation
- [ ] README.md updated
- [ ] Deployment guide available
- [ ] Operations guide available
- [ ] Troubleshooting documented
```

### 8.6 Validation

**Test Procedure:**

```bash
# Complete deployment from scratch
./scripts/deploy-sigul-infrastructure.sh

# Run complete validation
./scripts/test-infrastructure.sh

# Go through validation checklist
cat VALIDATION_CHECKLIST.md

# Verify documentation is complete
ls -la *.md
```

**Expected Results:**

- All documentation files present and accurate
- Validation checklist can be completed successfully
- Deployment guide leads to successful deployment
- Operations guide covers common tasks

**Exit Criteria:**

- [ ] README.md updated
- [ ] DEPLOYMENT_PRODUCTION_ALIGNED.md created
- [ ] OPERATIONS_GUIDE.md created
- [ ] VALIDATION_CHECKLIST.md created
- [ ] DEPLOYMENT_GUIDE.md updated
- [ ] All documentation reviewed and accurate
- [ ] Complete deployment validated end-to-end

---

## Success Criteria

The alignment is considered successful when all of the following criteria are met:

### Infrastructure Criteria

- [ ] **Directory Structure**: All paths follow FHS standard
  - `/etc/sigul/` for configurations
  - `/etc/pki/sigul/` for NSS databases
  - `/var/lib/sigul/` for persistent data
  - `/var/log/sigul/` for logs

- [ ] **File Permissions**: All files have correct ownership and permissions
  - NSS databases: 700, sigul:sigul
  - Configuration files: 600, sigul:sigul
  - Data directories: 755, sigul:sigul
  - GnuPG home: 700, sigul:sigul

### Certificate Criteria

- [ ] **NSS Format**: Modern cert9.db format (SQLite)
- [ ] **CA Certificate**: Present with CT,, trust flags
- [ ] **Component Certificates**: Present with u,u,u trust flags
- [ ] **Certificate Naming**: CNs match FQDNs
- [ ] **SAN Extensions**: All certificates include SAN with FQDN
- [ ] **Extended Key Usage**: serverAuth + clientAuth on all component certs
- [ ] **Key Size**: 2048+ bit RSA keys
- [ ] **Signature**: SHA256 or better

### Configuration Criteria

- [ ] **File Location**: Configs in `/etc/sigul/`
- [ ] **Section Structure**: Matches production pattern
- [ ] **NSS Password**: Embedded in config files (not external file)
- [ ] **Certificate Nicknames**: Use FQDNs
- [ ] **Bridge Hostname**: Uses FQDN
- [ ] **TLS Versions**: Min TLS 1.2, Max TLS 1.3
- [ ] **Database Path**: `/var/lib/sigul/server.sqlite`
- [ ] **GnuPG Home**: `/var/lib/sigul/gnupg`

### Service Criteria

- [ ] **Bridge Startup**: Direct invocation with `-v` flag
- [ ] **Server Startup**: Direct invocation with production flags
- [ ] **No Wrapper Scripts**: Simple entrypoints only
- [ ] **Process Names**: Match production pattern
- [ ] **User Context**: Running as sigul:sigul

### Network Criteria

- [ ] **Bridge Listening**: 0.0.0.0:44333 and 0.0.0.0:44334
- [ ] **Server Connection**: Established to bridge
- [ ] **Hostname Resolution**: FQDNs resolve correctly
- [ ] **DNS Aliases**: Configured in Docker network
- [ ] **TLS Validation**: Certificate hostname validation succeeds

### Operational Criteria

- [ ] **Services Start**: Both services start without errors
- [ ] **Healthchecks Pass**: Docker healthchecks report healthy
- [ ] **Database Created**: Server database exists and has schema
- [ ] **GnuPG Initialized**: GnuPG home directory exists
- [ ] **Logs Generated**: Log files being written
- [ ] **No Critical Errors**: No blocking errors in logs

### Testing Criteria

- [ ] **Integration Tests**: All tests pass
- [ ] **Configuration Validation**: Parsing succeeds
- [ ] **Certificate Validation**: Chain validation succeeds
- [ ] **Network Validation**: Connectivity tests pass
- [ ] **Volume Persistence**: Data survives container restart
- [ ] **Backup/Restore**: Backup and restore cycle succeeds

### Documentation Criteria

- [ ] **README Updated**: Reflects new structure
- [ ] **Deployment Guide**: Complete and accurate
- [ ] **Operations Guide**: Covers common tasks
- [ ] **Validation Checklist**: Comprehensive and usable
- [ ] **Troubleshooting**: Common issues documented

---

## Rollback Strategy

### When to Rollback

Rollback if:

- Critical functionality is broken
- Services fail to start after multiple attempts
- Data corruption is detected
- Security vulnerabilities are introduced
- Deployment cannot complete after 2 hours

### Rollback Procedure

#### Phase 1: Immediate Rollback (If needed during deployment)

```bash
# Stop current deployment
docker-compose -f docker-compose.sigul.yml down

# Switch to backup branch
git checkout backup/pre-alignment-$(date +%Y%m%d)

# Restore previous configuration
docker-compose -f docker-compose.sigul.yml up -d

# Verify services
docker-compose -f docker-compose.sigul.yml ps
```

#### Phase 2: Restore from Volume Backups (If data corruption)

```bash
# Stop services
docker-compose -f docker-compose.sigul.yml down

# List available backups
ls -lh backups/

# Restore critical volumes
./scripts/restore-volumes.sh sigul_server_data backups/sigul_server_data-<timestamp>.tar.gz
./scripts/restore-volumes.sh sigul_bridge_nss backups/sigul_bridge_nss-<timestamp>.tar.gz
./scripts/restore-volumes.sh sigul_server_nss backups/sigul_server_nss-<timestamp>.tar.gz

# Restart services
docker-compose -f docker-compose.sigul.yml up -d

# Verify restoration
./scripts/test-infrastructure.sh
```

#### Phase 3: Document Rollback

```bash
# Create rollback report
cat > ROLLBACK_REPORT.md << EOF
# Rollback Report

**Date:** $(date)
**Reason:** <describe reason>
**Phase Reached:** <phase number>
**Issues Encountered:** <list issues>

## Actions Taken
1. Stopped services
2. Restored from backup branch / volumes
3. Verified services operational

## Lessons Learned
<document what went wrong>

## Next Steps
<plan for retry>
EOF
```

### Post-Rollback Actions

1. **Analyze Failure**:
   - Review logs: `docker logs sigul-bridge`, `docker logs sigul-server`
   - Check diagnostics: `./scripts/collect-sigul-diagnostics.sh`
   - Review git diff: `git diff backup/pre-alignment-$(date +%Y%m%d) feature/production-alignment`

2. **Fix Issues**:
   - Address root cause
   - Test fix in isolation
   - Update alignment plan if needed

3. **Retry Deployment**:
   - Schedule new deployment window
   - Ensure all prerequisites met
   - Consider phased rollout

### Rollback Prevention

- **Test thoroughly** before each phase
- **Backup before each phase**
- **Validate after each phase**
- **Document issues immediately**
- **Don't skip validation steps**

---

## Appendix A: File Modification Checklist

### Dockerfiles

- [ ] `Dockerfile.bridge`
  - [ ] Directory structure updated
  - [ ] Entrypoint script copied
  - [ ] Certificate generation script copied
  - [ ] User context set

- [ ] `Dockerfile.server`
  - [ ] Directory structure updated
  - [ ] Entrypoint script copied
  - [ ] Certificate generation script copied
  - [ ] GnuPG directory creation
  - [ ] User context set

- [ ] `Dockerfile.client` (if applicable)
  - [ ] Directory structure updated
  - [ ] Configuration paths updated

### Scripts

- [ ] `scripts/deploy-sigul-infrastructure.sh`
  - [ ] Configuration generation added
  - [ ] Certificate generation added
  - [ ] Volume initialization added
  - [ ] Service startup updated

- [ ] `scripts/generate-configs.sh` (new)
  - [ ] Created from templates
  - [ ] Variable substitution
  - [ ] Permission setting

- [ ] `scripts/entrypoint-bridge.sh` (new)
  - [ ] Validation logic
  - [ ] Production-aligned startup command

- [ ] `scripts/entrypoint-server.sh` (new)
  - [ ] Bridge availability check
  - [ ] Validation logic
  - [ ] Production-aligned startup command

- [ ] `scripts/run-integration-tests.sh`
  - [ ] Updated for new paths
  - [ ] New test cases added

- [ ] `scripts/validate-configs.sh` (new)
  - [ ] Configuration parsing test
  - [ ] Required sections check

- [ ] `scripts/validate-certificates.sh` (new)
  - [ ] Certificate presence check
  - [ ] Trust flags verification
  - [ ] SAN validation

- [ ] `scripts/verify-dns.sh` (new)
  - [ ] Hostname resolution test
  - [ ] FQDN validation

- [ ] `scripts/verify-network.sh` (new)
  - [ ] Port listening check
  - [ ] Connectivity test

- [ ] `scripts/verify-cert-hostname-alignment.sh` (new)
  - [ ] CN-hostname match
  - [ ] SAN validation

- [ ] `scripts/backup-volumes.sh` (new)
  - [ ] Volume enumeration
  - [ ] Tar creation
  - [ ] Timestamp naming

- [ ] `scripts/restore-volumes.sh` (new)
  - [ ] Backup file validation
  - [ ] Volume recreation
  - [ ] Data restoration

### Configuration Templates

- [ ] `configs/bridge.conf.template` (new)
  - [ ] Production-aligned structure
  - [ ] NSS password placeholder
  - [ ] FQDN certificate nickname

- [ ] `configs/server.conf.template` (new)
  - [ ] Production-aligned structure
  - [ ] NSS password placeholder
  - [ ] FQDN certificate nickname
  - [ ] FQDN bridge hostname
  - [ ] Correct database path
  - [ ] Correct GnuPG path

### PKI Scripts

- [ ] `pki/generate-production-aligned-certs.sh` (new)
  - [ ] Modern NSS format
  - [ ] FQDN-based CNs
  - [ ] SAN extensions
  - [ ] Extended Key Usage
  - [ ] Proper trust flags

### Docker Compose

- [ ] `docker-compose.sigul.yml`
  - [ ] Volume mounts updated
  - [ ] Network configuration updated
  - [ ] Hostname configuration updated
  - [ ] Environment variables added
  - [ ] Healthchecks added
  - [ ] Volume definitions updated

### Documentation

- [ ] `README.md`
  - [ ] Architecture section updated
  - [ ] Quick start updated
  - [ ] Directory structure documented

- [ ] `DEPLOYMENT_GUIDE.md`
  - [ ] Reference to production-aligned deployment added

- [ ] `DEPLOYMENT_PRODUCTION_ALIGNED.md` (new)
  - [ ] Complete deployment procedure
  - [ ] Troubleshooting section
  - [ ] Maintenance procedures

- [ ] `OPERATIONS_GUIDE.md` (new)
  - [ ] Daily operations
  - [ ] Common tasks
  - [ ] Incident response

- [ ] `VALIDATION_CHECKLIST.md` (new)
  - [ ] Comprehensive checklist
  - [ ] All validation points covered

---

## Appendix B: Testing Procedures

### Manual Testing Procedure

Execute tests in this order after each phase:

#### Infrastructure Tests

```bash
# Test 1: Directory structure
for COMPONENT in bridge server; do
    echo "Testing ${COMPONENT}..."
    docker exec sigul-${COMPONENT} ls -la /etc/sigul/
    docker exec sigul-${COMPONENT} ls -la /etc/pki/sigul/
    docker exec sigul-${COMPONENT} ls -la /var/lib/sigul/
    docker exec sigul-${COMPONENT} ls -la /var/log/sigul/
done

# Test 2: File permissions
docker exec sigul-bridge stat -c "%a %U:%G %n" /etc/pki/sigul
docker exec sigul-server stat -c "%a %U:%G %n" /var/lib/sigul/gnupg

# Test 3: Configuration files
docker exec sigul-bridge cat /etc/sigul/bridge.conf
docker exec sigul-server cat /etc/sigul/server.conf
```

#### Certificate Tests

```bash
# Test 4: NSS database format
docker exec sigul-bridge file /etc/pki/sigul/cert9.db
docker exec sigul-server file /etc/pki/sigul/cert9.db

# Test 5: Certificate listing
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul

# Test 6: Certificate details
docker exec sigul-bridge certutil -L -n "sigul-bridge.example.org" -d sql:/etc/pki/sigul
docker exec sigul-server certutil -L -n "sigul-server.example.org" -d sql:/etc/pki/sigul

# Test 7: Trust flags
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul | grep "CT,,"
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul | grep "u,u,u"
```

#### Network Tests

```bash
# Test 8: Bridge listening
docker exec sigul-bridge netstat -tlnp | grep 44333
docker exec sigul-bridge netstat -tlnp | grep 44334

# Test 9: Server connectivity
docker exec sigul-server nc -zv sigul-bridge.example.org 44333

# Test 10: DNS resolution
docker exec sigul-server getent hosts sigul-bridge.example.org
docker exec sigul-bridge hostname
docker exec sigul-server hostname
```

#### Service Tests

```bash
# Test 11: Process check
docker exec sigul-bridge pgrep -af sigul_bridge
docker exec sigul-server pgrep -af sigul_server

# Test 12: Service logs
docker logs sigul-bridge --tail 50
docker logs sigul-server --tail 50

# Test 13: Database
docker exec sigul-server ls -la /var/lib/sigul/server.sqlite
docker exec sigul-server sqlite3 /var/lib/sigul/server.sqlite ".schema"

# Test 14: GnuPG
docker exec sigul-server ls -la /var/lib/sigul/gnupg/
```

### Automated Testing Procedure

```bash
# Run all automated tests
./scripts/test-infrastructure.sh
./scripts/run-integration-tests.sh

# Verify output
# All tests should show PASS
# No FAIL messages
# No ERROR messages
```

### Performance Baseline

Establish performance baselines:

```bash
# Connection time
time docker exec sigul-server nc -zv sigul-bridge.example.org 44333

# Certificate validation
time docker exec sigul-bridge certutil -V -n "sigul-bridge.example.org" -u V -d sql:/etc/pki/sigul

# Configuration parsing
time docker exec sigul-bridge python3 -c "import configparser; c = configparser.ConfigParser(); c.read('/etc/sigul/bridge.conf')"
```

Record baselines in `PERFORMANCE_BASELINE.md` for future comparison.

---

## Appendix C: Troubleshooting Guide

### Common Issues and Solutions

#### Issue: Services fail to start

**Symptoms:**

- Container exits immediately
- "Configuration file not found" error
- "Certificate not found" error

**Solutions:**

```bash
# Check logs
docker logs sigul-bridge
docker logs sigul-server

# Verify configuration files exist
docker exec sigul-bridge test -f /etc/sigul/bridge.conf && echo "OK" || echo "MISSING"
docker exec sigul-server test -f /etc/sigul/server.conf && echo "OK" || echo "MISSING"

# Verify certificates exist
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul

# Regenerate if needed
./scripts/deploy-sigul-infrastructure.sh
```

#### Issue: Certificate validation fails

**Symptoms:**

- "Certificate not trusted" error
- "Hostname mismatch" error
- TLS connection fails

**Solutions:**

```bash
# Verify certificate CN matches hostname
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server

# Verify trust flags
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul | grep "CT,,"

# Regenerate certificates
docker-compose -f docker-compose.sigul.yml down
docker volume rm sigul_bridge_nss sigul_server_nss
./scripts/deploy-sigul-infrastructure.sh
```

#### Issue: Network connectivity problems

**Symptoms:**

- "Connection refused" error
- "Name or service not known" error
- Server can't reach bridge

**Solutions:**

```bash
# Verify DNS resolution
./scripts/verify-dns.sh bridge
./scripts/verify-dns.sh server

# Verify bridge is listening
docker exec sigul-bridge netstat -tlnp | grep 44333

# Check Docker network
docker network inspect sigul-network

# Restart network
docker-compose -f docker-compose.sigul.yml down
docker-compose -f docker-compose.sigul.yml up -d
```

#### Issue: Database not created

**Symptoms:**

- "Database file not found" error
- Server fails to start

**Solutions:**

```bash
# Verify directory exists
docker exec sigul-server test -d /var/lib/sigul && echo "OK" || echo "MISSING"

# Check permissions
docker exec sigul-server ls -la /var/lib/sigul/

# Verify volume mount
docker inspect sigul-server | grep -A10 Mounts

# Recreate with correct permissions
docker-compose -f docker-compose.sigul.yml down
docker volume rm sigul_server_data
docker-compose -f docker-compose.sigul.yml up -d
```

---

**End of Document**

```

**Expected Results:**
- All hostnames resolve to correct FQDNs
- Bridge listening on both ports
- Server can connect to bridge
- Certificate CNs match hostnames
- SANs include FQDNs
- TLS connection succeeds with proper certificate
