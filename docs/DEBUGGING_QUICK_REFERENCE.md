<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul TLS Debugging - Quick Reference Card

> **One-page reference for debugging NSS/NSPR "Unexpected EOF" errors**

---

## 🚀 Quick Start (3 Commands)

```bash
# 1. Deploy with debug mode
./scripts/debug-deploy-stack.sh --clean --auto-test

# 2. Run diagnostics
./scripts/debug-tls-stack.sh --all --verbose

# 3. Test in isolation
./scripts/test-nss-isolation.sh --verbose
```

---

## 🔧 Debugging Scripts

### Deploy Stack
```bash
./scripts/debug-deploy-stack.sh [OPTIONS]
  --clean         # Remove all volumes first
  --auto-test     # Run diagnostics after deploy
  --trace         # Enable NSS/NSPR trace logging
```

### TLS Diagnostics
```bash
./scripts/debug-tls-stack.sh [OPTIONS]
  --all           # Run all tests (default)
  --certs         # Certificate checks only
  --connectivity  # Network tests only
  --tls           # TLS handshake tests only
  --nss           # NSS database tests only
  --full-trace    # Enable verbose NSS tracing
  --verbose       # Detailed output
```

### Isolation Testing
```bash
./scripts/test-nss-isolation.sh [OPTIONS]
  --container <name>  # Test specific: bridge/server/client
  --verbose           # Detailed output
```

---

## 📋 Manual Diagnostic Commands

### Container Status
```bash
# Check running containers
docker ps --filter "name=sigul"

# View logs (last 50 lines)
docker logs sigul-bridge --tail 50
docker logs sigul-server --tail 50

# Follow logs live
docker logs -f sigul-bridge
```

### NSS Database
```bash
# List certificates
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul

# Check specific certificate
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul -n sigul-bridge-cert

# List private keys
docker exec sigul-bridge certutil -K -d sql:/etc/pki/sigul

# Test password (replace PASSWORD)
docker exec sigul-bridge sh -c \
  "echo 'PASSWORD' | certutil -K -d sql:/etc/pki/sigul -f /dev/stdin"
```

### Network Tests
```bash
# Test DNS
docker exec sigul-bridge nslookup sigul-server.example.org

# Test TCP connectivity
docker exec sigul-bridge nc -zv sigul-server.example.org 44333

# Check listening ports
docker exec sigul-bridge netstat -tlnp | grep 44334
docker exec sigul-server netstat -tlnp | grep 44333
```

### TLS Handshake Tests
```bash
# Test with OpenSSL
docker exec sigul-bridge openssl s_client \
  -connect sigul-server.example.org:44333 \
  -showcerts < /dev/null

# Test with NSS tstclnt (if available)
docker exec sigul-bridge tstclnt \
  -h sigul-server.example.org \
  -p 44333 \
  -d sql:/etc/pki/sigul \
  -v -o
```

### Configuration
```bash
# View config files
docker exec sigul-bridge cat /etc/sigul/bridge.conf
docker exec sigul-server cat /etc/sigul/server.conf

# Check certificate nicknames in config
docker exec sigul-bridge grep cert-nickname /etc/sigul/bridge.conf

# Check NSS directory in config
docker exec sigul-bridge grep nss-dir /etc/sigul/bridge.conf
```

---

## 🔍 Common Issues & Quick Fixes

### Issue: Certificate Nickname Mismatch
```bash
# Check what's in database
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul

# Check what's in config
docker exec sigul-bridge grep cert-nickname /etc/sigul/bridge.conf

# Fix: Update config or regenerate certs
```

### Issue: Wrong NSS Password
```bash
# Check stored password
cat test-artifacts/nss-password

# Test manually (replace PASSWORD)
docker exec sigul-bridge sh -c \
  "echo 'PASSWORD' | certutil -K -d sql:/etc/pki/sigul -f /dev/stdin"

# Fix: Redeploy with consistent password
./scripts/debug-deploy-stack.sh --clean
```

### Issue: CA Certificate Not Trusted
```bash
# Check CA cert exists
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul -n sigul-ca

# Check trust flags (should have 'C')
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul | grep sigul-ca

# Fix: Re-import with correct trust
docker exec sigul-bridge certutil -A \
  -d sql:/etc/pki/sigul \
  -n sigul-ca \
  -t "CT,C,C" \
  -i /path/to/ca-cert.pem
```

### Issue: Service Not Ready (Race Condition)
```bash
# Check container uptime
docker ps --filter "name=sigul" --format "{{.Names}}: {{.Status}}"

# Check processes running
docker exec sigul-bridge ps aux | grep sigul

# Fix: Wait longer before testing
sleep 30
```

### Issue: Certificate Expired
```bash
# Check expiration
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul -n sigul-bridge-cert \
  | grep "Not After"

# Fix: Regenerate certificates
./scripts/debug-deploy-stack.sh --clean
```

---

## 🎯 Systematic Debug Flow

```
┌──────────────────────────────────────────┐
│ 1. Container Status                      │
│    docker ps --filter "name=sigul"       │
└──────────────┬───────────────────────────┘
               ↓
┌──────────────────────────────────────────┐
│ 2. NSS Database Check                    │
│    ./scripts/debug-tls-stack.sh --nss    │
└──────────────┬───────────────────────────┘
               ↓
┌──────────────────────────────────────────┐
│ 3. Certificate Validation                │
│    ./scripts/debug-tls-stack.sh --certs  │
└──────────────┬───────────────────────────┘
               ↓
┌──────────────────────────────────────────┐
│ 4. Network Connectivity                  │
│    ./scripts/debug-tls-stack.sh --conn   │
└──────────────┬───────────────────────────┘
               ↓
┌──────────────────────────────────────────┐
│ 5. TLS Handshake                         │
│    ./scripts/debug-tls-stack.sh --tls    │
└──────────────┬───────────────────────────┘
               ↓
┌──────────────────────────────────────────┐
│ 6. Isolation Testing                     │
│    ./scripts/test-nss-isolation.sh       │
└──────────────┬───────────────────────────┘
               ↓
┌──────────────────────────────────────────┐
│ 7. Full Trace (if needed)                │
│    ./scripts/debug-tls-stack.sh --trace  │
└──────────────────────────────────────────┘
```

---

## 🔬 Advanced: Enable NSS Trace Logging

```bash
# In container, set environment variables
docker exec sigul-bridge sh -c '
export NSPR_LOG_MODULES="all:5"
export NSPR_LOG_FILE=/var/log/sigul/nss-trace.log
export NSS_DEBUG_PKCS11=1
'

# Restart service to apply
docker restart sigul-bridge

# View trace log
docker exec sigul-bridge cat /var/log/sigul/nss-trace.log
```

---

## 📦 Collect Debug Package

```bash
# Generate comprehensive diagnostics
./scripts/debug-tls-stack.sh --all --verbose > debug-report.txt

# Collect logs
docker logs sigul-bridge > bridge.log 2>&1
docker logs sigul-server > server.log 2>&1

# Package for sharing
tar czf sigul-debug-$(date +%Y%m%d-%H%M%S).tar.gz \
  debug-report.txt \
  bridge.log \
  server.log \
  test-artifacts/
```

---

## 🔑 Key Facts About "Unexpected EOF in NSPR"

| Fact | Description |
|------|-------------|
| **When it occurs** | During TLS handshake, NOT password auth |
| **Error code** | `PR_END_OF_FILE_ERROR` from NSS/NSPR |
| **Common causes** | Certificate validation, NSS password, timing |
| **Not the issue** | Interactive password prompts (Sigul has batch mode) |
| **Source locations** | `client.py:1966`, `utils.py:1113`, `bridge.py:1441` |

---

## ✅ Checklist Before Debugging

- [ ] Containers are running (`docker ps`)
- [ ] No obvious errors in logs
- [ ] Wait 30+ seconds after container start
- [ ] NSS password available (`test-artifacts/nss-password`)
- [ ] Network exists (`docker network ls | grep sigul`)

---

## 📚 Related Documentation

- Full Guide: `docs/TLS_DEBUGGING_GUIDE.md`
- Deployment: `scripts/deploy-sigul-infrastructure.sh --help`
- Integration Tests: `scripts/run-integration-tests.sh --help`

---

## 💡 Remember

1. **Test in order**: Database → Certificates → Network → TLS
2. **Use isolation tests**: Find the exact failure point
3. **Check configurations**: Certificate nicknames must match database
4. **Be patient**: Wait for services to fully initialize
5. **Don't add `expect`**: Sigul has built-in batch mode

---

*Quick Reference v1.0 - See TLS_DEBUGGING_GUIDE.md for detailed information*
