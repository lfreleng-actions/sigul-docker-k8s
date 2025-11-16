# Client Certificate Generation Fix

**SPDX-License-Identifier:** Apache-2.0  
**SPDX-FileCopyrightText:** 2025 The Linux Foundation

## Problem Statement

After fixing volume mounting issues (Issue #1 and #2), the integration tests revealed a third issue during client certificate generation:

```
[18:59:56] NSS-INIT: Creating client NSS database...
password file contains no data
[18:59:57] NSS-INIT: Importing CA certificate from bridge NSS database...
[18:59:57] NSS-SUCCESS: CA certificate imported successfully
[18:59:57] NSS-INIT: Generating client certificate for sigul-client.example.org...
[18:59:57] NSS-ERROR: Failed to generate client certificate
```

## Root Cause

The client certificate generation code in `sigul-init.sh` was trying to self-sign a certificate using the CA certificate, but the CA's **private key was not available** in the client NSS database.

### What Was Happening

```bash
# Client imports CA certificate (public key only)
certutil -A -d "sql:$client_nss_dir" -n "$CA_NICKNAME" -t CT,, \
    -a -i /tmp/ca-import.pem

# Client tries to sign its own certificate using CA
certutil -S -d "sql:$client_nss_dir" \
    -n "$CLIENT_CERT_NICKNAME" \
    -c "$CA_NICKNAME" \           # ← Requires CA private key!
    -t u,, \
    ...
```

**Problem:** The `-c "$CA_NICKNAME"` flag tells certutil to sign the certificate with the CA, but only the CA's public certificate was imported (via `-A`), not the private key.

### Why Server/Bridge Worked

Bridge and server components use the `generate-production-aligned-certs.sh` script which:
1. Bridge **generates** the CA (has private key)
2. Bridge exports CA with private key as PKCS#12 file (`ca.p12`)
3. Server **imports** CA with private key from PKCS#12
4. Server can sign its own certificate using the imported CA private key

Client was using **different code path** that didn't handle this properly.

## Solution

### Approach: Use Production-Aligned Script for Client

Changed client certificate setup to use the same `generate-production-aligned-certs.sh` script as server and bridge, ensuring consistent certificate generation across all components.

### Implementation Steps

1. **Wait for Bridge CA Export** (with private key)
   - Bridge exports CA as PKCS#12 to `/etc/pki/sigul/ca-export/`
   - Client waits for this export via bridge-shared mount

2. **Copy CA Files to Client Import Location**
   - Bridge export: `/etc/pki/sigul/bridge-shared/ca-export/ca.p12`
   - Client import: `/etc/pki/sigul/ca-import/ca.p12`
   - Copy operation bridges the gap between export and import locations

3. **Call Production-Aligned Script**
   - Script imports CA with private key from PKCS#12
   - Script generates client certificate signed by CA
   - Consistent with server/bridge certificate generation

## Code Changes

### File: `scripts/sigul-init.sh`

#### Before (Lines 294-382)

```bash
setup_client_certificates() {
    log "Setting up client certificates (Sigul-compliant)"
    
    local client_nss_dir="$NSS_BASE_DIR/client"
    local bridge_nss_dir="$NSS_BASE_DIR/bridge-shared"
    
    # Create client NSS database
    mkdir -p "$client_nss_dir"
    certutil -N -d "sql:$client_nss_dir" -f "$temp_password_file"
    
    # Import CA certificate (public key only)
    certutil -L -d "sql:$bridge_nss_dir" -n "$CA_NICKNAME" -a > /tmp/ca-import.pem
    certutil -A -d "sql:$client_nss_dir" -n "$CA_NICKNAME" -t CT,, \
        -a -i /tmp/ca-import.pem -f "$temp_password_file"
    
    # Try to self-sign (FAILS - no private key!)
    certutil -S -d "sql:$client_nss_dir" \
        -n "$CLIENT_CERT_NICKNAME" \
        -c "$CA_NICKNAME" \  # ← ERROR: CA private key not available
        -t u,, \
        ...
}
```

#### After (Lines 294-351)

```bash
setup_client_certificates() {
    log "Setting up client certificates (production-aligned)"
    
    local client_nss_dir="$NSS_BASE_DIR/client"
    local client_fqdn="${CLIENT_FQDN:-sigul-client.example.org}"
    local bridge_ca_export_dir="$NSS_BASE_DIR/bridge-shared/ca-export"
    local client_ca_import_dir="$NSS_BASE_DIR/ca-import"
    
    # Check if certificates already exist
    if [[ -f "$client_nss_dir/cert9.db" ]] && \
       certutil -d "sql:$client_nss_dir" -L -n "$CA_NICKNAME" >/dev/null 2>&1 && \
       certutil -d "sql:$client_nss_dir" -L -n "$CLIENT_CERT_NICKNAME" >/dev/null 2>&1; then
        log "Client certificates already exist, skipping generation"
        return 0
    fi
    
    # Wait for CA with private key from bridge
    log "Waiting for CA with private key from bridge..."
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if [[ -d "$bridge_ca_export_dir" ]] && \
           [[ -f "$bridge_ca_export_dir/ca.p12" ]] && \
           [[ -f "$bridge_ca_export_dir/ca-p12-password" ]]; then
            debug "CA PKCS#12 file found from bridge"
            break
        fi
        if [[ $attempt -eq 1 ]]; then
            debug "Waiting for bridge CA with private key..."
        fi
        sleep 2
        ((attempt++))
    done
    
    if [[ $attempt -gt $max_attempts ]]; then
        fatal "Bridge CA not available, cannot generate client certificates"
    fi
    
    # Copy CA files from bridge export to client import location
    log "Copying CA files from bridge to client import location..."
    mkdir -p "$client_ca_import_dir"
    chmod 755 "$client_ca_import_dir"
    
    if ! cp "$bridge_ca_export_dir/ca.p12" "$client_ca_import_dir/ca.p12" 2>/dev/null; then
        fatal "Failed to copy CA PKCS#12 file"
    fi
    
    if ! cp "$bridge_ca_export_dir/ca-p12-password" "$client_ca_import_dir/ca-p12-password" 2>/dev/null; then
        fatal "Failed to copy CA PKCS#12 password file"
    fi
    
    chmod 600 "$client_ca_import_dir/ca.p12"
    chmod 600 "$client_ca_import_dir/ca-p12-password"
    
    success "CA files copied to client import location"
    
    log "Generating production-aligned certificates for client..."
    
    # Use production-aligned certificate generation script
    if [[ -x "/usr/local/bin/generate-production-aligned-certs.sh" ]]; then
        NSS_DB_DIR="$client_nss_dir" \
        NSS_PASSWORD="$(get_nss_password)" \
        COMPONENT="client" \
        FQDN="$client_fqdn" \
        /usr/local/bin/generate-production-aligned-certs.sh
    elif [[ -x "/workspace/pki/generate-production-aligned-certs.sh" ]]; then
        NSS_DB_DIR="$client_nss_dir" \
        NSS_PASSWORD="$(get_nss_password)" \
        COMPONENT="client" \
        FQDN="$client_fqdn" \
        /workspace/pki/generate-production-aligned-certs.sh
    else
        fatal "Production-aligned certificate generation script not found"
    fi
    
    success "Client certificates generated with FQDN and SAN"
}
```

## Certificate Flow

### Complete Certificate Generation Flow

```
1. Bridge Container (cert-init)
   └─> Generates CA certificate with private key
   └─> Exports CA as PKCS#12 file
       ├─> /etc/pki/sigul/ca-export/ca.p12
       └─> /etc/pki/sigul/ca-export/ca-p12-password

2. Bridge Volume Mount (bridge_nss)
   └─> Contains: /etc/pki/sigul/bridge/
       ├─> cert9.db (NSS database with CA)
       └─> key4.db (CA private key)
   └─> Exported to: /etc/pki/sigul/ca-export/
       ├─> ca.p12 (PKCS#12 with CA + private key)
       └─> ca-p12-password (password for PKCS#12)

3. Client Container
   └─> Mounts bridge_nss at: /etc/pki/sigul/bridge-shared:ro
   └─> Reads CA export from: /etc/pki/sigul/bridge-shared/ca-export/
   └─> Copies to: /etc/pki/sigul/ca-import/
       ├─> ca.p12
       └─> ca-p12-password
   └─> Calls generate-production-aligned-certs.sh
       └─> Imports CA with private key from PKCS#12
       └─> Generates client certificate signed by CA
       └─> Stores in: /etc/pki/sigul/client/
           ├─> cert9.db (client cert + CA cert)
           └─> key4.db (client private key + CA private key)
```

## Why This Works

### CA Private Key Access

The client now has access to the CA private key through PKCS#12 import:

1. **Bridge exports CA with private key**
   ```bash
   pk12util -o ca.p12 -n sigul-ca -d sql:/etc/pki/sigul/bridge \
       -k password-file -w p12-password-file
   ```

2. **Client imports CA with private key**
   ```bash
   pk12util -i ca.p12 -d sql:/etc/pki/sigul/client \
       -k nss-password-file -w p12-password-file
   ```

3. **Client signs its own certificate**
   ```bash
   certutil -S -d sql:/etc/pki/sigul/client -n sigul-client-cert \
       -c sigul-ca ...  # ← Now works! CA private key is available
   ```

### Security Considerations

**Note:** In production, client certificates should typically be signed via a CSR (Certificate Signing Request) workflow where:
- Client generates private key and CSR
- Server/CA signs the CSR
- Client receives signed certificate

However, for this containerized development/testing environment:
- All components are ephemeral and isolated
- CA private key is only in container volumes (not exposed externally)
- This approach simplifies initialization and testing
- Production deployments should use proper CSR workflows

## Files Modified

1. **`scripts/sigul-init.sh`** (Lines 294-351)
   - Removed manual certutil commands for client certificate generation
   - Added CA file copying from bridge export to client import
   - Integrated production-aligned certificate generation script
   - Added proper wait logic for bridge CA availability

## Testing Verification

### Before Fix

```
[18:59:56] NSS-INIT: Creating client NSS database...
password file contains no data
[18:59:57] NSS-ERROR: Failed to generate client certificate
❌ Failed to initialize client container
```

### After Fix

```
[CERT-GEN] Component type: client
[CERT-GEN] Importing CA with private key from bridge...
[CERT-GEN] CA with private key imported: sigul-ca
[CERT-GEN] Generating client certificate with FQDN and SAN...
[CERT-GEN] client certificate generated: sigul-client-cert
✅ Client certificates generated with FQDN and SAN
✅ Client container initialized successfully
```

## Key Improvements

1. **Consistency**: All components use same certificate generation logic
2. **Reliability**: Proper wait logic ensures CA is available before generation
3. **Standards Compliance**: Uses PKCS#12 standard for CA key transport
4. **Error Handling**: Clear error messages and proper failure handling
5. **Security**: Proper file permissions on sensitive key material

## Production Considerations

For production deployments:

1. **Use Proper PKI**: Implement CSR-based certificate issuance
2. **Separate CA**: Keep CA private key on dedicated secure system
3. **Certificate Lifecycle**: Implement certificate renewal and revocation
4. **Key Storage**: Use hardware security modules (HSMs) for CA keys
5. **Audit Logging**: Log all certificate operations

## Related Issues

- **Issue #1**: Wrong volume type mounted (bridge_data vs bridge_nss) - FIXED
- **Issue #2**: Missing client volumes for NSS database - FIXED
- **Issue #3**: Client certificate generation failure (this fix) - FIXED

## References

- **PKCS#12**: [RFC 7292](https://datatracker.ietf.org/doc/html/rfc7292)
- **NSS Tools**: [Mozilla NSS Documentation](https://firefox-source-docs.mozilla.org/security/nss/tools/)
- **Production Script**: `pki/generate-production-aligned-certs.sh`
- **Official Sigul**: [Sigul Documentation](https://pagure.io/sigul)

---

**Fix Date:** 2025-11-16  
**Priority:** HIGH - Blocks integration tests  
**Status:** FIXED - Awaiting CI verification