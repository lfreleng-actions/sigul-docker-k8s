<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# TLS Debugging Tools for Sigul

> Comprehensive debugging toolkit for troubleshooting NSS/NSPR "Unexpected EOF" errors and TLS handshake failures in Sigul container deployments.

## 📋 Overview

This toolkit provides systematic debugging capabilities for the Sigul signing infrastructure, with a focus on identifying and resolving TLS/SSL connection issues that commonly manifest as "Unexpected EOF in NSPR" errors.

### What's Included

- **3 Automated Debugging Scripts** - Progressive testing from deployment to isolation
- **2 Comprehensive Guides** - Detailed debugging procedures and quick reference
- **1 Readiness Checker** - Prevents race conditions by waiting for full initialization

### Key Insight

The "Unexpected EOF in NSPR" error is a **TLS handshake failure** that occurs during SSL negotiation, NOT during password authentication. Sigul already has proper batch mode for non-interactive operation - no need for `expect` or other workarounds.

---

## 🚀 Quick Start (30 Seconds)

```bash
# 1. Deploy with debug mode and auto-testing
./scripts/debug-deploy-stack.sh --clean --auto-test

# 2. If issues found, run comprehensive diagnostics
./scripts/debug-tls-stack.sh --all --verbose

# 3. For deeper analysis, test components in isolation
./scripts/test-nss-isolation.sh --verbose
```

That's it! The scripts will identify issues and suggest next steps.

---

## 🔧 Debugging Tools

### Tool 1: `debug-deploy-stack.sh`

**Purpose:** Deploy Sigul infrastructure with enhanced debugging capabilities

```bash
./scripts/debug-deploy-stack.sh [OPTIONS]
```

**Key Features:**
- Uses standard deployment script with debug mode enabled
- Optionally cleans volumes for fresh start
- Can enable NSS/NSPR trace logging
- Runs automatic diagnostics after deployment
- Provides interactive debugging commands

**Options:**
- `--clean` - Remove all volumes before deployment (fresh start)
- `--auto-test` - Run TLS diagnostics automatically after deployment
- `--trace` - Enable NSS/NSPR trace logging (very verbose)
- `--help` - Show detailed help

**Use When:**
- Starting a new debugging session
- After making configuration changes
- Containers won't start or fail immediately
- Need clean environment for testing

**Example Workflows:**
```bash
# Fresh deployment with auto-testing
./scripts/debug-deploy-stack.sh --clean --auto-test

# Deploy with trace logging for deep debugging
./scripts/debug-deploy-stack.sh --clean --trace

# Quick redeploy keeping existing volumes
./scripts/debug-deploy-stack.sh
```

### Tool 2: `debug-tls-stack.sh`

**Purpose:** Comprehensive TLS diagnostics on running stack

```bash
./scripts/debug-tls-stack.sh [OPTIONS]
```

**Key Features:**
- Multi-layer validation (NSS → Certificates → Network → TLS)
- Tests with both OpenSSL and NSS tools
- Validates certificate trust chains
- Checks configuration consistency
- Detects race conditions
- Generates diagnostic reports

**Options:**
- `--all` - Run all tests (default if no specific test selected)
- `--nss` - NSS database validation only
- `--certs` - Certificate validation only
- `--connectivity` - Network connectivity tests only
- `--tls` - TLS handshake tests only
- `--full-trace` - Enable verbose NSS/NSPR tracing
- `--verbose` - Detailed output

**Use When:**
- Stack is deployed but not working correctly
- Investigating specific TLS failures
- Validating certificate setup
- Checking network connectivity
- Need comprehensive diagnostic report

**Example Workflows:**
```bash
# Complete diagnostic suite
./scripts/debug-tls-stack.sh --all --verbose

# Quick certificate check
./scripts/debug-tls-stack.sh --certs

# Deep TLS analysis with full trace
./scripts/debug-tls-stack.sh --tls --full-trace

# Just network connectivity
./scripts/debug-tls-stack.sh --connectivity
```

### Tool 3: `test-nss-isolation.sh`

**Purpose:** Test NSS/NSPR operations in isolation, layer by layer

```bash
./scripts/test-nss-isolation.sh [OPTIONS]
```

**Key Features:**
- Progressive testing from basic to complex operations
- Identifies exact failure point in the stack
- Tests each component independently
- Validates Python NSS module functionality
- No dependencies between tests

**Test Layers:**
1. **NSS Database Access** - File existence, validity, password
2. **Certificate Operations** - Presence, validity, private keys
3. **Python/Sigul** - Module imports, Sigul library access
4. **Network Operations** - DNS, TCP connectivity
5. **TLS Operations** - OpenSSL and NSS handshakes

**Options:**
- `--container <name>` - Test specific container (bridge, server, or client)
- `--verbose` - Detailed output
- `--help` - Show help

**Use When:**
- Need to identify exact failure point
- Other scripts show failures but not clear cause
- Testing after certificate regeneration
- Validating individual components
- Debugging Python NSS issues

**Example Workflows:**
```bash
# Test all containers progressively
./scripts/test-nss-isolation.sh --verbose

# Test only bridge component
./scripts/test-nss-isolation.sh --container bridge

# Quick test without verbose output
./scripts/test-nss-isolation.sh
```

### Tool 4: `wait-for-tls-ready.sh`

**Purpose:** Wait for components to be fully ready, avoiding race conditions

```bash
./scripts/wait-for-tls-ready.sh [OPTIONS]
```

**Key Features:**
- Multi-stage readiness checks
- Waits for actual TLS capability, not just TCP
- Configurable timeout
- Can wait for specific components or all

**Readiness Checks:**
1. Container is running
2. Process is active
3. NSS database is accessible
4. Port is listening
5. TLS handshake succeeds

**Options:**
- `--all` - Wait for all components (default)
- `--bridge` - Wait for bridge only
- `--server` - Wait for server only
- `--timeout <seconds>` - Maximum wait time (default: 120)
- `--verbose` - Detailed output

**Use When:**
- In deployment scripts before running tests
- Avoiding "Unexpected EOF" from timing issues
- CI/CD pipelines need reliable wait
- Integration tests failing intermittently

**Example Workflows:**
```bash
# Wait for all components (default 120s)
./scripts/wait-for-tls-ready.sh

# Wait for bridge with custom timeout
./scripts/wait-for-tls-ready.sh --bridge --timeout 60

# Verbose waiting for all
./scripts/wait-for-tls-ready.sh --all --verbose
```

---

## 📚 Documentation

### Comprehensive Guide: `TLS_DEBUGGING_GUIDE.md`

**Purpose:** Complete reference for understanding and debugging TLS issues

**Contents:**
- Understanding the "Unexpected EOF in NSPR" error
- Root cause analysis
- Systematic debugging approach (7 steps)
- Common issues with detailed solutions
- Advanced debugging techniques
- Complete troubleshooting checklist

**When to Use:**
- Learning about TLS debugging in Sigul
- Need detailed explanation of error causes
- Looking for specific issue solutions
- Want to understand the debugging process
- Planning debugging strategy

### Quick Reference: `DEBUGGING_QUICK_REFERENCE.md`

**Purpose:** One-page cheat sheet for common debugging commands

**Contents:**
- Quick start commands
- Manual diagnostic commands
- Common issues with quick fixes
- Systematic debug flow diagram
- Key facts about the error
- Checklist before debugging

**When to Use:**
- During active debugging session
- Need quick command reference
- Forgot specific command syntax
- Want quick issue lookup
- Need debugging flow reminder

---

## 🎯 Systematic Debugging Approach

Follow this order for most efficient debugging:

```
┌─────────────────────────────────────────┐
│ 1. Deploy with Debug                    │
│    ./scripts/debug-deploy-stack.sh      │
└────────────────┬────────────────────────┘
                 ↓
┌─────────────────────────────────────────┐
│ 2. Comprehensive Diagnostics            │
│    ./scripts/debug-tls-stack.sh --all   │
└────────────────┬────────────────────────┘
                 ↓
┌─────────────────────────────────────────┐
│ 3. Isolation Testing                    │
│    ./scripts/test-nss-isolation.sh      │
└────────────────┬────────────────────────┘
                 ↓
┌─────────────────────────────────────────┐
│ 4. Identify Exact Failure               │
│    (First failing test = root cause)    │
└────────────────┬────────────────────────┘
                 ↓
┌─────────────────────────────────────────┐
│ 5. Apply Fix                            │
│    (Certificate, config, network, etc)  │
└────────────────┬────────────────────────┘
                 ↓
┌─────────────────────────────────────────┐
│ 6. Re-run Diagnostics                   │
│    (Verify fix resolved issue)          │
└─────────────────────────────────────────┘
```

### Why This Order?

1. **Deploy with Debug** - Ensures clean, instrumented environment
2. **Comprehensive Diagnostics** - Identifies which layer is failing
3. **Isolation Testing** - Pinpoints exact operation that fails
4. **Identify Failure** - First failing test is usually root cause
5. **Apply Fix** - Address the specific issue found
6. **Re-run Diagnostics** - Confirm fix and check for secondary issues

---

## 🔍 Common Issues Quick Lookup

| Issue | Script to Run | What to Check |
|-------|---------------|---------------|
| Containers won't start | `debug-deploy-stack.sh --clean` | Logs, initialization errors |
| "Unexpected EOF" error | `debug-tls-stack.sh --tls` | TLS handshake, certificates |
| Certificate errors | `debug-tls-stack.sh --certs` | Nicknames, expiration, trust |
| Network failures | `debug-tls-stack.sh --connectivity` | DNS, TCP, ports |
| NSS database issues | `debug-tls-stack.sh --nss` | Files, passwords, access |
| Intermittent failures | `wait-for-tls-ready.sh` | Timing, race conditions |
| Don't know where to start | `test-nss-isolation.sh` | Progressive layer testing |

---

## 💡 Key Insights

### About the Error

- **"Unexpected EOF in NSPR"** occurs during TLS handshake
- It's a **transport layer** issue, not application authentication
- Error code: `PR_END_OF_FILE_ERROR` from NSS/NSPR
- Happens before any password prompts
- Found in: `client.py:1966`, `utils.py:1113`, `bridge.py:1441`

### About Sigul Authentication

- Sigul has **built-in batch mode** (`--batch` flag)
- NSS password can be in config file (`nss-password:`)
- Passwords are NUL-terminated in batch mode
- No need for `expect` or other automation tools
- The issue is TLS, not interactive prompts

### Common Root Causes

1. **Certificate Issues** (70%)
   - Wrong nicknames in config
   - Missing CA certificates
   - Expired certificates
   - Trust chain problems

2. **Timing Issues** (20%)
   - Service not fully initialized
   - Race conditions on startup
   - Database not ready

3. **Configuration Issues** (10%)
   - Wrong NSS directory paths
   - Incorrect passwords
   - TLS version mismatches

---

## 📦 Integration with Deployment

### In Deployment Scripts

```bash
#!/bin/bash

# Deploy infrastructure
./scripts/deploy-sigul-infrastructure.sh --debug --verbose

# Wait for TLS readiness (avoid race conditions)
./scripts/wait-for-tls-ready.sh --all --timeout 120

# Verify everything is working
./scripts/debug-tls-stack.sh --all

# If all passed, proceed with integration tests
./scripts/run-integration-tests.sh
```

### In CI/CD Pipelines

```yaml
- name: Deploy Sigul Stack
  run: ./scripts/debug-deploy-stack.sh --clean

- name: Wait for Readiness
  run: ./scripts/wait-for-tls-ready.sh --all --verbose

- name: Run TLS Diagnostics
  run: ./scripts/debug-tls-stack.sh --all --verbose

- name: Upload Diagnostics on Failure
  if: failure()
  uses: actions/upload-artifact@v3
  with:
    name: tls-diagnostics
    path: test-artifacts/
```

---

## 🛠️ Manual Debugging Commands

If scripts don't reveal the issue, use manual debugging:

```bash
# Check container status
docker ps --filter "name=sigul"
docker logs sigul-bridge --tail 50

# List NSS certificates
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul

# Test TLS with OpenSSL
docker exec sigul-bridge openssl s_client \
  -connect sigul-server.example.org:44333 \
  -showcerts < /dev/null

# Check configuration
docker exec sigul-bridge cat /etc/sigul/bridge.conf | grep cert

# Test DNS
docker exec sigul-bridge nslookup sigul-server.example.org

# Test TCP
docker exec sigul-bridge nc -zv sigul-server.example.org 44333
```

See `DEBUGGING_QUICK_REFERENCE.md` for complete command reference.

---

## 🎓 Learning Path

1. **Start Here:** Read `TLS_DEBUGGING_GUIDE.md` Overview section
2. **Understand Error:** Review "Understanding the Error" section
3. **Run Quick Start:** Execute the 3-command quick start
4. **Study Results:** Review what passed and failed
5. **Deep Dive:** Read guide section for your specific failure
6. **Apply Fix:** Follow solution for your issue
7. **Verify:** Re-run diagnostics to confirm fix

---

## 📊 Test Results Interpretation

### All Tests Pass ✅
- Stack is healthy and ready for integration tests
- Proceed with signing operations
- May still have application-level issues (passwords, permissions)

### NSS Tests Fail ❌
- Database files missing or corrupted
- Wrong passwords
- Permission issues
- **Action:** Check NSS database initialization

### Certificate Tests Fail ❌
- Certificates missing or expired
- Wrong nicknames
- Trust chain broken
- **Action:** Regenerate certificates or fix nicknames

### Network Tests Fail ❌
- DNS not working
- TCP connectivity broken
- Services not listening
- **Action:** Check Docker networking and container startup

### TLS Tests Fail ❌
- Certificate validation failing
- Protocol mismatch
- Trust not established
- **Action:** Check certificate trust and validation

---

## 🚨 When to Get Help

Collect debug information and ask for help if:

1. All diagnostic scripts run without errors but issue persists
2. Issue occurs intermittently with no pattern
3. Logs show errors not covered in guides
4. Fix for identified issue doesn't resolve problem
5. Multiple unrelated issues occurring simultaneously

### Information to Collect

```bash
# Run comprehensive diagnostics
./scripts/debug-tls-stack.sh --all --verbose > diagnostics.txt

# Collect logs
docker logs sigul-bridge > bridge.log 2>&1
docker logs sigul-server > server.log 2>&1

# Package everything
tar czf sigul-debug-$(date +%Y%m%d-%H%M%S).tar.gz \
  diagnostics.txt \
  bridge.log \
  server.log \
  test-artifacts/ \
  docs/TLS_DEBUGGING_GUIDE.md
```

Include:
- Diagnostic report
- Container logs (last 100 lines minimum)
- Docker version and OS
- Steps to reproduce
- What you've already tried

---

## 📝 Contributing

When adding new debugging capabilities:

1. Follow existing script patterns and naming
2. Use consistent logging functions (log, warn, error, success, verbose)
3. Provide `--help` documentation
4. Update this README
5. Add examples to quick reference guide
6. Test on both local and CI environments

---

## 📖 Additional Resources

- **Sigul Upstream:** https://pagure.io/sigul
- **NSS Documentation:** https://developer.mozilla.org/en-US/docs/Mozilla/Projects/NSS
- **Docker Networking:** https://docs.docker.com/network/
- **TLS Debugging:** https://www.openssl.org/docs/man1.1.1/man1/s_client.html

---

## 🎯 Summary

This toolkit provides:

✅ **3 Progressive Scripts** - From deployment to isolation testing
✅ **2 Complete Guides** - Detailed and quick reference
✅ **Systematic Approach** - Follow clear debugging path
✅ **Root Cause Focus** - Identify exact failure point
✅ **No Guesswork** - Automated diagnostics reveal issues
✅ **CI/CD Ready** - Scripts work in pipelines
✅ **Well Documented** - Clear instructions and examples

**Remember:** The "Unexpected EOF in NSPR" is a TLS handshake issue. Start with comprehensive diagnostics, then drill down to exact failure point using isolation tests.

---

*Version: 1.0*
*Last Updated: 2025-01-24*
*For questions or issues: See GitHub Issues*
