<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Production vs Local Sigul Stack Comparison

**Date:** 2024-11-24
**Purpose:** Document differences between production Sigul infrastructure and local Docker stack

---

## Overview

This document compares the production Sigul infrastructure (deployed on AWS) with the local Docker-based development/testing stack to identify configuration and architectural differences that may affect client connectivity.

---

## 1. NSS Database Format

### Production (Bridge & Server)
- **Format:** Legacy NSS database (Berkeley DB 1.85)
- **Files:** `cert8.db`, `key3.db`, `secmod.db`
- **Path:** `/etc/pki/sigul/`
- **Created:** 2021 (stable, no migrations)

### Local Docker Stack
- **Format:** New NSS database (SQLite-based)
- **Files:** `cert9.db`, `key4.db`, `pkcs11.txt`
- **Path:** `/etc/pki/sigul/bridge/`, `/etc/pki/sigul/server/`, `/etc/pki/sigul/client/`
- **Created:** On-demand during container initialization

### Impact
- **Compatibility:** Both formats are supported by modern NSS libraries
- **Migration:** NSS automatically upgrades old → new format when accessed
- **Risk:** Minimal - both formats should work identically for TLS operations

---

## 2. Certificate Authority Structure

### Production
```
CA: EasyRSA
├── Bridge: sigul-bridge-us-west-2.linuxfoundation.org
├── Server: aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org
└── Clients:
    ├── aws-us-west-2-dent-jenkins-1.ci.codeaurora.org
    ├── aws-us-west-2-dent-jenkins-sandbox-1.ci.codeaurora.org
    └── [other jenkins instances]

Trust Flags:
- easyrsa: CT,, (Trusted CA for SSL)
- All certs: u,u,u (User certs)
```

### Local Docker Stack
```
CA: Sigul CA (self-signed)
├── Bridge: sigul-bridge-cert (sigul-bridge.example.org)
├── Server: sigul-server-cert (sigul-server.example.org)
└── Client: sigul-client-cert (sigul-client.example.org)

Trust Flags:
- sigul-ca: CTu,Cu,Cu (Trusted CA for SSL, Email, Objects + User)
- sigul-bridge-cert: u,u,u (User cert)
- sigul-server-cert: u,u,u (User cert)
- sigul-client-cert: u,u,u (User cert)
```

### Impact
- **Structure:** Production uses EasyRSA (external PKI tool), local uses self-signed CA
- **Trust Model:** Same trust model - CA is trusted, certs are signed by CA
- **Issue:** Local CA has broader trust flags (CTu vs CT) - this is acceptable

---

## 3. Certificate Attributes

### Production Client Certificate Example
```
Subject: CN=aws-us-west-2-dent-jenkins-1.ci.codeaurora.org
Issuer: CN=EasyRSA
SAN: DNS:aws-us-west-2-dent-jenkins-1.ci.codeaurora.org
Key Usage: Digital Signature, Key Encipherment
Extended Key Usage: TLS Web Server Authentication, TLS Web Client Authentication
```

### Local Client Certificate
```
Subject: CN=sigul-client.example.org,O=Sigul Infrastructure,OU=client
Issuer: CN=Sigul CA,O=Sigul Infrastructure,OU=Certificate Authority
SAN: DNS:sigul-client.example.org
Key Usage: Digital Signature, Key Encipherment
Extended Key Usage: TLS Web Server Authentication, TLS Web Client Authentication
```

### Impact
- **Compatible:** Both have correct Key Usage and Extended Key Usage for mutual TLS
- **Difference:** Production certs are simpler (CN only), local includes O and OU
- **Issue:** No compatibility issues identified

---

## 4. Bridge Configuration

### Production
```ini
[bridge]
bridge-cert-nickname: sigul-bridge-us-west-2.linuxfoundation.org
client-listen-port: 44334
server-listen-port: 44333

[nss]
nss-dir: /etc/pki/sigul
nss-password: <redacted>
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

**Note:** No `bridge-ca-cert-nickname` in production configuration

### Local Docker Stack
```ini
[bridge]
bridge-cert-nickname: sigul-bridge-cert
client-listen-port: 44334
server-listen-port: 44333

# CUSTOM ADDITION (not in upstream Sigul)
bridge-ca-cert-nickname: sigul-ca

[nss]
nss-dir: /etc/pki/sigul/bridge
nss-password: <generated>
nss-min-tls: tls1.2
```

### Impact
- **⚠️ CRITICAL FINDING:** `bridge-ca-cert-nickname` is **not used** by Sigul bridge source code
- **Effect:** This configuration parameter has no effect on client certificate validation
- **Validation:** Bridge validates client certs against ALL trusted CAs in NSS database (default NSS behavior)
- **Action:** Remove this parameter from local configuration (cosmetic only)

---

## 5. Server Configuration

### Production
```ini
[server]
bridge-hostname: sigul-bridge-us-west-2.linuxfoundation.org
bridge-port: 44333
server-cert-nickname: aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org

[nss]
nss-dir: /etc/pki/sigul
nss-password: <redacted>
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

### Local Docker Stack
```ini
[server]
bridge-hostname: sigul-bridge
bridge-port: 44333
server-cert-nickname: sigul-server-cert

[nss]
nss-dir: /etc/pki/sigul/server
nss-password: <generated>
nss-min-tls: tls1.2
```

### Impact
- **Compatible:** Same structure and parameters
- **Difference:** Hostname references (production uses FQDN, local uses short names)

---

## 6. Client TLS Behavior

### Sigul Source Code Analysis

**Client Certificate Loading (`client.py` → `double_tls.py` → `utils.py`):**

```python
# utils.py - nss_init()
def nss_init(config):
    def _password_callback(unused_slot, retry):
        if not retry:
            return config.nss_password
        return None

    nss.nss.set_password_callback(_password_callback)
    nss.nss.nss_init(config.nss_dir)
    nss.nss.get_internal_key_slot().authenticate()
```

**Client Certificate Presentation (`double_tls.py`):**

```python
cert = nss.nss.find_cert_from_nickname(cert_nickname)
socket_fd.set_client_auth_data_callback(
    utils.nss_client_auth_callback_single, cert)

# utils.py
def nss_client_auth_callback_single(unused_ca_names, cert):
    return (cert, nss.nss.find_key_by_any_cert(cert))
```

**Bridge TLS Configuration (`bridge.py`):**

```python
sock.set_ssl_option(nss.ssl.SSL_REQUEST_CERTIFICATE, True)
sock.set_ssl_option(nss.ssl.SSL_REQUIRE_CERTIFICATE, True)
sock.config_secure_server(cert, nss.nss.find_key_by_any_cert(cert),
                          cert.find_kea_type())
```

### Key Findings

1. **Password Callback:** Single-shot password callback (no retry on first failure)
2. **Certificate Selection:** Client presents certificate by nickname
3. **Private Key Access:** Retrieved via `find_key_by_any_cert()` during callback
4. **Bridge Validation:** Bridge REQUIRES client certificate, validates against trusted CAs

---

## 7. Observed Client Connection Errors

### Test Results (Local Stack)

**DNS Resolution Test:**
```
✓ DNS resolution works with --add-host flag
  sigul-bridge.example.org → 172.20.0.2
```

**Certificate Validation:**
```
✓ Client certificates imported successfully
✓ CA certificate trusted (CT,C,C flags)
✓ Client certificate found (sigul-client-cert)
✓ Private key accessible via Python NSS
```

**TLS Handshake (tstclnt):**
```
✗ ERROR: SSL_ERROR_BAD_CERT_ALERT: SSL peer cannot verify your certificate
✗ ERROR: Incorrect password/PIN entered
✗ ERROR: Failed to load a suitable client certificate
```

**Sigul Client:**
```
✗ ERROR: I/O error: Unexpected EOF in NSPR
```

### Analysis

1. **Root Cause:** Client certificate private key cannot be accessed during TLS handshake
2. **Symptom:** Bridge rejects connection → immediate disconnect → "Unexpected EOF"
3. **Evidence:**
   - Python NSS can access key successfully outside TLS context
   - tstclnt shows "Incorrect password/PIN" during handshake
   - Certificate itself is valid and trusted

---

## 8. Differences That May Affect Client Authentication

| Aspect | Production | Local Docker | Impact |
|--------|-----------|--------------|--------|
| NSS DB Format | cert8.db (old) | cert9.db (new) | **Low** - Both formats supported |
| Certificate Import | Manual/EasyRSA | Automated/PKCS#12 | **Medium** - Different import methods |
| Password Storage | Config file | Config file + NSS password file | **Medium** - Multiple password sources |
| Certificate Nickname | FQDN-based | Generic (sigul-client-cert) | **Low** - Both work |
| Trust Flags | CT,, | CTu,Cu,Cu | **Low** - Both trust SSL |
| DNS Resolution | Real DNS | Docker network + /etc/hosts | **Medium** - May affect cert validation |

---

## 9. Hypothesis: Password Callback Timing Issue

### Potential Issue

The error "Incorrect password/PIN entered" suggests the password callback is failing during the TLS handshake, specifically when NSS tries to access the private key.

**Possible Causes:**

1. **Timing:** Password callback invoked before NSS slot is authenticated
2. **Context:** Different security context during TLS handshake vs. manual access
3. **PKCS#12 Import:** Client cert imported from PKCS#12 may have different key protection
4. **NSS Version:** python-nss-ng behavior may differ from python-nss

### Testing Needed

1. **Verify password callback invocation:** Add logging to callback
2. **Test with cert imported differently:** Import cert/key separately (not PKCS#12)
3. **Compare with old NSS format:** Convert local DB to cert8.db format
4. **Test with manual authentication:** Pre-authenticate slot before TLS

---

## 10. Next Steps

### Immediate Actions

1. **Add debug logging to client connection:**
   - Log password callback invocations
   - Log NSS slot authentication status
   - Log certificate/key lookup results

2. **Test alternative certificate import:**
   - Import client certificate and key separately (not PKCS#12)
   - Verify key is accessible with same password

3. **Verify bridge certificate validation:**
   - Check bridge logs for client connection attempts
   - Add verbose NSS logging on bridge side

### Medium-term Actions

1. **Test with production-like setup:**
   - Use EasyRSA to generate certificates
   - Use old NSS database format (cert8.db)
   - Match production hostname structure

2. **Isolate NSS behavior:**
   - Test with minimal NSS TLS example
   - Compare python-nss vs python-nss-ng behavior

---

## 11. Conclusions

### Working Components
- ✓ NSS database initialization
- ✓ Certificate import and storage
- ✓ CA trust configuration
- ✓ Bridge-server TLS connection
- ✓ Network connectivity
- ✓ DNS resolution (with workarounds)

### Failing Components
- ✗ Client-bridge TLS handshake
- ✗ Client certificate private key access during handshake

### Likely Root Cause
**The client certificate's private key cannot be accessed during the TLS handshake, despite being accessible via Python NSS in other contexts.** This suggests a password callback timing issue or a difference in how the key was imported (PKCS#12) vs. how it's being accessed (TLS callback).

### Recommended Fix
Test importing the client certificate and private key separately (not via PKCS#12) to determine if the import method is causing the key access issue during TLS handshake.

---

## Appendix A: Test Commands

### Verify Client NSS Database
```bash
docker run --rm -v sigul-test-client-nss:/mnt sigul-client:test \
  certutil -L -d sql:/mnt
```

### Test Python NSS Access
```bash
docker run --rm -v sigul-test-client-nss:/mnt sigul-client:test \
  python3 -c "
import nss.nss as nss
nss.set_password_callback(lambda s,r: 'redhat' if not r else None)
nss.nss_init('/mnt')
nss.get_internal_key_slot().authenticate()
cert = nss.find_cert_from_nickname('sigul-client-cert')
key = nss.find_key_by_any_cert(cert)
print(f'Cert: {cert.subject}')
print('Key: Found')
"
```

### Test TLS Handshake
```bash
docker run --rm \
  --network sigul-docker_sigul-network \
  --add-host sigul-bridge.example.org:172.20.0.2 \
  -v sigul-test-client-nss:/etc/pki/sigul/client \
  sigul-client:test \
  bash -c 'echo "GET /" | tstclnt -h sigul-bridge.example.org -p 44334 \
    -d sql:/etc/pki/sigul/client -n sigul-client-cert \
    -w <(echo "redhat") -V tls1.2:tls1.2 -v'
```

---

## Appendix B: Production Certificate Examples

### Bridge Certificate (Production)
- **Subject:** CN=sigul-bridge-us-west-2.linuxfoundation.org
- **Issuer:** CN=EasyRSA
- **SAN:** sigul-bridge-us-west-2.linuxfoundation.org
- **Valid:** 2021-2031

### Client Certificate (Production)
- **Subject:** CN=aws-us-west-2-dent-jenkins-1.ci.codeaurora.org
- **Issuer:** CN=EasyRSA
- **SAN:** aws-us-west-2-dent-jenkins-1.ci.codeaurora.org
- **Valid:** 2021-2031

---

**Document Version:** 1.0
**Last Updated:** 2024-11-24
**Status:** Active Investigation
