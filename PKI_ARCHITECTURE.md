# Sigul PKI Architecture Documentation

**Version:** 2.0.0  
**Date:** 2025-01-XX  
**Status:** Production-Aligned

---

## Overview

This document describes the proper PKI (Public Key Infrastructure) architecture for the Sigul container stack, aligned with official Sigul documentation and security best practices.

## Architecture Principles

### Key Design Decisions

1. **Bridge as Certificate Authority**
   - The bridge component acts as the CA
   - Bridge has exclusive access to CA private key
   - Bridge pre-generates ALL certificates during initialization

2. **Pre-Generation Strategy**
   - All certificates (bridge, server, client) are generated on the bridge
   - Certificates are distributed as needed during component initialization
   - No runtime certificate generation required

3. **Security Best Practices**
   - CA private key NEVER leaves the bridge
   - Server and client receive only CA public certificate
   - Each component receives only its own certificate + private key
   - Principle of least privilege applied consistently

---

## Certificate Generation Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    INITIALIZATION PHASE                      │
│                                                              │
│  1. cert-init container starts                              │
│  2. Bridge NSS database initialized                         │
│  3. CA certificate generated (on bridge)                    │
│  4. Bridge certificate generated and signed by CA           │
│  5. Server certificate generated and signed by CA           │
│  6. Client certificate(s) generated and signed by CA        │
│  7. Certificates exported to designated directories         │
│  8. Configuration files generated                           │
│                                                              │
│  Result: Bridge has complete PKI infrastructure             │
└─────────────────────────────────────────────────────────────┘
```

---

## Component Certificate Details

### Bridge Component

**Location:** `/etc/pki/sigul/bridge`

**Certificates in NSS Database:**
- `sigul-ca` - CA certificate WITH private key
- `sigul-bridge-cert` - Bridge certificate + private key
- `sigul-server-cert` - Server certificate + private key (for export)
- `sigul-client-cert` - Client certificate + private key (for export)

**Export Directories:**
- `/etc/pki/sigul/bridge/../ca-export/ca.crt` - CA public certificate
- `/etc/pki/sigul/bridge/../server-export/server-cert.p12` - Server cert + key
- `/etc/pki/sigul/bridge/../client-export/client-cert.p12` - Client cert + key

**Security Status:**
- ✓ Has CA private key (certificate authority)
- ✓ Can sign new certificates
- ✓ Pre-generates all infrastructure certificates

**Configuration:** `/etc/sigul/bridge.conf`

---

### Server Component

**Location:** `/etc/pki/sigul/server`

**Certificates in NSS Database:**
- `sigul-ca` - CA certificate (PUBLIC ONLY, no private key)
- `sigul-server-cert` - Server certificate + private key

**Import Process:**
1. Run `/usr/local/bin/init-server-certs.sh`
2. Import CA public certificate from bridge export
3. Import server certificate + key from bridge export
4. Verify CA private key is NOT present

**Security Status:**
- ✓ Has CA public certificate only
- ✓ Cannot sign certificates
- ✓ Has own certificate for TLS
- ✗ Does NOT have CA private key

**Configuration:** `/etc/sigul/server.conf`

---

### Client Component

**Location:** `/etc/pki/sigul/client`

**Certificates in NSS Database:**
- `sigul-ca` - CA certificate (PUBLIC ONLY, no private key)
- `sigul-client-cert` - Client certificate + private key

**Import Process:**
1. Run `/usr/local/bin/init-client-certs.sh`
2. Import CA public certificate from bridge export
3. Import client certificate + key from bridge export
4. Verify CA private key is NOT present

**Security Status:**
- ✓ Has CA public certificate only
- ✓ Cannot sign certificates
- ✓ Has own certificate for TLS
- ✗ Does NOT have CA private key

**Configuration:** `/etc/sigul/client.conf` (if needed)

---

## Volume Architecture

### Bridge NSS Volume

**Volume:** `sigul_bridge_nss`  
**Mount Point:** `/etc/pki/sigul/bridge`  
**Access:**
- Bridge: Read-Write
- Server: Read-Only (import phase only)
- Client: Read-Only (import phase only)

**Contents:**
```
/etc/pki/sigul/bridge/
├── cert9.db              # NSS certificate database
├── key4.db               # NSS key database
├── pkcs11.txt            # NSS configuration
├── .nss-password         # Password file
├── .noise                # Entropy for key generation
└── ../                   # Parent directory exports
    ├── ca-export/
    │   └── ca.crt        # CA public certificate
    ├── server-export/
    │   ├── server-cert.p12
    │   ├── server-cert.crt
    │   └── server-cert.p12.password
    └── client-export/
        ├── client-cert.p12
        ├── client-cert.crt
        └── client-cert.p12.password
```

**Security:**
- Contains CA private key (critical security asset)
- Should be backed up securely
- Should never be exposed outside bridge container

### Server NSS Volume

**Volume:** `sigul_server_nss`  
**Mount Point:** `/etc/pki/sigul/server`  
**Access:** Server: Read-Write

**Contents:**
```
/etc/pki/sigul/server/
├── cert9.db              # NSS certificate database
├── key4.db               # NSS key database
├── pkcs11.txt            # NSS configuration
└── .nss-password         # Password file
```

**Security:**
- Does NOT contain CA private key
- Contains server certificate + private key only
- Can be backed up

### Client NSS Volume

**Volume:** `sigul_client_nss`  
**Mount Point:** `/etc/pki/sigul/client`  
**Access:** Client: Read-Write

**Contents:**
```
/etc/pki/sigul/client/
├── cert9.db              # NSS certificate database
├── key4.db               # NSS key database
├── pkcs11.txt            # NSS configuration
└── .nss-password         # Password file
```

**Security:**
- Does NOT contain CA private key
- Contains client certificate + private key only
- Can be backed up

---

## Initialization Scripts

### `/usr/local/bin/cert-init.sh`

**Purpose:** Generate complete PKI infrastructure on bridge  
**Runs on:** cert-init container (bridge-based)  
**Mode:** One-time initialization

**What it does:**
1. Creates bridge NSS database
2. Generates CA certificate (with private key)
3. Generates bridge certificate (signed by CA)
4. Generates server certificate (signed by CA)
5. Generates client certificate (signed by CA)
6. Exports certificates to designated directories
7. Generates bridge and server configuration files

**Environment Variables:**
- `NSS_PASSWORD` - NSS database password (required)
- `BRIDGE_FQDN` - Bridge FQDN (default: sigul-bridge.example.org)
- `SERVER_FQDN` - Server FQDN (default: sigul-server.example.org)
- `CLIENT_FQDN` - Client FQDN (default: sigul-client.example.org)
- `CERT_INIT_MODE` - Mode: auto, force, skip (default: auto)
- `CA_VALIDITY_MONTHS` - CA validity in months (default: 120)
- `CERT_VALIDITY_MONTHS` - Certificate validity in months (default: 120)

### `/usr/local/bin/init-server-certs.sh`

**Purpose:** Import server certificates from bridge  
**Runs on:** sigul-server container  
**Mode:** Every container start (idempotent)

**What it does:**
1. Creates server NSS database
2. Imports CA public certificate from bridge export
3. Imports server certificate + key from bridge export
4. Verifies CA private key is NOT present (security check)

**Environment Variables:**
- `NSS_PASSWORD` - NSS database password (required)

### `/usr/local/bin/init-client-certs.sh`

**Purpose:** Import client certificates from bridge  
**Runs on:** sigul-client-test container  
**Mode:** Every container start (idempotent)

**What it does:**
1. Creates client NSS database
2. Imports CA public certificate from bridge export
3. Imports client certificate + key from bridge export
4. Verifies CA private key is NOT present (security check)

**Environment Variables:**
- `NSS_PASSWORD` - NSS database password (required)

---

## Docker Compose Integration

### Service Dependency Chain

```
cert-init (pre-generates all certs)
    ↓
sigul-bridge (starts with complete PKI)
    ↓ (waits for bridge health check)
sigul-server (imports certs, then starts)
    ↓
sigul-client-test (imports certs, then starts)
```

### Volume Mounts

**cert-init:**
```yaml
volumes:
  - sigul_bridge_nss:/etc/pki/sigul/bridge:rw
  - sigul_shared_config:/etc/sigul:rw
```

**sigul-bridge:**
```yaml
volumes:
  - sigul_bridge_nss:/etc/pki/sigul/bridge:rw
  - sigul_shared_config:/etc/sigul:rw
  # ... other volumes
```

**sigul-server:**
```yaml
volumes:
  - sigul_server_nss:/etc/pki/sigul/server:rw
  - sigul_shared_config:/etc/sigul:rw
  - sigul_bridge_nss:/etc/pki/sigul/bridge:ro  # Read-only for import
  # ... other volumes
```

**sigul-client-test:**
```yaml
volumes:
  - sigul_client_nss:/etc/pki/sigul/client:rw
  - sigul_client_config:/etc/sigul:rw
  - sigul_bridge_nss:/etc/pki/sigul/bridge:ro  # Read-only for import
  # ... other volumes
```

---

## Security Validation

### Automated Security Checks

Each component's initialization script includes security validation:

1. **Server Security Check:**
   ```bash
   if certutil -K -d "sql:${SERVER_NSS_DIR}" | grep -q "${CA_NICKNAME}"; then
       echo "⚠️  SECURITY ISSUE: CA private key found on server!"
       exit 1
   fi
   ```

2. **Client Security Check:**
   ```bash
   if certutil -K -d "sql:${CLIENT_NSS_DIR}" | grep -q "${CA_NICKNAME}"; then
       echo "⚠️  SECURITY ISSUE: CA private key found on client!"
       exit 1
   fi
   ```

### Manual Verification

To manually verify the PKI architecture:

```bash
# Check bridge has CA private key
docker exec sigul-bridge certutil -K -d sql:/etc/pki/sigul/bridge

# Expected: Should show CA private key

# Check server does NOT have CA private key
docker exec sigul-server certutil -K -d sql:/etc/pki/sigul/server

# Expected: Should NOT show CA private key

# Check client does NOT have CA private key
docker exec sigul-client-test certutil -K -d sql:/etc/pki/sigul/client

# Expected: Should NOT show CA private key
```

---

## Migration from Previous Architecture

### What Changed

**Before (Incorrect):**
- CA private key was exported from bridge
- Server imported CA private key (security issue)
- Client might have imported CA private key (security issue)
- Certificates generated separately on each component

**After (Correct):**
- CA private key stays on bridge only
- Bridge pre-generates all certificates
- Server and client import only their certificates + CA public cert
- No component except bridge can sign certificates

### Migration Steps

If migrating from the old architecture:

1. **Stop all containers:**
   ```bash
   docker compose -f docker-compose.sigul.yml down
   ```

2. **Remove old volumes (data loss warning):**
   ```bash
   docker volume rm sigul_bridge_nss sigul_server_nss sigul_client_nss
   ```

3. **Deploy with new architecture:**
   ```bash
   CERT_INIT_MODE=force docker compose -f docker-compose.sigul.yml up -d
   ```

4. **Verify security:**
   ```bash
   # Run security checks as documented above
   ```

---

## Troubleshooting

### Certificate Import Fails

**Symptom:** Server or client cannot import certificates

**Diagnosis:**
```bash
# Check if cert-init completed
docker logs sigul-cert-init

# Check export directory exists
docker exec sigul-bridge ls -la /etc/pki/sigul/ca-export
docker exec sigul-bridge ls -la /etc/pki/sigul/server-export
docker exec sigul-bridge ls -la /etc/pki/sigul/client-export
```

**Solution:**
- Ensure cert-init container completed successfully
- Check bridge NSS volume is properly mounted
- Verify NSS_PASSWORD is consistent across all components

### CA Private Key Detected on Server/Client

**Symptom:** Security check fails during initialization

**Diagnosis:**
```bash
# Check for CA private key presence
docker exec sigul-server certutil -K -d sql:/etc/pki/sigul/server
docker exec sigul-client-test certutil -K -d sql:/etc/pki/sigul/client
```

**Solution:**
- This indicates incorrect certificate import
- Remove affected NSS volumes
- Re-run initialization with CERT_INIT_MODE=force
- Verify init scripts are the updated versions

### Certificates Not Found

**Symptom:** Bridge or server cannot find required certificates

**Diagnosis:**
```bash
# List certificates in bridge database
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge

# List certificates in server database
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul/server
```

**Solution:**
- Verify cert-init ran successfully
- Check certificate nicknames match configuration
- Re-run initialization if needed

---

## References

- Official Sigul Documentation: https://github.com/ModeSevenIndustrialSolutions/sigul
- NSS Tools Documentation: https://developer.mozilla.org/en-US/docs/Mozilla/Projects/NSS/tools
- FHS (Filesystem Hierarchy Standard): https://refspecs.linuxfoundation.org/FHS_3.0/

---

## Changelog

### Version 2.0.0 (2025-01-XX)

**Major Changes:**
- Implemented proper PKI architecture with bridge as CA
- Bridge pre-generates all certificates during initialization
- Server and client import certificates without CA private key
- Added security validation checks
- Updated Docker Compose for proper certificate distribution
- Created dedicated initialization scripts for each component

**Breaking Changes:**
- Old certificates are incompatible (requires volume recreation)
- CA private key no longer distributed to server/client
- Certificate import process changed

**Migration Required:** Yes - see Migration section above

### Version 1.0.0 (Previous)

- Initial implementation (incorrect PKI architecture)
- CA private key was distributed to components
- Each component generated its own certificates

---

**Document Maintained By:** Linux Foundation Release Engineering  
**Last Updated:** 2025-01-XX  
**Next Review:** 2025-06-XX