# Workflow Audit Findings - Path and Directory Issues

**Date:** 2025-01-16  
**Audit Scope:** GitHub Actions workflow and related scripts for FHS-compliance  
**Status:** 🔴 Multiple critical path issues found

## Executive Summary

After extensive changes to move to FHS-compliant directory structures, several components still reference outdated paths. This audit identifies all path-related issues that need correction.

## Directory Structure Changes

### Old Structure (Deprecated)
```
/var/sigul/
├── nss/
│   ├── bridge/
│   ├── server/
│   └── client/
├── secrets/
│   ├── certificates/
│   └── nss-password
├── config/
├── logs/
└── data/
```

### New Structure (FHS-Compliant)
```
/etc/sigul/              # Configuration files
/etc/pki/sigul/          # NSS certificate databases
│   ├── bridge/
│   ├── server/
│   └── client/
/var/lib/sigul/          # Persistent data
│   ├── bridge/
│   ├── server/
│   └── client/
/var/log/sigul/          # Log files
│   ├── bridge/
│   ├── server/
│   └── client/
/run/sigul/              # Runtime files
│   ├── bridge/
│   ├── server/
│   └── client/
```

## Issues Found

### 1. ✅ FIXED: NSS Validation Script Default Path

**File:** `scripts/validate-nss.sh`  
**Line:** 36  
**Issue:** Default NSS_BASE_DIR was `/var/sigul/nss`  
**Status:** Fixed - Changed to `/etc/pki/sigul`

```diff
-NSS_BASE_DIR="${NSS_DIR:-/var/sigul/nss}"
+NSS_BASE_DIR="${NSS_DIR:-/etc/pki/sigul}"
```

### 2. ✅ FIXED: Workflow NSS Validation Environment Variable

**File:** `.github/workflows/build-test.yaml`  
**Lines:** 1164, 1174  
**Issue:** NSS validation calls didn't pass NSS_DIR environment variable  
**Status:** Fixed - Added `-e NSS_DIR=/etc/pki/sigul` to docker exec commands

```diff
-if docker exec sigul-bridge \
+if docker exec -e NSS_DIR=/etc/pki/sigul sigul-bridge \
```

### 3. ✅ FIXED: Workflow Volume Diagnostics Collection

**File:** `.github/workflows/build-test.yaml`  
**Lines:** 931-948  
**Issue:** Volume diagnostics looking for `/var/sigul` mount and `/var/sigul/nss/bridge` path  
**Status:** Fixed - Updated to use `/etc/pki/sigul/bridge`

```diff
-bridge_volume=$(docker inspect sigul-bridge \
-  --format \
-  '{{range .Mounts}}{{if eq .Destination "/var/sigul"}}' \
-  '{{.Name}}{{end}}{{end}}' \
-  2>/dev/null || echo "")
+bridge_nss_volume=$(docker inspect sigul-bridge \
+  --format \
+  '{{range .Mounts}}{{if eq .Destination "/etc/pki/sigul/bridge"}}' \
+  '{{.Name}}{{end}}{{end}}' \
+  2>/dev/null || echo "")
```

### 4. 🔴 CRITICAL: Deployment Script Certificate File Checks

**File:** `scripts/deploy-sigul-infrastructure.sh`  
**Lines:** 391-405, 417-431  
**Issue:** Checking for certificates in `/var/sigul/secrets/certificates/`  
**Impact:** High - Certificate validation will always fail  
**Fix Required:** Remove these checks (certificates are now NSS-only, no PEM files)

**Current problematic code:**
```bash
if docker exec sigul-bridge test -f /var/sigul/secrets/certificates/ca.crt 2>/dev/null; then
    bridge_cert_ca='"ok"'
else
    bridge_cert_ca='"missing"'
fi
```

**Recommended fix:** These checks should be removed entirely as we now use NSS-only approach (no PEM certificate files).

### 5. 🔴 CRITICAL: Client Certificate Import Function

**File:** `scripts/deploy-sigul-infrastructure.sh`  
**Lines:** 1207-1254  
**Function:** `import_client_cert_to_bridge()`  
**Issue:** Uses old paths `/var/sigul/nss/client` and `/var/sigul/nss/bridge`  
**Impact:** High - Client certificate import will fail  
**Fix Required:** Update all NSS paths to FHS-compliant paths

**Required changes:**
```diff
-if docker exec "$client_container" test -f /var/sigul/nss/client/cert9.db 2>/dev/null; then
+if docker exec "$client_container" test -f /etc/pki/sigul/client/cert9.db 2>/dev/null; then

-docker exec "$bridge_container" certutil -D -d /var/sigul/nss/bridge -n sigul-client-cert 2>/dev/null || true
+docker exec "$bridge_container" certutil -D -d sql:/etc/pki/sigul/bridge -n sigul-client-cert 2>/dev/null || true

-if ! docker exec "$client_container" certutil -L -d /var/sigul/nss/client -n sigul-client-cert -a > /tmp/current-client-cert.pem 2>/dev/null; then
+if ! docker exec "$client_container" certutil -L -d sql:/etc/pki/sigul/client -n sigul-client-cert -a > /tmp/current-client-cert.pem 2>/dev/null; then

-if docker exec "$bridge_container" certutil -A -d /var/sigul/nss/bridge \
+if docker exec "$bridge_container" certutil -A -d sql:/etc/pki/sigul/bridge \
     -n sigul-client-cert \
     -t "P,," \
     -a -i /tmp/current-client-cert.pem \
-    -f /var/sigul/secrets/nss-password 2>/dev/null; then
+    2>/dev/null; then

-if docker exec "$bridge_container" certutil -L -d /var/sigul/nss/bridge -n sigul-client-cert >/dev/null 2>&1; then
+if docker exec "$bridge_container" certutil -L -d sql:/etc/pki/sigul/bridge -n sigul-client-cert >/dev/null 2>&1; then
```

### 6. 🔴 CRITICAL: Log File Checks in Deployment Script

**File:** `scripts/deploy-sigul-infrastructure.sh`  
**Lines:** 1330, 1335, 1419, 1424, 1456-1475  
**Issue:** Looking for logs in `/var/sigul/logs/{component}/`  
**Impact:** Medium - Diagnostic log collection will fail  
**Fix Required:** Update to `/var/log/sigul/{component}/`

**Required changes:**
```diff
-if docker exec sigul-server test -f /var/sigul/logs/server/startup_errors.log 2>/dev/null; then
+if docker exec sigul-server test -f /var/log/sigul/server/startup_errors.log 2>/dev/null; then

-if docker exec sigul-bridge test -f /var/sigul/logs/bridge/startup_errors.log 2>/dev/null; then
+if docker exec sigul-bridge test -f /var/log/sigul/bridge/startup_errors.log 2>/dev/null; then
```

### 7. 🔴 CRITICAL: Volume Inspection for Logs

**File:** `scripts/deploy-sigul-infrastructure.sh`  
**Lines:** 1442-1481  
**Issue:** Looking for `/var/sigul` mount point and `/var/sigul/logs/` paths  
**Impact:** Medium - Log diagnostics will fail  
**Fix Required:** Update to check `/var/log/sigul/bridge` mount

**Required changes:**
```diff
-bridge_volume_name=$(docker inspect sigul-bridge --format '{{range .Mounts}}{{if eq .Destination "/var/sigul"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")
+bridge_log_volume=$(docker inspect sigul-bridge --format '{{range .Mounts}}{{if eq .Destination "/var/log/sigul/bridge"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || echo "")

-docker run --rm -v "${bridge_volume_name}":/var/sigul alpine:3.19 sh -c '
+docker run --rm -v "${bridge_log_volume}":/logs alpine:3.19 sh -c '
   set -e
   echo "===== Bridge Log Directory Listing ====="
-  ls -l /var/sigul/logs/bridge 2>/dev/null || echo "Cannot list /var/sigul/logs/bridge"
+  ls -l /logs 2>/dev/null || echo "Cannot list /logs"
```

### 8. 🟡 MEDIUM: Configuration File Path Check

**File:** `scripts/deploy-sigul-infrastructure.sh`  
**Line:** 1542  
**Issue:** Looking for config in `/var/sigul/config/server.conf`  
**Impact:** Low - Diagnostic only  
**Fix Required:** Update to `/etc/sigul/server.conf`

```diff
-docker exec sigul-server grep -A 3 -B 3 "bridge-hostname\|bridge-port" /var/sigul/config/server.conf 2>/dev/null || true
+docker exec sigul-server grep -A 3 -B 3 "bridge-hostname\|bridge-port" /etc/sigul/server.conf 2>/dev/null || true
```

## Additional Checks Needed

### Scripts to Audit
1. ✅ `scripts/validate-nss.sh` - Fixed
2. 🔴 `scripts/deploy-sigul-infrastructure.sh` - Multiple issues
3. ⚪ `scripts/run-integration-tests.sh` - Not yet audited
4. ⚪ `scripts/collect-sigul-diagnostics.sh` - Not yet audited
5. ⚪ `scripts/enhanced-telemetry-collection.sh` - Known to have `/var/sigul` references

### Health Library
**File:** `scripts/lib/health.sh`  
**Status:** ⚪ Not yet audited  
**Concern:** May have NSS_BASE_DIR references that need updating

## Priority Recommendations

### Immediate (P0)
1. ✅ Fix NSS validation in workflow - DONE
2. 🔴 Fix `import_client_cert_to_bridge()` function - NSS paths
3. 🔴 Remove obsolete PEM certificate file checks
4. 🔴 Update all log file paths in deployment script

### High Priority (P1)
1. Audit and fix `run-integration-tests.sh`
2. Audit and fix `collect-sigul-diagnostics.sh`
3. Update health library if needed

### Medium Priority (P2)
1. Audit `enhanced-telemetry-collection.sh`
2. Update all diagnostic collection to use FHS paths
3. Create path constant definitions for consistency

## Testing Checklist

After fixes are applied:
- [ ] Validate NSS certificates in bridge container
- [ ] Validate NSS certificates in server container
- [ ] Run full integration test suite
- [ ] Verify diagnostic collection works
- [ ] Check log file collection
- [ ] Verify volume inspection works
- [ ] Test client certificate import

## Reference: FHS Path Variables

For consistency across all scripts, consider defining these constants:

```bash
# NSS Certificate Databases
readonly NSS_BASE_DIR="/etc/pki/sigul"
readonly BRIDGE_NSS_DIR="/etc/pki/sigul/bridge"
readonly SERVER_NSS_DIR="/etc/pki/sigul/server"
readonly CLIENT_NSS_DIR="/etc/pki/sigul/client"

# Configuration Files
readonly CONFIG_DIR="/etc/sigul"
readonly BRIDGE_CONFIG="/etc/sigul/bridge.conf"
readonly SERVER_CONFIG="/etc/sigul/server.conf"
readonly CLIENT_CONFIG="/etc/sigul/client.conf"

# Persistent Data
readonly DATA_BASE_DIR="/var/lib/sigul"
readonly BRIDGE_DATA_DIR="/var/lib/sigul/bridge"
readonly SERVER_DATA_DIR="/var/lib/sigul/server"
readonly CLIENT_DATA_DIR="/var/lib/sigul/client"

# Log Files
readonly LOG_BASE_DIR="/var/log/sigul"
readonly BRIDGE_LOG_DIR="/var/log/sigul/bridge"
readonly SERVER_LOG_DIR="/var/log/sigul/server"
readonly CLIENT_LOG_DIR="/var/log/sigul/client"

# Runtime Files
readonly RUN_BASE_DIR="/run/sigul"
readonly BRIDGE_RUN_DIR="/run/sigul/bridge"
readonly SERVER_RUN_DIR="/run/sigul/server"
readonly CLIENT_RUN_DIR="/run/sigul/client"
```

## Conclusion

The workflow is currently blocked due to incorrect NSS path validation. The immediate fixes have been applied to unblock the workflow, but multiple critical issues remain in the deployment script that will cause failures in integration tests and diagnostics collection.

**Estimated effort to fix all issues:** 2-4 hours  
**Risk if not fixed:** Integration tests will fail, diagnostics will be incomplete