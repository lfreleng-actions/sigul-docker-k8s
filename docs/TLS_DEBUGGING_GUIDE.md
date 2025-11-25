<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul TLS Debugging Guide

> Comprehensive guide for debugging NSS/NSPR "Unexpected EOF" errors and TLS handshake failures in the Sigul container stack.

## Table of Contents

- [Overview](#overview)
- [Understanding the Error](#understanding-the-error)
- [Quick Start](#quick-start)
- [Debugging Tools](#debugging-tools)
- [Systematic Debugging Approach](#systematic-debugging-approach)
- [Common Issues and Solutions](#common-issues-and-solutions)
- [Advanced Debugging](#advanced-debugging)
- [Troubleshooting Checklist](#troubleshooting-checklist)

---

## Overview

The "Unexpected EOF in NSPR" error is one of the most common issues when deploying Sigul in containerized environments. This guide provides a systematic approach to diagnosing and fixing TLS-related problems.

### What This Guide Covers

1. **TLS handshake failures** between Sigul components
2. **NSS database access issues** and password authentication
3. **Certificate validation problems** and trust chain issues
4. **Network connectivity** and timing problems
5. **Race conditions** during container startup

### What This Guide Does NOT Cover

- Initial Sigul setup and installation
- GPG key generation and management
- PostgreSQL database configuration
- General Docker/container troubleshooting

---

## Understanding the Error

### The "Unexpected EOF in NSPR" Error

```
NSPRError: (PR_END_OF_FILE_ERROR) Encountered end of file.
INFO: Unexpected EOF
```

**This error occurs during TLS handshake, NOT during password authentication.**

#### What It Means

The error `PR_END_OF_FILE_ERROR` from NSS/NSPR indicates that:

1. A TCP connection was established
2. TLS handshake was initiated
3. The connection closed unexpectedly during the handshake
4. No proper SSL/TLS closure occurred

#### Where It Occurs

Found in Sigul source code:
- `sigul/src/client.py:1966` - Client-side error handling
- `sigul/src/utils.py:1113` - Utility error logging
- `sigul/src/bridge.py:1441` - Bridge connection handling

#### Common Root Causes

1. **Certificate validation failures**
   - Wrong certificate nicknames
   - Missing CA certificates
   - Expired certificates
   - Certificate/hostname mismatches

2. **NSS database issues**
   - Incorrect NSS password
   - Corrupted database
   - Wrong permissions

3. **Network/timing issues**
   - Service not fully initialized
   - Race conditions on startup
   - Firewall/network policy problems

4. **Configuration mismatches**
   - Certificate nicknames don't match config
   - Wrong NSS directory paths
   - TLS version mismatches

---

## Quick Start

### 1. Deploy with Debugging Enabled

```bash
# Clean deployment with auto-testing
./scripts/debug-deploy-stack.sh --clean --auto-test

# Or deploy with trace logging
./scripts/debug-deploy-stack.sh --trace
```

### 2. Run Comprehensive Diagnostics

```bash
# Run all diagnostic tests
./scripts/debug-tls-stack.sh --all --verbose

# Or run specific tests
./scripts/debug-tls-stack.sh --certs      # Certificate validation
./scripts/debug-tls-stack.sh --connectivity # Network tests
./scripts/debug-tls-stack.sh --tls        # TLS handshakes
./scripts/debug-tls-stack.sh --nss        # NSS database access
```

### 3. Run Isolation Tests

```bash
# Test all components in isolation
./scripts/test-nss-isolation.sh --verbose

# Test specific component
./scripts/test-nss-isolation.sh --container bridge
```

### 4. Check Results

The scripts will:
- ✅ Identify passing components
- ❌ Highlight failing operations
- 📋 Generate detailed diagnostic reports
- 💡 Suggest next steps

---

## Debugging Tools

### Tool 1: `debug-deploy-stack.sh`

**Purpose:** Deploy Sigul stack with enhanced debugging capabilities

**Usage:**
```bash
./scripts/debug-deploy-stack.sh [OPTIONS]
```

**Options:**
- `--clean` - Remove all volumes before deployment
- `--keep` - Keep containers running for debugging (default)
- `--auto-test` - Run TLS diagnostics after deployment
- `--trace` - Enable NSS/NSPR trace logging

**When to Use:**
- Starting fresh debugging session
- After making configuration changes
- When containers won't start properly

### Tool 2: `debug-tls-stack.sh`

**Purpose:** Comprehensive TLS diagnostics on running stack

**Usage:**
```bash
./scripts/debug-tls-stack.sh [OPTIONS]
```

**Options:**
- `--all` - Run all diagnostic tests (default)
- `--certs` - Certificate validation only
- `--connectivity` - Network tests only
- `--tls` - TLS handshake tests only
- `--nss` - NSS database tests only
- `--full-trace` - Enable verbose NSS/NSPR tracing
- `--verbose` - Detailed output

**When to Use:**
- Stack is deployed but not working
- Investigating specific TLS failures
- Validating fixes

### Tool 3: `test-nss-isolation.sh`

**Purpose:** Test NSS/NSPR operations in isolation, layer by layer

**Usage:**
```bash
./scripts/test-nss-isolation.sh [OPTIONS]
```

**Options:**
- `--container <name>` - Test specific container (bridge/server/client)
- `--verbose` - Detailed output

**Tests Performed:**
1. NSS database access
2. Password authentication
3. Certificate presence and validity
4. Private key access
5. Python NSS module import
6. DNS resolution
7. TCP connectivity
8. TLS handshakes (OpenSSL and NSS)

**When to Use:**
- Narrowing down exact failure point
- Testing after certificate regeneration
- Validating individual components

---

## Systematic Debugging Approach

### Step 1: Verify Container Status

```bash
# Check all containers are running
docker ps --filter "name=sigul"

# Check container logs
docker logs sigul-bridge
docker logs sigul-server
```

**Expected:** Containers running with "Up" status, no obvious errors in logs.

**If Failed:**
- Container exits immediately → Check entrypoint script and initialization
- Container restarts repeatedly → Check configuration files and passwords
- Container stuck → Check startup dependencies and health checks

### Step 2: Validate NSS Databases

```bash
# Run NSS-specific tests
./scripts/debug-tls-stack.sh --nss --verbose
```

**Tests:**
- ✅ Database files exist (cert9.db, key4.db)
- ✅ Databases can be opened and read
- ✅ Password authentication works
- ✅ Certificates are present

**If Failed:**
- Database not found → Check volume mounts and initialization
- Cannot read database → Check file permissions (should be readable by sigul user)
- Password fails → Verify NSS_PASSWORD in test-artifacts/nss-password
- Certificates missing → Re-run certificate generation

### Step 3: Verify Certificates

```bash
# Run certificate tests
./scripts/debug-tls-stack.sh --certs --verbose
```

**Checks:**
- ✅ CA certificate present in all databases
- ✅ Component certificates present (bridge-cert, server-cert, client-cert)
- ✅ Private keys match certificates
- ✅ Certificates not expired
- ✅ Certificate nicknames match configuration
- ✅ **CRITICAL:** CA private key NOT on client (security check)

**If Failed:**
- Certificate not found → Check nickname spelling in configs
- Certificate expired → Regenerate certificates (validity period in cert generation)
- Wrong nickname → Update config file or regenerate with correct nickname
- CA private key on client → **SECURITY ISSUE** - regenerate client database

### Step 4: Test Network Connectivity

```bash
# Run connectivity tests
./scripts/debug-tls-stack.sh --connectivity --verbose
```

**Tests:**
- ✅ DNS resolution works (e.g., sigul-bridge.example.org)
- ✅ TCP connection succeeds (ports 44333, 44334)
- ✅ Services are listening on correct ports
- ✅ Containers can reach each other

**If Failed:**
- DNS fails → Check Docker network and /etc/hosts
- TCP fails → Check container networking and port exposure
- Port not listening → Service not started or crashed
- Cannot reach → Network isolation or firewall issue

### Step 5: Test TLS Handshakes

```bash
# Run TLS tests
./scripts/debug-tls-stack.sh --tls --verbose
```

**Tests:**
- ✅ OpenSSL can complete handshake
- ✅ NSS tstclnt can complete handshake
- ✅ Certificate verification passes
- ✅ Trust chain is valid

**If Failed:**
- OpenSSL works but NSS fails → NSS-specific issue (database, password, or nicknames)
- Both fail → Certificate validation problem (trust chain, expiration, hostname)
- Connection made but verification fails → CA certificate not trusted
- Handshake never starts → TCP/network issue (see Step 4)

### Step 6: Isolation Testing

```bash
# Test components in isolation
./scripts/test-nss-isolation.sh --verbose
```

This performs progressive testing:
1. Database access (most basic)
2. Certificate operations
3. Python module imports
4. Network operations
5. TLS operations (most complex)

**Analysis:**
- Find the FIRST failing test
- That's where to focus debugging efforts
- Tests after the first failure will also fail (dependent operations)

### Step 7: Enable Full Trace Logging

```bash
# Run with full NSS/NSPR trace
./scripts/debug-tls-stack.sh --full-trace
```

**Warning:** This produces VERY verbose output.

**Analysis:**
- Look for SSL/TLS negotiation messages
- Check for certificate validation errors
- Identify exact point of failure in handshake
- Review error codes from NSS/NSPR

---

## Common Issues and Solutions

### Issue 1: Certificate Nickname Mismatch

**Symptoms:**
- `Certificate 'XXX' is not available` error
- NSS database query fails for specific nickname

**Diagnosis:**
```bash
# List all certificates in database
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul

# Check what's configured
docker exec sigul-bridge grep cert-nickname /etc/sigul/bridge.conf
```

**Solution:**
```bash
# Option A: Fix config to match database
docker exec sigul-bridge vi /etc/sigul/bridge.conf
# Change cert-nickname to match actual certificate name

# Option B: Regenerate certificates with correct nicknames
# (Requires redeploying infrastructure)
```

### Issue 2: NSS Password Incorrect

**Symptoms:**
- `SEC_ERROR_BAD_PASSWORD` error
- Cannot access private keys
- Authentication fails during NSS init

**Diagnosis:**
```bash
# Check stored password
cat test-artifacts/nss-password

# Test password manually
docker exec sigul-bridge sh -c \
  "echo 'PASSWORD_HERE' | certutil -K -d sql:/etc/pki/sigul -f /dev/stdin"
```

**Solution:**
```bash
# Regenerate with consistent password
./scripts/debug-deploy-stack.sh --clean

# Or update password in configuration
# (Must match password used during NSS database creation)
```

### Issue 3: CA Certificate Not Trusted

**Symptoms:**
- OpenSSL shows "Verify return code: 20 (unable to get local issuer certificate)"
- Certificate chain validation fails

**Diagnosis:**
```bash
# Check CA certificate presence
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul -n sigul-ca

# Check trust flags (should have 'C' for CA)
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul | grep sigul-ca
```

**Solution:**
```bash
# Re-import CA certificate with correct trust
docker exec sigul-bridge certutil -A \
  -d sql:/etc/pki/sigul \
  -n sigul-ca \
  -t "CT,C,C" \
  -i /path/to/ca-cert.pem
```

### Issue 4: Race Condition on Startup

**Symptoms:**
- First connection fails, subsequent ones succeed
- Intermittent "Unexpected EOF" errors
- Works sometimes, fails other times

**Diagnosis:**
```bash
# Check how long containers have been running
docker ps --filter "name=sigul" --format "{{.Names}}: {{.Status}}"

# Check if processes are fully started
docker exec sigul-bridge ps aux | grep sigul
docker exec sigul-server ps aux | grep sigul
```

**Solution:**
```bash
# Add longer wait times in deployment script
# Or implement proper health checks

# Manual wait
sleep 30

# Then retry operation
```

### Issue 5: Certificate Expired

**Symptoms:**
- `SEC_ERROR_EXPIRED_CERTIFICATE` error
- TLS handshake fails with expiration message

**Diagnosis:**
```bash
# Check certificate expiration
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul -n sigul-bridge-cert \
  | grep "Not After"
```

**Solution:**
```bash
# Regenerate all certificates
# This requires full redeployment
./scripts/debug-deploy-stack.sh --clean
```

### Issue 6: Wrong Hostname in Certificate

**Symptoms:**
- `SSL_ERROR_BAD_CERT_DOMAIN` error
- Certificate subject doesn't match hostname

**Diagnosis:**
```bash
# Check certificate subject
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul -n sigul-bridge-cert

# Check configured hostname
docker exec sigul-bridge grep hostname /etc/sigul/bridge.conf
```

**Solution:**
```bash
# Certificates must have correct Subject Alternative Names (SANs)
# Regenerate certificates with proper hostnames
# Or update /etc/hosts to match certificate names
```

---

## Advanced Debugging

### Enable NSS/NSPR Debug Logging

Add environment variables to containers:

```bash
# Bridge container
docker exec sigul-bridge sh -c '
export NSPR_LOG_MODULES="all:5"
export NSPR_LOG_FILE=/var/log/sigul/nss-trace.log
export NSS_DEBUG_PKCS11=1
'

# Restart Sigul service to apply
docker exec sigul-bridge pkill -HUP python3
```

### Manual TLS Testing

```bash
# Test with OpenSSL (no NSS)
docker exec sigul-bridge openssl s_client \
  -connect sigul-server.example.org:44333 \
  -showcerts \
  -debug \
  -state

# Test with NSS tstclnt
docker exec sigul-bridge tstclnt \
  -h sigul-server.example.org \
  -p 44333 \
  -d sql:/etc/pki/sigul \
  -v -V ssl3:tls1.2 \
  -o
```

### Python NSS Testing

Create test script in container:

```bash
docker exec -it sigul-bridge bash

cat > /tmp/test_nss.py << 'EOF'
#!/usr/bin/env python3
import nss.nss as nss
import nss.ssl as ssl

# Initialize NSS
nss.nss_init('/etc/pki/sigul')

# Get certificate
cert = nss.find_cert_from_nickname('sigul-bridge-cert')
print(f"Certificate: {cert.subject}")

# Test key access
key = nss.find_key_by_any_cert(cert)
print(f"Private key found: {key is not None}")
EOF

python3 /tmp/test_nss.py
```

### Capture Network Traffic

```bash
# Install tcpdump in container
docker exec sigul-bridge apk add tcpdump

# Capture TLS handshake
docker exec sigul-bridge tcpdump -i any -s 0 -w /tmp/capture.pcap \
  "port 44333 or port 44334"

# Copy out for analysis
docker cp sigul-bridge:/tmp/capture.pcap ./tls-capture.pcap

# Analyze with Wireshark
wireshark tls-capture.pcap
```

### Check Sigul Source Code

Key files for TLS debugging:

```
sigul/src/double_tls.py    - Double TLS implementation
sigul/src/utils.py          - NSS initialization and error handling
sigul/src/client.py         - Client-side connection code
sigul/src/bridge.py         - Bridge connection handling
sigul/src/server.py         - Server connection handling
```

Look for:
- `PR_END_OF_FILE_ERROR` - The EOF error
- `force_handshake()` - Where handshake happens
- `nss_init()` - NSS database initialization
- `find_cert_from_nickname()` - Certificate lookup

---

## Troubleshooting Checklist

### Before Starting Debugging

- [ ] Containers are running (`docker ps`)
- [ ] No obvious errors in logs (`docker logs`)
- [ ] Network exists (`docker network ls`)
- [ ] Volumes exist (`docker volume ls`)

### NSS Database Checks

- [ ] cert9.db files exist in correct locations
- [ ] NSS password is correct and accessible
- [ ] Databases are readable by sigul user (UID 1000)
- [ ] No database corruption errors

### Certificate Checks

- [ ] CA certificate present in all databases
- [ ] Component certificates present (bridge, server, client)
- [ ] Private keys match certificates
- [ ] Certificates not expired
- [ ] Certificate nicknames match configuration
- [ ] CA private key NOT on client (security)

### Network Checks

- [ ] DNS resolution works (*.example.org)
- [ ] TCP connectivity works (ports 44333, 44334)
- [ ] Services listening on correct ports
- [ ] No firewall/network policy blocking

### TLS Checks

- [ ] OpenSSL can complete handshake
- [ ] NSS tstclnt can complete handshake (if available)
- [ ] Certificate verification passes
- [ ] Trust chain is valid
- [ ] TLS version compatibility

### Configuration Checks

- [ ] Certificate nicknames in config match NSS database
- [ ] NSS directory paths are correct
- [ ] Hostnames in config match certificate SANs
- [ ] TLS min/max versions are compatible
- [ ] Passwords in config match NSS database passwords

### Timing Checks

- [ ] Containers have been running for >30 seconds
- [ ] Services have completed initialization
- [ ] No restarts during testing
- [ ] Database is fully initialized (server)

---

## Getting Help

### Collect Diagnostic Information

```bash
# Generate comprehensive report
./scripts/debug-tls-stack.sh --all --verbose > debug-report.txt

# Collect all logs
docker logs sigul-bridge > bridge.log 2>&1
docker logs sigul-server > server.log 2>&1

# Package everything
tar czf sigul-debug-$(date +%Y%m%d-%H%M%S).tar.gz \
  debug-report.txt \
  bridge.log \
  server.log \
  test-artifacts/
```

### Information to Provide

When asking for help, include:

1. **Error messages** - Exact text of errors
2. **Diagnostic report** - Output from debug-tls-stack.sh
3. **Container logs** - Last 50 lines from each container
4. **Environment** - Docker version, OS, architecture
5. **What you tried** - Steps already taken to resolve
6. **Reproducibility** - Does it always fail or intermittently?

### Related Documentation

- [Sigul Documentation](https://pagure.io/sigul)
- [NSS Documentation](https://developer.mozilla.org/en-US/docs/Mozilla/Projects/NSS)
- [Docker Networking Guide](https://docs.docker.com/network/)

---

## Summary

The "Unexpected EOF in NSPR" error is a **TLS handshake failure**, not a password authentication issue.

**Key Points:**

1. ✅ Use the debugging scripts in systematic order
2. ✅ Test components in isolation to find exact failure point
3. ✅ Verify certificates and NSS databases first
4. ✅ Check network connectivity before TLS
5. ✅ Enable trace logging for detailed analysis
6. ❌ Don't add `expect` - Sigul has proper batch mode
7. ❌ Don't guess - use diagnostic tools to identify root cause

**Quick Debug Flow:**

```
Deploy with debug → Run diagnostics → Run isolation tests → Identify failure → Apply fix → Verify
```

**Remember:** The error occurs during TLS handshake (transport layer), before any application-level password authentication happens.

---

*Last Updated: 2025-01-24*
*Version: 1.0*
