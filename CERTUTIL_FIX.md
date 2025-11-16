# Certutil Basic Constraints Fix

**Date:** 2025-01-XX  
**Status:** ✅ FIXED  
**Issue:** Certificate generation failing with SEC_ERROR_EXTENSION_VALUE_INVALID

---

## Problem

Certificate generation was failing during the bridge certificate creation step with the following error:

```
certutil: Problem creating BasicConstraint extension: SEC_ERROR_EXTENSION_VALUE_INVALID: Certificate extension value is invalid.
certutil: unable to create cert (Certificate extension value is invalid.)
```

**Error occurred at:**
```
[CERT-INIT] Generating bridge certificate for sigul-bridge.example.org...
Generating key.  This may take a few moments...
Is this a CA certificate [y/N]?
certutil: Problem creating BasicConstraint extension: SEC_ERROR_EXTENSION_VALUE_INVALID
[CERT-INIT] Failed to generate bridge certificate
```

---

## Root Cause

The `generate_component_certificate()` function in `scripts/cert-init.sh` was using the `-2` flag for non-CA certificates:

```bash
# INCORRECT - causes error
certutil -S \
    -d "sql:${BRIDGE_NSS_DIR}" \
    -n "${cert_nickname}" \
    -s "CN=${fqdn},O=Sigul Infrastructure,OU=${component}" \
    -c "${CA_NICKNAME}" \
    -t "u,u,u" \
    -m "${serial}" \
    -v "${validity_days}" \
    -g "${KEY_SIZE}" \
    -z "${noise_file}" \
    -f "${password_file}" \
    --keyUsage digitalSignature,keyEncipherment \
    --extKeyUsage serverAuth,clientAuth \
    -8 "${fqdn}" \
    -2 <<EOF          # ← This flag causes the issue
n
n
EOF
```

**What the `-2` flag does:**
- Enables Basic Constraints extension configuration
- Prompts interactively: "Is this a CA certificate [y/N]?"
- For CA certificates: Used to indicate the certificate can sign other certificates
- For non-CA certificates: **Should NOT be used** - causes SEC_ERROR_EXTENSION_VALUE_INVALID

**Why it failed:**
- The `-2` flag was being used for bridge, server, and client certificates
- We were answering "n\nn\n" (no, no) to the prompts
- certutil tried to set basic constraints with invalid values for non-CA certs
- Non-CA certificates should not have basic constraints extension at all

---

## Solution

Removed the `-2` flag from `generate_component_certificate()` function since it's only needed for CA certificates:

```bash
# CORRECT - works properly
certutil -S \
    -d "sql:${BRIDGE_NSS_DIR}" \
    -n "${cert_nickname}" \
    -s "CN=${fqdn},O=Sigul Infrastructure,OU=${component}" \
    -c "${CA_NICKNAME}" \
    -t "u,u,u" \
    -m "${serial}" \
    -v "${validity_days}" \
    -g "${KEY_SIZE}" \
    -z "${noise_file}" \
    -f "${password_file}" \
    --keyUsage digitalSignature,keyEncipherment \
    --extKeyUsage serverAuth,clientAuth \
    -8 "${fqdn}"
    # No -2 flag for non-CA certificates
```

**Key points:**
- Basic constraints extension is only for CA certificates
- Regular certificates (bridge, server, client) don't need it
- The CA certificate generation still uses `-2` flag correctly
- Non-CA certificates generate successfully without it

---

## Technical Details

### Certificate Types and Basic Constraints

| Certificate Type | Needs `-2` Flag? | Basic Constraints Value | Purpose |
|-----------------|------------------|------------------------|---------|
| CA Certificate | ✅ Yes | `CA:TRUE, pathlen:unlimited` | Can sign other certificates |
| Bridge Certificate | ❌ No | None | TLS authentication only |
| Server Certificate | ❌ No | None | TLS authentication only |
| Client Certificate | ❌ No | None | TLS authentication only |

### certutil `-2` Flag Behavior

**When used with CA certificate:**
```bash
certutil -S ... -2 <<EOF
y           # Is this a CA certificate? YES
-1          # Path length constraint: unlimited
y           # Is this a critical extension? YES
EOF
```

**When incorrectly used with non-CA certificate:**
```bash
certutil -S ... -2 <<EOF
n           # Is this a CA certificate? NO
n           # (further prompts)
EOF
# Result: SEC_ERROR_EXTENSION_VALUE_INVALID
```

**Correct approach for non-CA certificate:**
```bash
certutil -S ... 
# No -2 flag at all - no basic constraints extension
```

---

## Files Modified

**`scripts/cert-init.sh`:**
- Removed `-2` flag and associated EOF input from `generate_component_certificate()`
- Added comment explaining why it's not needed for non-CA certificates
- CA certificate generation still correctly uses `-2` flag

---

## Verification

After the fix, certificate generation succeeds:

```
[CERT-INIT] Generating Certificate Authority (CA)...
[CERT-INIT] CA certificate generated: sigul-ca ✅

[CERT-INIT] Generating bridge certificate for sigul-bridge.example.org...
[CERT-INIT] bridge certificate generated: sigul-bridge-cert ✅

[CERT-INIT] Generating server certificate for sigul-server.example.org...
[CERT-INIT] server certificate generated: sigul-server-cert ✅

[CERT-INIT] Generating client certificate for sigul-client.example.org...
[CERT-INIT] client certificate generated: sigul-client-cert ✅
```

---

## Testing

To test the fix:

```bash
# Clean environment
docker compose -f docker-compose.sigul.yml down -v

# Deploy with certificate generation
docker compose -f docker-compose.sigul.yml up cert-init

# Verify success
docker logs sigul-cert-init
# Should show all certificates generated successfully
```

---

## Lessons Learned

1. **Basic Constraints are for CAs only**
   - Only CA certificates need the basic constraints extension
   - Regular certificates should not have it

2. **certutil `-2` flag usage**
   - Use `-2` for CA certificates to set CA:TRUE
   - Don't use `-2` for regular certificates
   - Interactive prompts can cause issues in automated scripts

3. **Certificate extensions**
   - Different certificate types need different extensions
   - Key usage and extended key usage are appropriate for all types
   - Basic constraints are specific to CA certificates

4. **Error messages matter**
   - "SEC_ERROR_EXTENSION_VALUE_INVALID" indicated wrong extension usage
   - The prompt "Is this a CA certificate [y/N]?" was a clue
   - The error happened right after answering "N" to CA question

---

## Related Documentation

- NSS certutil documentation: https://developer.mozilla.org/en-US/docs/Mozilla/Projects/NSS/tools/certutil
- X.509 Basic Constraints: https://tools.ietf.org/html/rfc5280#section-4.2.1.9
- Certificate Extensions: https://tools.ietf.org/html/rfc5280#section-4.2

---

## Status

✅ **FIXED** - Certificate generation now works correctly

The cert-init container completes successfully and generates all required certificates without errors.

---

**Fixed By:** AI Assistant (Claude Sonnet 4.5)  
**Date:** 2025-01-XX  
**Impact:** Resolves cert-init container failure, unblocks integration tests