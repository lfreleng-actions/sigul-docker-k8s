# Sigul Double-TLS Connection Debugging Strategy

**Date**: 2025-01-17  
**Status**: Active Investigation  
**Issue**: SSL handshake failures and "Unexpected EOF in NSPR" errors in CI integration tests

---

## Problem Summary

The Sigul integration tests are failing with SSL handshake errors followed by authentication failures:

```
[2025-11-17 01:03:35] WARN: ⚠ SSL handshake failed with tstclnt - trying OpenSSL fallback
[2025-11-17 01:03:36] ERROR: ✗ Both NSS and OpenSSL SSL handshakes failed
[2025-11-17 01:03:36] WARN: SSL handshake verification failed - sigul operations may encounter 'Unexpected EOF in NSPR' errors
...
[2025-11-17 01:03:36] ERROR: ✗ Command failed with exit code: 1
[2025-11-17 01:03:36] ERROR: Command output (stdout/stderr):
  ERROR: I/O error: Unexpected EOF in NSPR
```

### What We Know

1. **Infrastructure is correct**: All PKI, volumes, networking verified locally
2. **Certificates are properly generated**: CA, bridge, and client certificates exist
3. **Trust flags are correct**: `TC,,` for CA, `P,P,P` for bridge, `u,u,u` for client
4. **Local vs CI discrepancy**: Local debugging works, CI tests fail
5. **Double-TLS architecture**: Client → Bridge (outer TLS) → Server (inner TLS)

### What We Don't Know

1. **Where exactly the handshake fails**: Is it the outer TLS (client→bridge) or inner TLS (bridge→server)?
2. **Certificate validation details**: Which certificate is being rejected and why?
3. **NSS database state in CI**: Are certificates actually imported correctly?
4. **Password handling**: Is the NSS password being correctly used?
5. **Bridge/server readiness**: Are services truly ready when clients try to connect?

---

## Debugging Approach

### Phase 1: Source Code Instrumentation ✓ COMPLETE

We've added comprehensive debugging patches to the Sigul v1.4 source code.

#### Patches Created

**File**: `patches/01-add-comprehensive-debugging.patch`

This patch instruments three key Python modules:

1. **`src/utils.py`** - NSS initialization
   - Logs NSS database path and password length
   - Shows certificate enumeration from NSS database
   - Provides detailed error messages for common failures
   - Confirms successful authentication

2. **`src/double_tls.py`** - Double-TLS connection logic
   - Logs bridge hostname, port, and certificate nickname
   - Shows certificate lookup and validation
   - Tracks TCP connection attempts
   - Monitors SSL handshake progress
   - Reports peer certificate details
   - Provides context for all child process errors

3. **`src/client.py`** - Client connection lifecycle
   - Identifies operation being performed
   - Shows connection parameters
   - Tracks NSS initialization status
   - Adds context to EOF and connection reset errors

#### Build Integration ✓ COMPLETE

Modified files to automatically apply patches:

- `build-scripts/install-sigul.sh`: Detects and applies patches during source build
- `Dockerfile.client`: Copies patches directory before building Sigul
- `Dockerfile.bridge`: Copies patches directory before building Sigul
- `Dockerfile.server`: Copies patches directory before building Sigul

#### Expected Debug Output

With patches applied, logs will show structured output:

```
==================== NSS INITIALIZATION DEBUG ====================
NSS_DIR: /etc/pki/sigul/client
NSS_PASSWORD length: 16
Calling nss.nss.nss_init(/etc/pki/sigul/client)
✓ NSS database initialized successfully
Testing NSS password by authenticating key slot...
✓ NSS password authentication successful
Available certificates in NSS database:
  - CN=sigul-ca,O=Sigul Test CA
  - CN=sigul-bridge-cert,O=Sigul Test CA
  - CN=sigul-client-cert,O=Sigul Test CA
==================== NSS INITIALIZATION COMPLETE ====================

==================== CLIENT CONNECTION STARTING ====================
Operation: new-user
Bridge: sigul-bridge:44334
Client cert: sigul-client-cert

==================== DOUBLE-TLS CLIENT INIT DEBUG ====================
Bridge hostname: sigul-bridge
Bridge port: 44334
Client cert nickname: sigul-client-cert

==================== CHILD PROCESS SSL CONNECTION DEBUG ====================
Attempting SSL connection to sigul-bridge:44334
Looking up certificate nickname: sigul-client-cert
✓ Found certificate: CN=sigul-client-cert,O=Sigul Test CA
Setting client auth callback with certificate
Trying address: 172.18.0.3
Attempting TCP connect to sigul-bridge:44334...
✓ TCP connection established
Starting SSL handshake with bridge...
✓ SSL handshake with bridge completed successfully
✓ Bridge certificate: CN=sigul-bridge-cert,O=Sigul Test CA
Starting bidirectional forwarding (double-TLS active)...
```

---

## Phase 2: Execution Plan

### Step 1: Rebuild Docker Images with Patches

```bash
# From sigul-docker directory
git add patches/
git commit -m "Add comprehensive Sigul debugging patches for CI troubleshooting"
git push origin main
```

This will trigger CI to rebuild all Docker images with debugging instrumentation.

### Step 2: Analyze CI Logs

After the next CI run, examine logs for:

1. **NSS Initialization Section**
   - Verify NSS_DIR path is correct
   - Check that password length is non-zero
   - Confirm certificates are listed
   - Look for authentication success

2. **Connection Attempt Section**
   - Verify bridge hostname and port
   - Check certificate nickname matches
   - Confirm certificate is found
   - Track TCP connection success/failure

3. **SSL Handshake Section**
   - Identify which handshake fails (outer vs inner)
   - Check for peer certificate details
   - Look for specific NSPR error codes

4. **Error Context**
   - Read the detailed error messages
   - Identify exact failure point
   - Check for certificate expiration warnings
   - Look for "SEC_ERROR_BAD_DATABASE" or similar

### Step 3: Diagnostic Decision Tree

Based on the debug output, follow this decision tree:

#### If "Certificate not found" error:
- **Check**: NSS database listing shows expected certificates
- **Fix**: Certificate import script may need adjustment
- **Verify**: Certificate nicknames match in config and NSS database

#### If "NSS initialization failed":
- **Check**: NSS_DIR path is correct (`/etc/pki/sigul/client`)
- **Check**: Password authentication section shows success
- **Fix**: May be a password mismatch or corrupt database
- **Verify**: NSS password file and environment variable

#### If "TCP connection failed":
- **Check**: Bridge container is running and healthy
- **Check**: Network connectivity between client and bridge
- **Fix**: May be a readiness timing issue
- **Verify**: Bridge logs show it's listening on 44334

#### If "SSL handshake failed" with TCP success:
- **Check**: Which certificate the bridge received
- **Check**: Trust flags in NSS database
- **Fix**: May be incorrect trust flags or untrusted CA
- **Verify**: Bridge logs for certificate validation errors

#### If "Unexpected EOF" after handshake:
- **Check**: Bridge→Server (inner TLS) connection logs
- **Check**: Server readiness and authentication
- **Fix**: May be a server-side authentication issue
- **Verify**: Server database and user credentials

---

## Phase 3: Potential Fixes

Based on common failure patterns:

### Fix Option A: Certificate Trust Chain

If certificates aren't properly trusted:

```bash
# In client container, verify trust chain
certutil -L -d sql:/etc/pki/sigul/client
# Should show:
# sigul-ca          CT,C,C  (or TC,,)
# sigul-bridge-cert P,P,P
# sigul-client-cert u,u,u
```

**Action**: Modify `scripts/init-client-certs.sh` trust flags if needed.

### Fix Option B: NSS Database Corruption

If NSS database is corrupt or incomplete:

```bash
# Rebuild NSS database
rm -rf /etc/pki/sigul/client/*.db
certutil -N -d sql:/etc/pki/sigul/client -f /path/to/password-file
# Re-import certificates
```

**Action**: Add NSS database validation to initialization scripts.

### Fix Option C: Timing Issues

If services aren't ready when clients connect:

```bash
# Wait for specific conditions
while ! docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge -n sigul-bridge-cert; do
  sleep 1
done
```

**Action**: Enhance readiness checks in `scripts/run-integration-tests.sh`.

### Fix Option D: Certificate Hostname Mismatch

If SNI or hostname validation fails:

```bash
# Verify certificate subject matches bridge hostname
certutil -L -d sql:/etc/pki/sigul/bridge -n sigul-bridge-cert | grep Subject
# Should contain: sigul-bridge
```

**Action**: Regenerate certificates with correct hostnames.

### Fix Option E: Double-TLS Configuration

If inner or outer TLS is misconfigured:

```bash
# Verify client config
cat /etc/sigul/client.conf
# Check:
# - bridge-hostname
# - server-hostname  
# - bridge-port
# - server-port
# - client-cert-nickname
```

**Action**: Validate and regenerate configs if misaligned.

---

## Phase 4: Validation

After applying fixes:

1. **Run integration tests locally**:
   ```bash
   ./scripts/run-integration-tests.sh --verbose
   ```

2. **Check debug output for success markers** (`✓`):
   - NSS initialization complete
   - Certificate found and validated
   - TCP connection established
   - SSL handshake completed
   - Double-TLS active

3. **Verify actual operations succeed**:
   - User creation
   - Key creation
   - Signing operations

4. **Commit and push** to trigger CI validation

---

## Success Criteria

Integration tests pass when:

1. ✅ All debug sections show success markers
2. ✅ No "Unexpected EOF" errors
3. ✅ User creation completes successfully
4. ✅ Key operations succeed
5. ✅ Signing operations produce valid signatures

---

## Rollback Plan

If debugging patches cause issues:

1. Remove or rename `patches/` directory
2. Rebuild Docker images without patches
3. Revert to previous troubleshooting methods

The patches only add logging and don't change functional behavior, so rollback risk is minimal.

---

## Next Actions

1. ✅ Commit patches and build changes
2. ⏳ Wait for CI rebuild with debugging
3. ⏳ Analyze detailed debug logs
4. ⏳ Apply appropriate fix from Phase 3
5. ⏳ Validate and document resolution

---

## Related Documentation

- `patches/README.md` - Patch details and testing
- `PKI_ARCHITECTURE.md` - Certificate infrastructure
- `DEPLOYMENT_GUIDE.md` - Container deployment
- `TLS_DEBUG_SUMMARY.md` - Previous TLS debugging
- `CI_CA_TRUST_FLAGS_FIX.md` - Prior trust flag fixes

---

## Contact

For questions or issues with this debugging strategy:
- Review CI logs for detailed debug output
- Check previous debugging sessions in conversation history
- Consult Sigul documentation at https://github.com/ModeSevenIndustrialSolutions/sigul