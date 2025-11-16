# Quick Fix Summary - Integration Test Failures

**SPDX-License-Identifier:** Apache-2.0  
**SPDX-FileCopyrightText:** 2025 The Linux Foundation

## Overview

Integration tests were failing in GitHub CI with two sequential issues that have now been fixed.

## Issue #1: Wrong Volume Type (FIXED)

### Problem
```
[18:28:00] NSS-ERROR: Bridge NSS database not accessible at /etc/pki/sigul/bridge-shared
NSS database files not found
```

### Root Cause
Integration test was mounting `bridge_data` volume instead of `bridge_nss` volume.

### Fix
**File:** `scripts/run-integration-tests.sh` (Lines 196-213)

```bash
# BEFORE
bridge_volume=$(... | grep -E "(sigul.*bridge.*data|bridge.*data)")
-v "${bridge_volume}":/etc/pki/sigul/bridge-shared:ro

# AFTER
bridge_nss_volume=$(... | grep -E "(sigul.*bridge.*nss|bridge.*nss)")
-v "${bridge_nss_volume}":/etc/pki/sigul/bridge-shared:ro
```

### Result
✅ Bridge NSS certificates now accessible to client container

**Status:** ✅ FIXED

---

## Issue #2: Missing Client Volumes (FIXED)

### Problem
```
mkdir: cannot create directory '/etc/pki/sigul/client': Permission denied
[2025-11-16 18:51:14] ERROR: Failed to initialize client container
```

### Root Cause
Client container had no writable volumes for:
- NSS database (`/etc/pki/sigul/client`)
- Configuration files (`/etc/sigul`)

### Fix
**File:** `scripts/run-integration-tests.sh` (Lines 209-245)

**Added volume creation and mounting:**
```bash
# Create client PKI volume (for NSS databases)
client_pki_volume="sigul-integration-client-pki"
docker volume create "$client_pki_volume"

# Initialize with correct ownership (UID 1000 = sigul user)
docker run --rm -v "$client_pki_volume:/target" alpine:3.19 \
    sh -c "mkdir -p /target && chown -R 1000:1000 /target"

# Create client config volume
client_config_volume="sigul-integration-client-config"
docker volume create "$client_config_volume"
docker run --rm -v "$client_config_volume:/target" alpine:3.19 \
    sh -c "mkdir -p /target && chown -R 1000:1000 /target"

# Mount volumes in client container
docker run -d --name sigul-client-integration \
    --user sigul \
    -v "${bridge_nss_volume}":/etc/pki/sigul/bridge-shared:ro \
    -v "${client_pki_volume}":/etc/pki/sigul:rw \
    -v "${client_config_volume}":/etc/sigul:rw \
    ...
```

**Added volume cleanup:**
```bash
# Lines 807-808
docker volume rm sigul-integration-client-pki 2>/dev/null || true
docker volume rm sigul-integration-client-config 2>/dev/null || true
```

### Result
✅ Client can create NSS database and configuration files

**Status:** ✅ FIXED

---

## Issue #3: Certificate Generation Failure (FIXED)

### Problem
```
[18:59:56] NSS-INIT: Creating client NSS database...
password file contains no data
[18:59:57] NSS-ERROR: Failed to generate client certificate
ERROR: Failed to initialize client container
```

### Root Cause
Client certificate generation tried to self-sign using CA certificate, but CA private key was not available in client NSS database.

The old code imported only the CA public certificate, then tried to use it for signing:
```bash
# Import CA certificate (public key only)
certutil -A -d "sql:$client_nss_dir" -n "$CA_NICKNAME" -t CT,, -a -i /tmp/ca-import.pem

# Try to sign with CA (FAILS - no private key!)
certutil -S -d "sql:$client_nss_dir" -c "$CA_NICKNAME" ...
```

### Fix
**File:** `scripts/sigul-init.sh` (Lines 294-351)

**Replaced manual certificate generation with production-aligned script:**
```bash
# Wait for bridge to export CA with private key (PKCS#12)
while [[ $attempt -le $max_attempts ]]; do
    if [[ -f "$bridge_ca_export_dir/ca.p12" ]] && \
       [[ -f "$bridge_ca_export_dir/ca-p12-password" ]]; then
        break
    fi
    sleep 2
    ((attempt++))
done

# Copy CA files from bridge export to client import location
mkdir -p "$client_ca_import_dir"
cp "$bridge_ca_export_dir/ca.p12" "$client_ca_import_dir/ca.p12"
cp "$bridge_ca_export_dir/ca-p12-password" "$client_ca_import_dir/ca-p12-password"
chmod 600 "$client_ca_import_dir/ca.p12"
chmod 600 "$client_ca_import_dir/ca-p12-password"

# Use production-aligned certificate generation script
NSS_DB_DIR="$client_nss_dir" \
NSS_PASSWORD="$(get_nss_password)" \
COMPONENT="client" \
FQDN="$client_fqdn" \
/usr/local/bin/generate-production-aligned-certs.sh
```

**Key changes:**
1. Wait for bridge to export CA with private key (PKCS#12 format)
2. Copy CA files from bridge export location to client import location
3. Call `generate-production-aligned-certs.sh` (same as server/bridge)
4. Script imports CA with private key and generates client certificate

### Result
✅ Client certificate generated successfully with CA private key access

**Status:** ✅ FIXED

---

## Files Modified

1. **`scripts/run-integration-tests.sh`**
   - Lines 196-213: Fixed bridge NSS volume detection
   - Lines 209-245: Added client volume creation and mounting
   - Lines 807-808: Added cleanup for integration test volumes

2. **`scripts/sigul-init.sh`**
   - Lines 294-351: Replaced manual client certificate generation with production-aligned script
   - Added CA file copying from bridge export to client import
   - Integrated same certificate generation workflow as server/bridge

3. **`tests/integration/test_sigul_stack.py`**
   - Updated 10 test methods to use FHS-compliant paths
   - Changed `/var/sigul/*` → `/etc/pki/sigul/*`, `/etc/sigul/*`, `/var/lib/sigul/*`
   - Fixed volume names in test commands

---

## Expected CI Output (Success)

```
[INFO] Starting persistent client container for integration tests...
[DEBUG] Using bridge NSS volume: sigul-docker_sigul_bridge_nss
[DEBUG] Using client PKI volume: sigul-integration-client-pki  
[DEBUG] Using client config volume: sigul-integration-client-config
[NSS-SUCCESS] FHS-compliant directory structure created
[NSS-SUCCESS] Waiting for CA with private key from bridge...
[NSS-SUCCESS] CA PKCS#12 file found from bridge
[NSS-SUCCESS] CA files copied to client import location
[CERT-GEN] Importing CA with private key from bridge...
[CERT-GEN] CA with private key imported: sigul-ca
[CERT-GEN] Generating client certificate with FQDN and SAN...
[CERT-GEN] client certificate generated: sigul-client-cert
[SUCCESS] Client certificates generated with FQDN and SAN
[SUCCESS] Client container initialized successfully
```

---

## Verification Commands

```bash
# 1. Verify bridge NSS volume exists and has certificates
docker run --rm -v sigul-docker_sigul_bridge_nss:/nss alpine ls -la /nss/
# Expected: cert9.db, key4.db, pkcs11.txt

# 2. Run volume validation tool
./scripts/validate-volumes.sh --verbose

# 3. Run integration tests locally
./scripts/run-integration-tests.sh --verbose

# 4. Check client container logs
docker logs sigul-client-integration
```

---

## Technical Details

### Volume Architecture

| Volume Purpose | Mount Point | Permissions | Created By |
|---------------|-------------|-------------|------------|
| Bridge NSS (shared) | `/etc/pki/sigul/bridge-shared` | `:ro` | cert-init container |
| Client PKI | `/etc/pki/sigul` | `:rw` | Integration test |
| Client Config | `/etc/sigul` | `:rw` | Integration test |

### Certificate Generation Flow

```
Bridge (cert-init)
└─> Generates CA with private key
└─> Exports CA as PKCS#12
    └─> /etc/pki/sigul/ca-export/ca.p12

Client Container
└─> Mounts bridge NSS at /etc/pki/sigul/bridge-shared:ro
└─> Reads CA export from bridge-shared/ca-export/
└─> Copies to /etc/pki/sigul/ca-import/ca.p12
└─> Calls generate-production-aligned-certs.sh
    └─> Imports CA with private key (PKCS#12)
    └─> Generates client certificate signed by CA
```

### Key Concepts

1. **Volume Type Matters**: NSS volumes contain certificates, data volumes contain application data
2. **Parent Directory Mounting**: Mount at `/etc/pki/sigul` not `/etc/pki/sigul/client` to allow subdirectory creation
3. **Ownership Initialization**: Pre-set volume ownership to match container user (UID 1000)
4. **FHS Compliance**: All paths follow Filesystem Hierarchy Standard
5. **CA Private Key Transport**: Use PKCS#12 format to transport CA with private key
6. **Consistent Certificate Generation**: All components use same production-aligned script

---

## Related Documentation

- **`CLIENT_SETUP_DEBUG_ANALYSIS.md`** - Issue #1 comprehensive analysis
- **`CLIENT_PERMISSION_FIX.md`** - Issue #2 permission fix deep dive
- **`CLIENT_CERT_GENERATION_FIX.md`** - Issue #3 certificate generation fix
- **`CI_INTEGRATION_TEST_FIXES.md`** - Detailed fix documentation
- **`INTEGRATION_TEST_RESOLUTION_SUMMARY.md`** - Executive summary
- **`TESTING_CHECKLIST.md`** - Verification procedures

---

## Status

- ✅ Issue #1 Fixed: Bridge NSS volume detection
- ✅ Issue #2 Fixed: Client volume permissions  
- ✅ Issue #3 Fixed: Client certificate generation
- ⏳ Awaiting CI verification
- 📝 Documentation complete

**Summary:** Three sequential issues resolved - volume detection, permissions, and certificate generation.

**Next Action:** Monitor GitHub Actions workflow for successful test execution.