# Testing Checklist for CI Integration Test Fixes

**SPDX-License-Identifier:** Apache-2.0  
**SPDX-FileCopyrightText:** 2025 The Linux Foundation

## Overview

This checklist provides step-by-step verification procedures for the integration test fixes applied to resolve CI failures related to volume mounting and certificate import.

## Pre-Commit Verification

### Local Development Testing

- [ ] **Syntax Validation**
  ```bash
  # Verify bash script syntax
  bash -n scripts/run-integration-tests.sh
  bash -n scripts/validate-volumes.sh
  
  # Verify Python syntax
  python3 -m py_compile tests/integration/test_sigul_stack.py
  ```

- [ ] **Docker Compose Validation**
  ```bash
  # Validate compose file syntax
  docker compose -f docker-compose.sigul.yml config
  
  # List defined volumes
  docker compose -f docker-compose.sigul.yml config --volumes
  ```

- [ ] **Clean Environment Test**
  ```bash
  # Start fresh
  docker compose -f docker-compose.sigul.yml down -v
  docker compose -f docker-compose.sigul.yml up -d
  
  # Wait for health checks
  sleep 30
  
  # Run volume validation
  ./scripts/validate-volumes.sh --verbose
  ```

- [ ] **Integration Test Local Run**
  ```bash
  # Run integration tests locally
  ./scripts/run-integration-tests.sh --verbose
  
  # Verify exit code
  echo "Exit code: $?"
  ```

## Post-Commit Verification

### GitHub Actions Workflow Monitoring

- [ ] **Trigger CI Build**
  - Push commits to branch
  - Monitor workflow at: `https://github.com/{org}/{repo}/actions`
  - Wait for `functional-tests` job to start

- [ ] **Build Phase Checks**
  - [ ] All container images build successfully
  - [ ] No build warnings or errors
  - [ ] Image artifacts uploaded correctly

- [ ] **Stack Deployment Checks**
  - [ ] All containers start without errors
  - [ ] Health checks pass within timeout
  - [ ] No permission errors in logs

- [ ] **Volume Validation Checks**
  - [ ] Bridge NSS volume detected correctly
  - [ ] Volume contains cert9.db and key4.db files
  - [ ] Volume accessible to client container

- [ ] **Integration Test Execution**
  - [ ] Client container initialization succeeds
  - [ ] CA certificate import succeeds
  - [ ] All test methods pass
  - [ ] No NSS-related errors in output

## Detailed Test Verification

### Test 1: Volume Detection

**What to check:**
```bash
# In CI logs, look for:
[INFO] Using bridge NSS volume: sigul-docker_sigul_bridge_nss
```

**Success criteria:**
- Volume name contains `bridge_nss` (not `bridge_data`)
- No "Could not find bridge NSS volume" errors

**If failed:**
- Check volume naming in docker-compose.sigul.yml
- Verify volume creation in cert-init step
- Review volume ls output in CI logs

### Test 2: Client Container Initialization

**What to check:**
```bash
# In CI logs, look for:
[INFO] Starting persistent client container for integration tests...
[DEBUG] Using bridge NSS volume: sigul-docker_sigul_bridge_nss
[SUCCESS] Bridge NSS certificates are ready
[SUCCESS] Client container initialized successfully
```

**Success criteria:**
- Client container starts without errors
- Bridge NSS directory accessible at `/etc/pki/sigul/bridge-shared`
- CA certificate imported successfully
- Client certificate generated successfully

**If failed:**
- Check volume mount in docker run command
- Verify bridge NSS database exists: `docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge`
- Check client initialization logs for specific errors

### Test 3: NSS Database Paths

**What to check:**
```bash
# In test output, verify paths like:
certutil -L -d sql:/etc/pki/sigul/bridge
certutil -L -d sql:/etc/pki/sigul/server
certutil -L -d sql:/etc/pki/sigul/client
```

**Success criteria:**
- No references to `/var/sigul/nss/` paths
- All paths use `/etc/pki/sigul/{component}` format
- certutil commands succeed

**If failed:**
- Search codebase for remaining `/var/sigul` references
- Update any missed path references

### Test 4: Configuration File Paths

**What to check:**
```bash
# In test output, verify paths like:
cat /etc/sigul/bridge.conf
cat /etc/sigul/server.conf
sigul -c /etc/sigul/client.conf list-users
```

**Success criteria:**
- No references to `/var/sigul/config/` paths
- All config paths use `/etc/sigul/` format
- Configuration files accessible

**If failed:**
- Check for remaining legacy config path references
- Verify config volume mounts in docker-compose.sigul.yml

### Test 5: Python Integration Tests

**What to check:**
```bash
# In pytest output, look for:
tests/integration/test_sigul_stack.py::TestCertificates::test_nss_database_initialization PASSED
tests/integration/test_sigul_stack.py::TestCertificates::test_ca_certificate_sharing PASSED
tests/integration/test_sigul_stack.py::TestCommunication::test_client_configuration_generation PASSED
```

**Success criteria:**
- All 10 test methods pass
- No path-related assertion errors
- No volume mount errors

**If failed:**
- Review specific test failure output
- Check volume names match between compose file and tests
- Verify test paths are FHS-compliant

## Expected CI Output Patterns

### ✅ Successful Output

```
[INFO] Starting real Sigul infrastructure integration tests...
[INFO] Setting up test environment...
[SUCCESS] Test environment setup completed
[INFO] Waiting for bridge to be ready with NSS certificates...
[SUCCESS] Bridge NSS certificates are ready
[INFO] Starting persistent client container for integration tests...
[DEBUG] Using bridge NSS volume: sigul-docker_sigul_bridge_nss
[SUCCESS] Client container initialized successfully
[SUCCESS] Client certificate setup completed by initialization
...
[SUCCESS] === Real Infrastructure Integration Tests Passed ===
```

### ❌ Failure Output (Fixed Issues)

```
# This should NO LONGER appear:
[ERROR] Could not find bridge data volume
[ERROR] Bridge NSS database not accessible at /etc/pki/sigul/bridge-shared
[ERROR] Failed to initialize client container
```

## Rollback Procedure

If tests fail in CI after merge:

1. **Immediate Actions**
   ```bash
   # Revert commits
   git revert HEAD~3..HEAD
   git push origin main
   ```

2. **Investigation**
   - Download CI artifacts
   - Review container logs
   - Check volume inspection output
   - Run validation tool locally

3. **Fix and Retest**
   - Apply targeted fix
   - Test locally first
   - Submit new PR with fix
   - Do not merge until CI passes

## Local CI Simulation (Optional)

Using nektos/act to replicate CI environment:

```bash
# Install act (macOS)
brew install act

# Run functional tests locally
act -j functional-tests \
    --container-architecture linux/amd64 \
    --verbose

# With secrets file
act -j functional-tests \
    --secret-file .secrets \
    --container-architecture linux/amd64
```

## Documentation Verification

- [ ] **README.md** updated with correct paths (if referenced)
- [ ] **DEPLOYMENT_GUIDE.md** reflects FHS-compliant architecture
- [ ] **CLIENT_SETUP_DEBUG_ANALYSIS.md** created and reviewed
- [ ] **CI_INTEGRATION_TEST_FIXES.md** created and reviewed
- [ ] **INTEGRATION_TEST_RESOLUTION_SUMMARY.md** created and reviewed
- [ ] **TESTING_CHECKLIST.md** created (this file)

## Success Criteria Summary

All of the following must be true for successful verification:

1. ✅ No syntax errors in modified files
2. ✅ Docker Compose validates successfully
3. ✅ Local integration tests pass
4. ✅ CI workflow completes without errors
5. ✅ All volume validations pass
6. ✅ Client initialization succeeds in CI
7. ✅ All Python integration tests pass
8. ✅ No legacy path references remain in output
9. ✅ NSS databases accessible at correct paths
10. ✅ Certificate import succeeds

## Post-Merge Actions

After successful CI verification:

- [ ] Update project status board
- [ ] Close related GitHub issues
- [ ] Notify team of successful deployment
- [ ] Archive investigation documentation
- [ ] Update operational runbooks

## Troubleshooting Quick Reference

| Issue | Command | Expected Output |
|-------|---------|-----------------|
| Volume not found | `docker volume ls \| grep bridge_nss` | Shows volume name |
| Volume empty | `docker run --rm -v <vol>:/nss alpine ls /nss` | Shows cert9.db, key4.db |
| NSS DB inaccessible | `docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge` | Lists certificates |
| Client can't read volume | `docker exec client ls -la /etc/pki/sigul/bridge-shared/` | Shows certificate files |
| Wrong paths used | `grep -r "/var/sigul" tests/` | No matches found |

## Contacts

- **Primary Developer:** [Your Name]
- **CI/CD Owner:** [Team Lead]
- **Code Review:** [Reviewer Names]
- **Escalation:** [Manager/Tech Lead]

---

**Checklist Version:** 1.0  
**Last Updated:** 2025-11-16  
**Related Fixes:** Volume mounting, FHS compliance, certificate import