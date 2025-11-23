# CI Debug Log Analysis - Quick Reference Guide

**Purpose**: Quick reference for analyzing Sigul integration test logs with comprehensive debugging enabled  
**Date**: 2025-01-17  
**Related**: DEBUGGING_STRATEGY.md, DEBUGGING_IMPLEMENTATION_SUMMARY.md

---

## Quick Start

1. Go to: https://github.com/modeseven-lfreleng-actions/sigul-docker/actions
2. Find the workflow run for commit `63a17f0` or later
3. Open "Integration Tests" step
4. Search for debug markers (see below)

---

## Debug Markers to Search For

Use these search strings in CI logs:

### Primary Markers
```
==================== NSS INITIALIZATION DEBUG ====================
==================== CLIENT CONNECTION STARTING ====================
==================== DOUBLE-TLS CLIENT INIT DEBUG ====================
==================== CHILD PROCESS SSL CONNECTION DEBUG ====================
```

### Success Indicators
```
✓ NSS database initialized successfully
✓ NSS password authentication successful
✓ Found certificate:
✓ TCP connection established
✓ SSL handshake with bridge completed successfully
✓ Bridge certificate:
```

### Failure Indicators
```
✗ Certificate not found:
✗ Error finding certificate:
✗ Connection attempt failed:
✗ Connection refused by server
✗ Connection failed with error:
✗ NSPR error:
==================== CHILD EXITING:
```

---

## Analysis Workflow

### Step 1: Check NSS Initialization

**Search for**: `==================== NSS INITIALIZATION DEBUG`

**Look for**:
```
NSS_DIR: /etc/pki/sigul/client
NSS_PASSWORD length: 16
✓ NSS database initialized successfully
✓ NSS password authentication successful
Available certificates in NSS database:
  - CN=sigul-ca,O=Sigul Test CA
  - CN=sigul-bridge-cert,O=Sigul Test CA
  - CN=sigul-client-cert,O=Sigul Test CA
```

**Red flags**:
- ✗ NSS_PASSWORD length: 0
- ✗ NSS_DIR: wrong path
- ✗ Certificates list is empty or incomplete
- ✗ Authentication failed
- ✗ Error messages about "SEC_ERROR_BAD_DATABASE"

### Step 2: Check Connection Attempt

**Search for**: `==================== CLIENT CONNECTION STARTING`

**Look for**:
```
Operation: new-user
Bridge: sigul-bridge:44334
Client cert: sigul-client-cert
```

**Red flags**:
- Wrong bridge hostname
- Wrong port number
- Wrong certificate nickname

### Step 3: Check Double-TLS Setup

**Search for**: `==================== DOUBLE-TLS CLIENT INIT DEBUG`

**Look for**:
```
Bridge hostname: sigul-bridge
Bridge port: 44334
Client cert nickname: sigul-client-cert
```

**Red flags**:
- Mismatch with client connection parameters
- Exception or error immediately after this section

### Step 4: Check SSL Connection Process

**Search for**: `==================== CHILD PROCESS SSL CONNECTION DEBUG`

**This is the critical section - watch carefully!**

**Expected sequence**:
```
Attempting SSL connection to sigul-bridge:44334
Looking up certificate nickname: sigul-client-cert
✓ Found certificate: CN=sigul-client-cert,O=Sigul Test CA
Setting client auth callback with certificate
Trying address: 172.18.0.X
Attempting TCP connect to sigul-bridge:44334...
✓ TCP connection established
Starting SSL handshake with bridge...
✓ SSL handshake with bridge completed successfully
✓ Bridge certificate: CN=sigul-bridge-cert,O=Sigul Test CA
Starting bidirectional forwarding (double-TLS active)...
```

**Failure points and meanings**:

| Failure After This Line | Root Cause | Next Action |
|------------------------|------------|-------------|
| "Looking up certificate nickname" | Certificate not in NSS DB | Check cert import |
| "Attempting TCP connect" | Bridge not ready/unreachable | Check bridge logs |
| "Starting SSL handshake" | Certificate trust issue | Check trust flags |
| "Starting bidirectional forwarding" | Inner TLS or auth issue | Check server logs |

### Step 5: Check for Error Exits

**Search for**: `==================== CHILD EXITING:`

**Types**:
- `CONNECTION REFUSED` - Bridge not accepting connections
- `NSPR ERROR` - SSL/TLS protocol issue
- `NSS INIT ERROR` - Certificate or database problem
- `UNEXPECTED EXCEPTION` - Code error (bug or environment)

---

## Common Failure Patterns

### Pattern 1: Certificate Not Found
```
Looking up certificate nickname: sigul-client-cert
✗ Certificate not found: SEC_ERROR_BAD_DATABASE
```
**Diagnosis**: Certificate not imported or wrong nickname  
**Fix**: Check `scripts/init-client-certs.sh`

### Pattern 2: Password Mismatch
```
NSS_PASSWORD length: 16
✗ NSS password authentication failed
Error: SEC_ERROR_BAD_PASSWORD
```
**Diagnosis**: NSS password doesn't match database  
**Fix**: Check password generation and storage

### Pattern 3: TCP Connection Refused
```
Attempting TCP connect to sigul-bridge:44334...
✗ Connection attempt failed: Connection refused
```
**Diagnosis**: Bridge not ready or not listening  
**Fix**: Check bridge container and readiness checks

### Pattern 4: SSL Handshake Failure
```
✓ TCP connection established
Starting SSL handshake with bridge...
✗ NSPR error: SSL_ERROR_BAD_CERT_ALERT
```
**Diagnosis**: Certificate rejected by bridge  
**Fix**: Check certificate trust chain and validity

### Pattern 5: Unexpected EOF (The Original Issue)
```
✓ SSL handshake with bridge completed successfully
Starting bidirectional forwarding (double-TLS active)...
[some time passes]
✗ Unexpected EOF on outer stream
```
**Diagnosis**: Inner TLS (bridge→server) failing  
**Fix**: Check server logs and bridge→server connection

---

## Diagnostic Commands

If you have access to the CI environment or can reproduce locally:

### Check NSS Database
```bash
docker exec sigul-client-integration certutil -L -d sql:/etc/pki/sigul/client
```

### Check Certificate Details
```bash
docker exec sigul-client-integration certutil -L -d sql:/etc/pki/sigul/client -n sigul-ca
```

### Check Bridge Logs
```bash
docker logs sigul-bridge --tail 100
```

### Check Server Logs
```bash
docker logs sigul-server --tail 100
```

### Test Direct Connection
```bash
docker exec sigul-client-integration nc -zv sigul-bridge 44334
```

---

## Decision Tree

```
Start: Integration test fails
  |
  ├─> No NSS debug section visible?
  |     └─> Problem: Client container didn't start or patches not applied
  |           Fix: Check Docker build logs
  |
  ├─> NSS init shows errors?
  |     ├─> Empty certificate list?
  |     |     └─> Fix: Certificate import script
  |     └─> Password authentication failed?
  |           └─> Fix: Password generation/storage
  |
  ├─> Connection debug shows wrong parameters?
  |     └─> Fix: Client configuration file
  |
  ├─> Certificate not found in child process?
  |     └─> Fix: Certificate nickname mismatch
  |
  ├─> TCP connection fails?
  |     └─> Fix: Bridge readiness checks or networking
  |
  ├─> SSL handshake fails (after TCP success)?
  |     └─> Fix: Certificate trust flags or validity
  |
  └─> Unexpected EOF (after handshake success)?
        └─> Fix: Bridge→server connection or authentication
```

---

## Success Example

Complete successful log excerpt:

```
[2025-01-17 XX:XX:XX] INFO: Running integration tests...
[2025-01-17 XX:XX:XX] DEBUG: Creating integration test user...

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

[2025-01-17 XX:XX:XX] INFO: ✓ User 'integration-tester' created successfully
```

---

## Quick Troubleshooting Checklist

- [ ] All debug sections present in logs?
- [ ] NSS database shows all 3 certificates?
- [ ] Password authentication successful?
- [ ] Certificate found by nickname?
- [ ] TCP connection established?
- [ ] SSL handshake completed?
- [ ] Bridge certificate received?
- [ ] Bidirectional forwarding started?
- [ ] User creation completed?

If all checked: **Success!**  
If any unchecked: **See failure pattern matching that step**

---

## Getting Help

If debugging reveals an unclear issue:

1. Copy the relevant debug section from logs
2. Note which step shows the failure
3. Check the DEBUGGING_STRATEGY.md for detailed analysis
4. Review related documentation:
   - PKI_ARCHITECTURE.md
   - DEPLOYMENT_GUIDE.md
   - TLS_DEBUG_SUMMARY.md

---

*Last Updated: 2025-01-17*  
*Version: 1.0 (Initial release with comprehensive debugging)*