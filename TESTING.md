<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Testing Guide

**Last Updated:** 2025-11-24
**Status:** ✅ Production Ready

---

## Overview

This document describes the complete testing infrastructure for Sigul,
ensuring **identical test execution** in both GitHub Actions CI and local
development environments.

### Key Principle

> **What works locally WILL work in CI.** No environment drift, no surprises.

---

## Table of Contents

1. [Test Scripts](#test-scripts)
2. [Local Testing](#local-testing)
3. [CI Testing](#ci-testing)
4. [Configuration](#configuration)
5. [Troubleshooting](#troubleshooting)
6. [Test Coverage](#test-coverage)

---

## Test Scripts

The `scripts/` directory contains all test scripts.

### Primary Test Suite

#### `scripts/client-tests.sh`

Core test suite with 10 comprehensive tests:

- Basic authentication
- Password validation (correct & incorrect)
- Key listing
- Connection stability
- Double-TLS verification
- Certificate authentication
- User operations
- Batch mode testing
- Performance checks

**Usage:**

```bash
./scripts/client-tests.sh [OPTIONS]

Options:
  --verbose              Enable verbose output
  --network NAME         Docker network name (auto-detected)
  --client-image IMAGE   Client image name (auto-detected)
  --admin-password PASS  Admin password (from test-artifacts)
  --help                 Show help message
```

#### `scripts/run-client-tests.sh`

Unified wrapper that auto-detects the environment (CI vs local) and runs
client-tests.sh with appropriate configuration.

**Usage:**

```bash
./scripts/run-client-tests.sh [OPTIONS]

Options:
  --verbose           Enable verbose output
  --network NAME      Override auto-detected network
  --client-image IMG  Override auto-detected image
  --help              Show help message
```

#### `scripts/test-client-basic.sh`

Standalone basic test suite that runs independently for quick validation.

**Usage:**

```bash
./scripts/test-client-basic.sh
```

### Integration Tests

#### `scripts/run-integration-tests.sh`

Full integration test suite that includes:

- Infrastructure deployment
- Key generation
- Signing operations
- Signature verification
- Client tests (via run-client-tests.sh)

---

## Local Testing

### Prerequisites

1. **Running Stack**

   ```bash
   docker compose -f docker-compose.sigul.yml up -d
   ```

2. **Healthy Containers**

   ```bash
   docker compose -f docker-compose.sigul.yml ps
   # Wait for bridge and server to show "healthy"
   ```

3. **Synchronized Password** (if you restarted the stack)

   ```bash
   # Get current server password
   CURRENT_PASSWORD=$(docker exec sigul-server env | \
     grep SIGUL_ADMIN_PASSWORD | cut -d= -f2)

   # Update test artifacts
   echo "$CURRENT_PASSWORD" > test-artifacts/admin-password
   ```

### Running Tests

#### Quick Start (Recommended)

```bash
# Auto-detect everything
./scripts/run-client-tests.sh --verbose
```

#### With Explicit Configuration

```bash
./scripts/run-client-tests.sh \
    --verbose \
    --admin-password "auto_generated_ephemeral" \
    --network "sigul-docker_sigul-network" \
    --client-image "sigul-docker-sigul-client-test:latest"
```

#### Direct Test Script

```bash
./scripts/client-tests.sh \
    --verbose \
    --network "sigul-docker_sigul-network" \
    --client-image "sigul-docker-sigul-client-test:latest" \
    --admin-password "auto_generated_ephemeral"
```

#### Standalone Basic Tests

```bash
./scripts/test-client-basic.sh
```

### Expected Output

```text
╔═══════════════════════════════════════════════════════════╗
║          SIGUL CLIENT TEST SUITE                          ║
╚═══════════════════════════════════════════════════════════╝

[INFO] Running test suite with 10 tests...

═══════════════════════════════════════════════════════════
TEST 1: Basic Authentication - List Users
═══════════════════════════════════════════════════════════
✅ PASS: Can authenticate and list users

[... 8 more tests ...]

═══════════════════════════════════════════════════════════
TEST 10: Double-TLS Communication Verification
═══════════════════════════════════════════════════════════
✅ PASS: Double-TLS communication working properly

╔═══════════════════════════════════════════════════════════╗
║                     TEST SUMMARY                          ║
╚═══════════════════════════════════════════════════════════╝

Total Tests:  10
Passed:       10
Failed:       0
Skipped:      0
Duration:     7s
Success Rate: 100%

╔═══════════════════════════════════════════════════════════╗
║              🎉 ALL TESTS PASSED! 🎉                      ║
╚═══════════════════════════════════════════════════════════╝
```

---

## CI Testing

### GitHub Actions Integration

The CI workflow integrates the client test suite at
`.github/workflows/build-test.yaml` in the `functional-tests` job.

### Workflow Steps

1. **Build Containers** - Build client, server, and bridge images
2. **Deploy Stack** - Deploy Sigul infrastructure with ephemeral passwords
3. **Run Integration Tests** - Execute signing operations and validation
4. **Run Client Tests** - Execute comprehensive 10-test suite
   (same as local)
5. **Upload Artifacts** - Save test results and logs
6. **Cleanup** - Remove containers, networks, and volumes

### Client Test Step

```yaml
- name: 'Run comprehensive client tests (10 tests)'
  shell: bash
  env:
    SIGUL_CLIENT_IMAGE: >-
      client-${{ steps.runner-arch.outputs.platform-id }}-image:test
    CI: 'true'
  run: |
    echo '🧪 Running comprehensive client test suite...'

    # Load admin password from deployment artifacts
    export SIGUL_ADMIN_PASSWORD=$(cat test-artifacts/admin-password)
    echo "✅ Loaded admin password from test-artifacts"

    # Detect network name
    export SIGUL_NETWORK_NAME=$(docker network ls \
      --filter "name=sigul" --format "{{.Name}}" | head -1)
    echo "✅ Detected network: ${SIGUL_NETWORK_NAME}"

    # Make scripts executable and run
    chmod +x scripts/run-client-tests.sh
    chmod +x scripts/client-tests.sh

    if ./scripts/run-client-tests.sh --verbose; then
      echo "✅ All 10 client tests passed in CI"
    else
      echo "❌ Client tests failed in CI"
      exit 1
    fi
```

### CI Environment Variables

| Variable | Source | Description |
|----------|--------|-------------|
| `SIGUL_CLIENT_IMAGE` | Workflow | Client image name |
| `SIGUL_ADMIN_PASSWORD` | test-artifacts | Admin password |
| `SIGUL_NETWORK_NAME` | Auto-detected | Docker network name |
| `CI` | GitHub Actions | Set to `"true"` in CI |

---

## Configuration

### Configuration Sources (Priority Order)

1. **Command-line arguments** (highest priority)

   ```bash
   --admin-password PASSWORD
   --network NETWORK_NAME
   --client-image IMAGE_NAME
   ```

2. **Environment variables**

   ```bash
   SIGUL_ADMIN_PASSWORD
   SIGUL_NETWORK_NAME
   SIGUL_CLIENT_IMAGE
   ```

3. **Test artifacts files**

   ```bash
   test-artifacts/admin-password
   test-artifacts/nss-password
   ```

4. **Auto-detection**
   - Network: `docker network ls --filter "name=sigul"`
   - Client image: `docker images --filter "reference=*sigul*client*"`

5. **Default values** (lowest priority)
   - Admin password: `auto_generated_ephemeral`

### Password Synchronization

**Critical:** The `test-artifacts/admin-password` file MUST match the
server's password.

- **CI:** Generated during deployment, written to
  `test-artifacts/admin-password`
- **Local:** Must match running server (update if stack restarted)

**Update Password File:**

```bash
docker exec sigul-server env | \
  grep SIGUL_ADMIN_PASSWORD | \
  cut -d= -f2 > test-artifacts/admin-password
```

**Verify Password Match:**

```bash
[ "$(docker exec sigul-server env | \
      grep SIGUL_ADMIN_PASSWORD | cut -d= -f2)" = \
  "$(cat test-artifacts/admin-password)" ] \
  && echo "✓ Passwords match" \
  || echo "✗ Passwords differ"
```

---

## Troubleshooting

### Test Failures Due to Password Mismatch

**Symptom:** Tests fail with "Authentication failed" or "Incorrect password"

**Diagnosis:**

```bash
# Check server password
docker exec sigul-server env | grep SIGUL_ADMIN_PASSWORD

# Check test-artifacts password
cat test-artifacts/admin-password

# Compare them
diff <(docker exec sigul-server env | \
       grep SIGUL_ADMIN_PASSWORD | cut -d= -f2) \
     <(cat test-artifacts/admin-password)
```

**Solution:**

```bash
# Update test-artifacts with current server password
docker exec sigul-server env | \
  grep SIGUL_ADMIN_PASSWORD | \
  cut -d= -f2 > test-artifacts/admin-password

# Or run tests with explicit password
./scripts/run-client-tests.sh \
    --admin-password "$(docker exec sigul-server env | \
                        grep SIGUL_ADMIN_PASSWORD | cut -d= -f2)"
```

### Tests Pass Locally But Fail in CI

**Root Cause:** Environment differences

**Diagnosis:**

1. Check CI logs for environment detection:

   ```text
   [VERBOSE] Auto-detected network: ...
   [VERBOSE] Auto-detected client image: ...
   [VERBOSE] Using admin password from ...
   ```

2. Verify password source in CI logs
3. Check image name matches CI convention

**Solutions:**

- Ensure deployment script writes correct password to
  `test-artifacts/admin-password`
- Verify the workflow sets `SIGUL_CLIENT_IMAGE` env var
- Check that docker-compose creates the network

### Auto-Detection Failures

**Symptom:** "Could not auto-detect network/image"

**Solution:**

```bash
# Find network
NETWORK=$(docker network ls --filter 'name=sigul' \
          --format '{{.Name}}' | head -1)

# Find client image
CLIENT_IMAGE=$(docker images --filter 'reference=*sigul*client*' \
               --format '{{.Repository}}:{{.Tag}}' | head -1)

# Run with explicit configuration
./scripts/run-client-tests.sh \
    --network "$NETWORK" \
    --client-image "$CLIENT_IMAGE" \
    --admin-password "$(cat test-artifacts/admin-password)"
```

### Container Not Running

**Symptom:** "sigul-server container is not running"

**Diagnosis:**

```bash
# Check container status
docker ps -a | grep sigul

# Check logs
docker logs sigul-server
docker logs sigul-bridge
```

**Solution:**

```bash
# Restart the stack
docker compose -f docker-compose.sigul.yml down
docker compose -f docker-compose.sigul.yml up -d

# Wait for healthy status
docker compose -f docker-compose.sigul.yml ps

# Update password file
docker exec sigul-server env | \
  grep SIGUL_ADMIN_PASSWORD | \
  cut -d= -f2 > test-artifacts/admin-password
```

---

## Test Coverage

### Client Test Suite (10 Tests)

1. **Basic Authentication - List Users**
   - Verifies admin can authenticate and list users
   - Tests basic client-bridge-server communication

2. **Authentication Failure with Wrong Password**
   - Verifies the system rejects incorrect passwords
   - Tests security controls

3. **List Keys Operation**
   - Tests key listing functionality
   - Verifies authenticated operations work

4. **Connection Stability**
   - Performs 5 consecutive operations
   - Verifies double-TLS connection remains stable

5. **Double-TLS Certificate Authentication**
   - Verifies NSS certificate database setup
   - Tests mutual TLS authentication

6. **User Information Query**
   - Tests user information retrieval
   - Verifies user management operations

7. **Batch Mode with NUL-terminated Password**
   - Tests batch mode operation (`-b` flag)
   - Verifies password handling in non-interactive mode

8. **Bridge Connection Latency**
   - Measures connection time to bridge
   - Verifies performance (<5 seconds)

9. **Client Command Availability**
   - Verifies sigul client command exists
   - Tests basic command execution

10. **Complete Double-TLS Communication Flow**
    - End-to-end test of full communication path
    - Verifies all components working together properly

### Integration Test Suite

The `scripts/run-integration-tests.sh` script includes these tests:

- GPG key generation
- Test file signing
- Signature verification
- RPM signing (if applicable)
- Certificate validation
- NSS database validation

---

## Maintenance

### When to Update test-artifacts/admin-password

Update the password file when:

- You restart the stack with new deployment
- You recreate the server container
- You explicitly change the admin password
- Tests start failing with authentication errors

### Adding New Tests

To add new tests to the suite:

1. **Edit `scripts/client-tests.sh`**
   - Create new test function: `test_<name>()`
   - Add test to `run_all_tests()` function
   - Follow existing pattern for pass/fail reporting

2. **Test locally**

   ```bash
   ./scripts/run-client-tests.sh --verbose
   ```

3. **Verify in CI**
   - Commit changes
   - Trigger workflow
   - Check CI logs for new test execution

4. **Update documentation**
   - Add test description to this file
   - Update test count in documentation

---

## Quick Reference

### Run Tests Locally

```bash
./scripts/run-client-tests.sh --verbose
```

### Run Tests in CI

```bash
CI=true \
SIGUL_CLIENT_IMAGE="client-linux-amd64-image:test" \
SIGUL_ADMIN_PASSWORD="$(cat test-artifacts/admin-password)" \
    ./scripts/run-client-tests.sh --verbose
```

### Update Password File

```bash
docker exec sigul-server env | \
  grep SIGUL_ADMIN_PASSWORD | \
  cut -d= -f2 > test-artifacts/admin-password
```

### Verify Configuration

```bash
./scripts/run-client-tests.sh --verbose 2>&1 | \
  grep -E "VERBOSE.*detected|VERBOSE.*Using|VERBOSE.*Loaded"
```

### Check Stack Health

```bash
docker compose -f docker-compose.sigul.yml ps
docker compose -f docker-compose.sigul.yml logs --tail=50
```

---

## Summary

✅ **Unified Scripts** - Same test code runs in CI and locally
✅ **Auto-Detection** - Minimal manual configuration required
✅ **Password Synchronization** - Single source of truth via test-artifacts
✅ **Comprehensive Coverage** - 10 client tests + integration tests
✅ **Clear Diagnostics** - Verbose logging for troubleshooting
✅ **Production Ready** - Tested and verified in both environments

**Result:** Complete CI/local parity. If tests pass locally, they will pass
in CI.

---

## See Also

- [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) - Stack deployment instructions
- [OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md) - Operational procedures
- [README.md](README.md) - Project overview
- [docs/historical/](docs/historical/) - Historical debugging documentation
