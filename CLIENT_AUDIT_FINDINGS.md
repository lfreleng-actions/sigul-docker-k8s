# Client Implementation Audit - Configuration Mismatch Report

**Date:** 2025-01-16  
**Scope:** Client Dockerfile, initialization, and integration test setup  
**Status:** 🔴 Critical mismatches found between client and server/bridge implementations

---

## Executive Summary

The client implementation has significant configuration mismatches with the updated server/bridge infrastructure. Multiple outdated paths, obsolete setup tasks, and misaligned expectations were identified.

---

## Critical Issues

### 1. 🔴 **Dockerfile Uses Wrong Directory Paths**

**File:** `Dockerfile.client`  
**Lines:** 82-84, 139-141

**Issue:** Client Dockerfile still references `/var/sigul` as home directory and creates wrong structure.

**Current (Wrong):**
```dockerfile
useradd -u 1000 -g 1000 -d /var/sigul -s /bin/bash sigul && \
mkdir -p /var/sigul && \
chown sigul:sigul /var/sigul && \
```

**Should Be (FHS-compliant):**
```dockerfile
useradd -u 1000 -g 1000 -d /home/sigul -s /bin/bash sigul && \
# FHS paths are created by volumes, not in Dockerfile
```

**Impact:** Creates wrong directory expectations in client container.

---

### 2. 🔴 **Health Check Uses Wrong NSS Path**

**File:** `Dockerfile.client`  
**Lines:** 139-141

**Issue:** Health check looks for NSS database in `/var/sigul/nss/client`.

**Current (Wrong):**
```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD certutil -d sql:/var/sigul/nss/client -L -n sigul-ca >/dev/null 2>&1 && \
        certutil -d sql:/var/sigul/nss/client -L -n sigul-client-cert >/dev/null 2>&1 || exit 1
```

**Should Be:**
```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD certutil -d sql:/etc/pki/sigul/client -L -n sigul-ca >/dev/null 2>&1 && \
        certutil -d sql:/etc/pki/sigul/client -L -n sigul-client-cert >/dev/null 2>&1 || exit 1
```

---

### 3. 🔴 **Client Initialization Expects Obsolete CA Export**

**File:** `scripts/sigul-init.sh`  
**Lines:** 305-329

**Issue:** Client setup waits for `/var/sigul/bridge-shared/ca-export/ca.crt` which no longer exists.

**Current (Obsolete):**
```bash
local ca_import_dir="$NSS_BASE_DIR/bridge-shared/ca-export"

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
```

**Why Wrong:**
- No PEM certificate export in NSS-only approach
- CA certificate is available directly in bridge NSS database
- Client should read from bridge NSS volume, not wait for export

**Should Be:**
```bash
# Client reads CA directly from bridge NSS database mounted at bridge-shared
local bridge_nss_dir="$NSS_BASE_DIR/bridge-shared"

# Verify bridge NSS database is accessible
if [[ ! -f "$bridge_nss_dir/cert9.db" ]]; then
    fatal "Bridge NSS database not accessible at $bridge_nss_dir"
fi

# Import CA certificate directly from bridge NSS database
if ! certutil -L -d "sql:$bridge_nss_dir" -n "$CA_NICKNAME" -a > /tmp/ca.pem 2>/dev/null; then
    fatal "Could not export CA from bridge NSS database"
fi

# Import CA to client NSS database
certutil -A -d "sql:$client_nss_dir" -n "$CA_NICKNAME" -t "CT,C,C" -a -i /tmp/ca.pem
rm -f /tmp/ca.pem
```

---

### 4. 🔴 **Client Uses Production-Aligned Cert Generation Script**

**File:** `scripts/sigul-init.sh`  
**Lines:** 336-348

**Issue:** Client tries to use `generate-production-aligned-certs.sh` which is a bridge-only script.

**Current (Wrong):**
```bash
if [[ -x "/usr/local/bin/generate-production-aligned-certs.sh" ]]; then
    NSS_DB_DIR="$client_nss_dir" \
    NSS_PASSWORD="$(get_nss_password)" \
    COMPONENT="client" \
    FQDN="$client_fqdn" \
    /usr/local/bin/generate-production-aligned-certs.sh
```

**Why Wrong:**
- This script is for bridge-as-CA only
- Client should generate CSR and get it signed by bridge (not self-sign)
- Current approach creates isolated client certs not trusted by bridge

**Should Be:**
Client should use `certutil` directly to:
1. Create NSS database
2. Generate key pair and CSR
3. Submit CSR to bridge (or use pre-signed cert from volume)
4. Import signed certificate

---

### 5. 🟡 **Redundant Certificate Import Functions**

**File:** `scripts/run-integration-tests.sh`  
**Lines:** 264-279, 289-405

**Issue:** Integration tests manually import certificates between client and bridge.

**Current Approach:**
1. Start client with bridge NSS volume mounted
2. Initialize client (creates own certs)
3. Export client cert from client
4. Import client cert to bridge
5. Export bridge cert from bridge
6. Import bridge cert to client

**Why Problematic:**
- Double work: mounting bridge NSS volume AND importing individual certs
- Race conditions: concurrent cert imports
- Fragile: depends on timing and order of operations

**Should Be:**
If bridge NSS volume is mounted as `bridge-shared`, client initialization should:
1. Read CA cert directly from bridge NSS
2. Generate client cert with same CA
3. No manual imports needed (all certs share same CA)

---

### 6. 🟡 **Client Initialization May Not Need Bridge Volume**

**File:** Integration tests, docker-compose

**Issue:** Current design mounts bridge NSS volume to client, but then does manual cert imports anyway.

**Current Volume Mount:**
```yaml
- sigul_bridge_nss:/etc/pki/sigul/bridge-shared:ro
```

**Decision Needed:**

**Option A: Keep Volume Mount (Simpler)**
- Client reads CA directly from bridge NSS database
- Client generates cert signed by same CA
- No manual imports needed
- **Pros:** Simpler, no file exports
- **Cons:** Client has read access to bridge NSS

**Option B: Certificate Exchange via API (Production-like)**
- Client generates CSR
- Submits CSR to bridge via sigul API
- Bridge signs and returns certificate
- **Pros:** More production-like
- **Cons:** More complex, requires bridge API

**Recommendation:** Option A for testing, document Option B for production.

---

### 7. 🟡 **Unused PKI Directory in Dockerfile**

**File:** `Dockerfile.client`  
**Lines:** 52-54, 93-96

**Issue:** Client Dockerfile copies `pki/` directory but it's not used in NSS-only approach.

**Current:**
```dockerfile
# Copy shared PKI files for certificate generation
COPY pki/ /workspace/pki/
```

**Impact:** Adds unnecessary files to image, creates confusion about certificate sources.

**Should Be:** Remove this COPY directive entirely. NSS-only approach doesn't use PEM files from `pki/`.

---

### 8. 🟡 **Log File Location Mismatch**

**File:** `Dockerfile.client`  
**Lines:** 87-89

**Issue:** Creates log file at `/var/log/sigul_client.log` (old naming, wrong location).

**Current:**
```dockerfile
touch /var/log/sigul_client.log && \
chown sigul:sigul /var/log/sigul_client.log && \
chmod 644 /var/log/sigul_client.log && \
```

**Should Be:**
```dockerfile
mkdir -p /var/log/sigul/client && \
chown -R sigul:sigul /var/log/sigul && \
```

Or better yet, don't create in Dockerfile—let volume mount handle it.

---

## Configuration Inconsistencies

### NSS Database Paths

| Component | Expected Path | Actual Path in Client | Status |
|-----------|--------------|----------------------|---------|
| Config | `/etc/sigul/client.conf` | ✅ Correct in tests | ✅ |
| NSS DB | `/etc/pki/sigul/client` | ❌ `/var/sigul/nss/client` in Dockerfile | ❌ |
| Data | `/var/lib/sigul/client` | ❌ `/var/lib/sigul` in Dockerfile | ⚠️ |
| Logs | `/var/log/sigul/client` | ❌ `/var/log/sigul_client.log` | ❌ |

### Volume Mounts (docker-compose.sigul.yml)

```yaml
sigul-client-test:
  volumes:
    - sigul_client_config:/etc/sigul:rw                    # ✅ Correct
    - sigul_client_nss:/etc/pki/sigul/client:rw            # ✅ Correct
    - sigul_client_data:/var/lib/sigul/client:rw           # ✅ Correct
    - sigul_bridge_nss:/etc/pki/sigul/bridge-shared:ro     # ✅ Correct path
```

**Issue:** Dockerfile creates wrong internal paths that volumes override, causing confusion.

---

## Recommended Actions

### Immediate (P0) - Block Integration Tests

1. ✅ **Fix integration test paths** (DONE)
   - Updated all `/var/sigul/nss/*` → `/etc/pki/sigul/*`
   - Updated all `/var/sigul/config/*` → `/etc/sigul/*`

2. 🔴 **Remove obsolete CA export wait in sigul-init.sh**
   - Replace with direct NSS database read
   - Lines 305-329 in `scripts/sigul-init.sh`

3. 🔴 **Fix client certificate generation approach**
   - Remove `generate-production-aligned-certs.sh` call
   - Use direct certutil commands
   - Import CA from bridge NSS instead of waiting for export

### High Priority (P1) - Correct Implementation

4. 🔴 **Update Dockerfile.client**
   - Fix home directory: `/home/sigul` not `/var/sigul`
   - Fix health check NSS path
   - Remove PKI directory copy
   - Fix log file creation

5. 🔴 **Simplify certificate import logic**
   - Remove redundant `import_client_cert_to_bridge()` function
   - Remove redundant `import_bridge_cert_to_client()` function
   - Use shared CA approach instead

### Medium Priority (P2) - Cleanup

6. 🟡 **Document certificate management approach**
   - Why client has bridge NSS volume access
   - How certificates are shared
   - Production considerations

7. 🟡 **Remove legacy entrypoint.sh**
   - Client now uses sigul-init.sh
   - Old entrypoint.sh is dead code

---

## Simplified Client Initialization Flow

### Current (Complex, Fragile)
```
1. Start client container
2. Mount bridge NSS volume
3. Wait for CA export file (doesn't exist)
4. Generate client certs (wrong script)
5. Export client cert to file
6. Import client cert to bridge
7. Export bridge cert to file
8. Import bridge cert to client
9. Hope everything worked
```

### Proposed (Simple, Reliable)
```
1. Start client container with bridge NSS volume mounted at bridge-shared
2. Client init:
   a. Create client NSS database
   b. Import CA cert from bridge-shared NSS DB
   c. Generate client key pair
   d. Create self-signed client cert with same CA trust chain
3. Done - no manual imports needed
```

---

## Testing Checklist

After fixes:
- [ ] Client container starts without errors
- [ ] Client NSS database created at `/etc/pki/sigul/client`
- [ ] Client can read bridge CA from mounted volume
- [ ] Client certificate generation succeeds
- [ ] Client can connect to bridge
- [ ] Integration tests pass
- [ ] No obsolete path references remain

---

## Code Examples

### Correct Client Initialization (Simplified)

```bash
setup_client_certificates() {
    log "Setting up client certificates (NSS-only)"

    local client_nss_dir="/etc/pki/sigul/client"
    local bridge_nss_dir="/etc/pki/sigul/bridge-shared"
    local client_fqdn="${CLIENT_FQDN:-sigul-client.example.org}"

    # Check if certificates already exist
    if [[ -f "$client_nss_dir/cert9.db" ]] && \
       certutil -d "sql:$client_nss_dir" -L -n "sigul-ca" >/dev/null 2>&1 && \
       certutil -d "sql:$client_nss_dir" -L -n "sigul-client-cert" >/dev/null 2>&1; then
        log "Client certificates already exist"
        return 0
    fi

    # Create NSS database
    mkdir -p "$client_nss_dir"
    certutil -N -d "sql:$client_nss_dir" --empty-password

    # Import CA from bridge NSS database
    log "Importing CA certificate from bridge NSS database"
    certutil -L -d "sql:$bridge_nss_dir" -n "sigul-ca" -a > /tmp/ca.pem
    certutil -A -d "sql:$client_nss_dir" -n "sigul-ca" -t "CT,C,C" -a -i /tmp/ca.pem
    rm -f /tmp/ca.pem

    # Generate client certificate
    log "Generating client certificate"
    certutil -S -d "sql:$client_nss_dir" \
        -n "sigul-client-cert" \
        -s "CN=$client_fqdn,O=Sigul,C=US" \
        -t "u,u,u" \
        -x \
        --keyUsage digitalSignature,keyEncipherment \
        -v 120 \
        -m "$RANDOM$RANDOM"

    log "Client certificate setup completed"
}
```

---

## Conclusion

The client implementation has significant drift from the updated server/bridge architecture. The main issues are:

1. **Path mismatches**: Dockerfile and health checks use old paths
2. **Obsolete waits**: Looking for CA export files that don't exist
3. **Wrong cert generation**: Using bridge CA script instead of client approach
4. **Redundant imports**: Manual certificate exchange when volume mount makes it unnecessary

**Estimated effort to fix:** 4-6 hours  
**Risk if not fixed:** Integration tests will continue to fail, production client deployment impossible

**Priority:** Address P0 issues immediately to unblock integration tests, then systematically fix P1 items for correct implementation.