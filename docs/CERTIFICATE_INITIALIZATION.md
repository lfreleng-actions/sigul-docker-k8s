<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Certificate Initialization System

**Version:** 1.0.0
**Date:** 2025-01-16
**Status:** Production Ready

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Deployment Scenarios](#deployment-scenarios)
- [Initialization Modes](#initialization-modes)
- [Usage Examples](#usage-examples)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Integration with Backup/Restore](#integration-with-backuprestore)
- [Security Considerations](#security-considerations)
- [Migration Guide](#migration-guide)

---

## Overview

The Sigul container stack uses an **init container pattern** with **intelligent certificate initialization** to handle multiple deployment scenarios:

- ✅ **CI Testing** - Fresh certificates generated automatically
- ✅ **Production First Deploy** - Certificates generated on first start
- ✅ **Production Restart** - Existing certificates preserved
- ✅ **Volume Restore** - Restored certificates respected
- ✅ **Disaster Recovery** - Forced regeneration when needed

### Key Features

- **Smart Detection**: Automatically detects if certificates exist
- **Safe by Default**: Never regenerates existing certificates
- **Explicit Control**: Operator can force regeneration when needed
- **Backup Compatible**: Works seamlessly with volume restore
- **Self-Healing**: Missing certificates auto-generated
- **Production-Aligned**: Follows FHS paths and production patterns

---

## Architecture

### Container Flow

```
┌─────────────────────────────────────────────────────────────┐
│ 1. cert-init Container Starts                               │
│    - Runs before all other services                         │
│    - Checks if certificates exist                           │
│    - Generates certificates if needed                       │
│    - Generates config files if needed                       │
│    - Exits when complete                                    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. sigul-bridge Container Starts                            │
│    - Waits for cert-init to complete                        │
│    - Validates certificates exist                           │
│    - Starts listening on ports 44333, 44334                 │
│    - Reports healthy when ready                             │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. sigul-server Container Starts                            │
│    - Waits for cert-init to complete                        │
│    - Waits for bridge to be healthy                         │
│    - Validates certificates exist                           │
│    - Connects to bridge                                     │
│    - Starts processing requests                             │
└─────────────────────────────────────────────────────────────┘
```

### Certificate Dependencies

```
cert-init Container
├── Generates CA certificate (sigul-ca)
├── Generates bridge certificate (sigul-bridge-cert)
│   └── Signed by CA
├── Generates server certificate (sigul-server-cert)
│   └── Signed by CA
└── Creates configuration files
    ├── /etc/sigul/bridge.conf
    └── /etc/sigul/server.conf
```

### Volume Mounts

The `cert-init` container mounts all certificate volumes:

```yaml
volumes:
  - sigul_bridge_config:/etc/sigul:rw          # Bridge configuration
  - sigul_bridge_nss:/etc/pki/sigul/bridge:rw  # Bridge NSS database
  - sigul_server_config:/etc/sigul:rw          # Server configuration
  - sigul_server_nss:/etc/pki/sigul/server:rw  # Server NSS database
```

---

## Deployment Scenarios

### Scenario 1: CI Testing (Ephemeral)

**Characteristics:**
- Fresh volumes every time
- No pre-existing state
- Fast initialization required

**How it works:**

```bash
# Default mode is 'auto' - detects empty volumes and generates certificates
docker compose -f docker-compose.sigul.yml up -d
```

**Expected behavior:**
1. `cert-init` starts
2. Detects empty volumes
3. Generates certificates
4. Exits successfully
5. Services start with new certificates

**Teardown:**

```bash
# Complete cleanup for next run
docker compose -f docker-compose.sigul.yml down -v
```

---

### Scenario 2: Production First Deploy

**Characteristics:**
- Fresh volumes
- Long-lived certificates
- Should persist across restarts

**How it works:**

```bash
# First deployment - certificates generated
docker compose -f docker-compose.sigul.yml up -d

# Verify certificates were created
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge
```

**Expected behavior:**
1. `cert-init` starts
2. Detects empty volumes
3. Generates certificates with 120-month validity
4. Creates configuration files
5. Services start
6. **Certificates persist in volumes**

**Important:** After first deploy, certificates are stored in Docker volumes and will be reused on restart.

---

### Scenario 3: Production Restart

**Characteristics:**
- Existing volumes with certificates
- Must preserve trust chain
- Fast restart required

**How it works:**

```bash
# Restart services (preserves existing certificates)
docker compose -f docker-compose.sigul.yml restart

# Or stop and start (volumes remain)
docker compose -f docker-compose.sigul.yml down
docker compose -f docker-compose.sigul.yml up -d
```

**Expected behavior:**
1. `cert-init` starts
2. Detects existing certificates
3. Skips generation
4. Exits successfully (fast!)
5. Services start with existing certificates

**Important:** Note that we use `down` without `-v` flag to preserve volumes.

---

### Scenario 4: Volume Restore from Backup

**Characteristics:**
- Volumes restored from backup
- Certificates must not be regenerated
- Must preserve trust chain

**How it works:**

```bash
# 1. Stop services
docker compose -f docker-compose.sigul.yml down

# 2. Restore volumes from backup
./scripts/restore-volumes.sh sigul_server_data backups/sigul_server_data-20250116.tar.gz
./scripts/restore-volumes.sh sigul_bridge_nss backups/sigul_bridge_nss-20250116.tar.gz
./scripts/restore-volumes.sh sigul_server_nss backups/sigul_server_nss-20250116.tar.gz

# 3. Start services with SKIP mode (important!)
CERT_INIT_MODE=skip docker compose -f docker-compose.sigul.yml up -d
```

**Expected behavior:**
1. Volumes restored with certificates
2. `cert-init` runs in SKIP mode
3. No certificate checking or generation
4. Services start with restored certificates

**Important:** Use `CERT_INIT_MODE=skip` to prevent any certificate operations after restore.

---

### Scenario 5: Disaster Recovery (Force Regeneration)

**Characteristics:**
- Existing volumes with corrupted/expired certificates
- Need to regenerate entire trust chain
- Breaks existing trust (intentional)

**How it works:**

```bash
# Stop services
docker compose -f docker-compose.sigul.yml down

# Force certificate regeneration
CERT_INIT_MODE=force docker compose -f docker-compose.sigul.yml up -d
```

**Expected behavior:**
1. `cert-init` starts in FORCE mode
2. Removes existing NSS databases
3. Generates new CA and certificates
4. Services start with new trust chain

**⚠️ Warning:** This breaks the existing trust chain. All clients must be updated with new CA.

---

## Initialization Modes

The certificate initialization system supports three modes controlled by the `CERT_INIT_MODE` environment variable:

### Mode: `auto` (Default)

**Behavior:** Smart detection - generates only if missing

```bash
# Explicitly set (same as default)
CERT_INIT_MODE=auto docker compose -f docker-compose.sigul.yml up -d
```

**Decision Logic:**

```
1. Check if cert9.db exists in bridge NSS directory
2. Check if cert9.db exists in server NSS directory
3. Check if required certificates exist in databases
   - sigul-ca (CA certificate)
   - sigul-bridge-cert (bridge certificate)
   - sigul-server-cert (server certificate)
4. If ALL checks pass:
   → Skip generation (certificates exist)
5. If ANY check fails:
   → Generate certificates
```

**Use cases:**
- ✅ CI testing
- ✅ Production first deploy
- ✅ Production restart
- ✅ Self-healing after partial failure

**Safety:** ✅ Safe - never regenerates existing certificates

---

### Mode: `force`

**Behavior:** Force regeneration of all certificates

```bash
# Force regeneration (DANGEROUS in production!)
CERT_INIT_MODE=force docker compose -f docker-compose.sigul.yml up -d
```

**Decision Logic:**

```
1. Remove existing NSS database files
2. Generate new CA certificate
3. Generate new component certificates
4. No validation of existing state
```

**Use cases:**
- ✅ Disaster recovery
- ✅ Certificate corruption
- ✅ Testing certificate rotation
- ❌ NOT for normal restarts

**Safety:** ⚠️ **DANGEROUS** - breaks existing trust chain

**Warning Messages:**

```
⚠️  Running in FORCE mode (regenerating ALL certificates)
⚠️  This will break existing trust chains!
⚠️  Only use this for disaster recovery
```

---

### Mode: `skip`

**Behavior:** Skip all certificate operations

```bash
# Skip initialization entirely
CERT_INIT_MODE=skip docker compose -f docker-compose.sigul.yml up -d
```

**Decision Logic:**

```
1. Exit immediately
2. No certificate checking
3. No certificate generation
4. Assume certificates exist
```

**Use cases:**
- ✅ After volume restore
- ✅ Manual certificate management
- ✅ Testing with pre-generated certificates
- ✅ Custom PKI workflows

**Safety:** ✅ Safe - does nothing

**Note:** Service entrypoints will still validate certificates exist before starting.

---

## Usage Examples

### Example 1: Fresh CI Deployment

```bash
# Clean slate
docker compose -f docker-compose.sigul.yml down -v

# Start with fresh volumes (auto mode)
docker compose -f docker-compose.sigul.yml up -d

# Verify certificates were generated
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul/server

# Check cert-init logs
docker logs sigul-cert-init
```

---

### Example 2: Production Deployment with Custom FQDNs

```bash
# Set custom FQDNs
export BRIDGE_FQDN="bridge.sigul.example.com"
export SERVER_FQDN="server.sigul.example.com"
export NSS_PASSWORD="$(openssl rand -base64 32)"

# Deploy
docker compose -f docker-compose.sigul.yml up -d

# Verify certificate CN matches FQDN
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge -n sigul-bridge-cert
```

---

### Example 3: Volume Backup and Restore

```bash
# Create backup
./scripts/backup-volumes.sh --all

# Simulate disaster (remove volumes)
docker compose -f docker-compose.sigul.yml down -v

# Restore from backup
./scripts/restore-volumes.sh sigul_bridge_nss backups/sigul_bridge_nss-20250116.tar.gz
./scripts/restore-volumes.sh sigul_server_nss backups/sigul_server_nss-20250116.tar.gz
./scripts/restore-volumes.sh sigul_server_data backups/sigul_server_data-20250116.tar.gz

# Start with SKIP mode (don't touch restored certs)
CERT_INIT_MODE=skip docker compose -f docker-compose.sigul.yml up -d

# Verify restored certificates
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge
```

---

### Example 4: Certificate Rotation (Disaster Recovery)

```bash
# Stop services
docker compose -f docker-compose.sigul.yml down

# Force regeneration of entire PKI
CERT_INIT_MODE=force \
  NSS_PASSWORD="$(openssl rand -base64 32)" \
  docker compose -f docker-compose.sigul.yml up -d

# Verify new certificates
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge

# Export new CA for clients
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge \
  -n sigul-ca -a > new-ca.crt
```

---

### Example 5: Debugging Certificate Issues

```bash
# Check cert-init logs
docker logs sigul-cert-init

# Inspect volumes
docker run --rm \
  -v sigul-docker_sigul_bridge_nss:/nss:ro \
  alpine:latest \
  ls -la /nss

# Check certificate validity
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge -n sigul-ca

# Verify certificate details
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge \
  -n sigul-bridge-cert | openssl x509 -text -noout
```

---

## Configuration

### Environment Variables

| Variable | Default | Description | Required |
|----------|---------|-------------|----------|
| `CERT_INIT_MODE` | `auto` | Initialization mode: auto, force, skip | No |
| `NSS_PASSWORD` | (generated) | NSS database password | Yes |
| `BRIDGE_FQDN` | `sigul-bridge.example.org` | Bridge FQDN for certificate CN | No |
| `SERVER_FQDN` | `sigul-server.example.org` | Server FQDN for certificate CN | No |
| `CA_VALIDITY_MONTHS` | `120` | CA certificate validity in months | No |
| `CERT_VALIDITY_MONTHS` | `120` | Component certificate validity in months | No |
| `DEBUG` | `false` | Enable debug output | No |

### Certificate Nicknames (Standardized)

| Component | Certificate Nickname | Usage |
|-----------|---------------------|-------|
| CA | `sigul-ca` | Root CA for trust chain |
| Bridge | `sigul-bridge-cert` | Bridge TLS certificate |
| Server | `sigul-server-cert` | Server TLS certificate |

### File Paths (FHS-Compliant)

| Component | NSS Database | Configuration |
|-----------|--------------|---------------|
| Bridge | `/etc/pki/sigul/bridge/` | `/etc/sigul/bridge.conf` |
| Server | `/etc/pki/sigul/server/` | `/etc/sigul/server.conf` |

---

## Troubleshooting

### Issue: cert-init container fails

**Symptoms:**

```
Error response from daemon: failed to create task for container:
failed to create shim task: OCI runtime create failed
```

**Solution:**

```bash
# Check cert-init logs
docker logs sigul-cert-init

# Verify environment variables
docker compose -f docker-compose.sigul.yml config | grep -A 10 cert-init

# Check NSS_PASSWORD is set
echo $NSS_PASSWORD
```

---

### Issue: Certificates not found after init

**Symptoms:**

```
[BRIDGE] NSS database not found at /etc/pki/sigul/bridge/cert9.db
[BRIDGE] Cannot start bridge without certificates
```

**Solution:**

```bash
# Check if cert-init completed successfully
docker ps -a --filter "name=cert-init"

# Verify volumes exist
docker volume ls | grep sigul

# Inspect volume contents
docker run --rm -v sigul-docker_sigul_bridge_nss:/nss:ro alpine ls -la /nss

# Force regeneration
CERT_INIT_MODE=force docker compose -f docker-compose.sigul.yml up -d
```

---

### Issue: Certificates exist but invalid

**Symptoms:**

```
[BRIDGE] Certificate 'sigul-bridge-cert' not found in NSS database
Available certificates:
  (none)
```

**Solution:**

```bash
# Check NSS database health
docker run --rm -v sigul-docker_sigul_bridge_nss:/nss:ro \
  alpine sh -c "ls -la /nss && file /nss/*"

# Regenerate certificates
CERT_INIT_MODE=force docker compose -f docker-compose.sigul.yml up -d
```

---

### Issue: After volume restore, certificates regenerated

**Symptoms:**

```
🔧 Certificates missing or incomplete - initializing
```

**Cause:** Used `CERT_INIT_MODE=auto` after restore

**Solution:**

```bash
# Stop services
docker compose -f docker-compose.sigul.yml down

# Restore again
./scripts/restore-volumes.sh sigul_bridge_nss backups/sigul_bridge_nss-*.tar.gz

# Use SKIP mode to preserve restored certificates
CERT_INIT_MODE=skip docker compose -f docker-compose.sigul.yml up -d
```

---

## Integration with Backup/Restore

The certificate initialization system is fully compatible with the existing backup/restore workflow.

### Backup Workflow (No Changes Needed)

```bash
# Backup all volumes (includes certificates)
./scripts/backup-volumes.sh --all

# Critical volumes backed up:
# - sigul_bridge_nss (contains CA + bridge cert)
# - sigul_server_nss (contains CA + server cert)
# - sigul_server_data (contains database + GnuPG keys)
```

### Restore Workflow (Use SKIP Mode)

```bash
# 1. Stop services
docker compose -f docker-compose.sigul.yml down

# 2. Restore volumes
./scripts/restore-volumes.sh sigul_server_data backups/sigul_server_data-TIMESTAMP.tar.gz
./scripts/restore-volumes.sh sigul_bridge_nss backups/sigul_bridge_nss-TIMESTAMP.tar.gz
./scripts/restore-volumes.sh sigul_server_nss backups/sigul_server_nss-TIMESTAMP.tar.gz

# 3. Start with SKIP mode (important!)
CERT_INIT_MODE=skip docker compose -f docker-compose.sigul.yml up -d

# 4. Verify restored certificates
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge
```

**Key Point:** Always use `CERT_INIT_MODE=skip` after volume restore to preserve restored certificates.

---

## Security Considerations

### NSS Password Management

**Default Behavior:** Ephemeral password generated automatically

```bash
# Auto-generated (CI/testing)
docker compose -f docker-compose.sigul.yml up -d
```

**Production Recommendation:** Use explicit password from secrets management

```bash
# From Vault/Secrets Manager
export NSS_PASSWORD="$(vault kv get -field=password secret/sigul/nss)"
docker compose -f docker-compose.sigul.yml up -d

# From file
export NSS_PASSWORD="$(cat /run/secrets/nss-password)"
docker compose -f docker-compose.sigul.yml up -d
```

### Certificate Validity

**Defaults:**
- CA: 120 months (10 years)
- Components: 120 months (10 years)

**Production Recommendation:** Shorter validity for defense-in-depth

```bash
# 2-year certificates
CA_VALIDITY_MONTHS=24 \
CERT_VALIDITY_MONTHS=24 \
docker compose -f docker-compose.sigul.yml up -d
```

### Trust Chain Protection

**Critical:** The CA certificate in `sigul_bridge_nss` volume is the root of trust

**Protection:**
- ✅ Regular backups of `sigul_bridge_nss` volume
- ✅ Use `CERT_INIT_MODE=auto` (never regenerates existing CA)
- ✅ Use `CERT_INIT_MODE=skip` after restore
- ❌ Never use `CERT_INIT_MODE=force` in production without backup

---

## Migration Guide

### Migrating from Previous Setup

If you have an existing Sigul deployment without the cert-init system:

#### Step 1: Backup Current State

```bash
# Backup all volumes
./scripts/backup-volumes.sh --all

# Record current certificate info
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge > bridge-certs-before.txt
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul/server > server-certs-before.txt
```

#### Step 2: Update Code

```bash
# Pull latest changes
git pull origin main

# Rebuild images
docker compose -f docker-compose.sigul.yml build
```

#### Step 3: Deploy with Auto Mode

```bash
# Stop services
docker compose -f docker-compose.sigul.yml down

# Start with auto mode (detects existing certificates)
CERT_INIT_MODE=auto docker compose -f docker-compose.sigul.yml up -d

# Verify cert-init detected existing certificates
docker logs sigul-cert-init | grep "skipping initialization"
```

**Expected output:**

```
✅ Certificates already exist - skipping initialization
Bridge: ✓ | Server: ✓
Mode: AUTO → SKIP (certificates present)
```

#### Step 4: Verify No Changes

```bash
# Compare certificates (should be identical)
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge > bridge-certs-after.txt
diff bridge-certs-before.txt bridge-certs-after.txt

# Should show no differences
```

---

## Conclusion

The certificate initialization system provides:

- ✅ **Flexibility** - Handles CI, production, and disaster recovery
- ✅ **Safety** - Never accidentally breaks production trust chains
- ✅ **Automation** - Self-healing certificate generation
- ✅ **Control** - Explicit modes for different scenarios
- ✅ **Compatibility** - Works with existing backup/restore

**Quick Reference:**

| Scenario | Mode | Command |
|----------|------|---------|
| CI Testing | `auto` | `docker compose up -d` |
| Production First Deploy | `auto` | `docker compose up -d` |
| Production Restart | `auto` | `docker compose restart` |
| After Volume Restore | `skip` | `CERT_INIT_MODE=skip docker compose up -d` |
| Disaster Recovery | `force` | `CERT_INIT_MODE=force docker compose up -d` |

For additional support, see:
- [DEPLOYMENT_GUIDE.md](../DEPLOYMENT_GUIDE.md) - General deployment
- [OPERATIONS_GUIDE.md](../OPERATIONS_GUIDE.md) - Day-to-day operations
- [Phase Documentation](./PHASE8_COMPLETE.md) - Production alignment details
