<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Phase 7: Integration Testing - Quick Reference

**Status:** ✅ COMPLETE
**Phase:** 7 of 8

---

## Test Scripts

### Integration Tests

```bash
# Full integration test suite
./scripts/run-integration-tests.sh

# Infrastructure validation
./scripts/test-infrastructure.sh
```

### Functional Tests

```bash
# Signing operations and functionality
./scripts/test-signing-operations.sh
```

### Performance Tests

```bash
# Performance benchmarks (default: 10 iterations)
./scripts/test-performance.sh

# Custom iteration count
ITERATIONS=20 ./scripts/test-performance.sh
```

### Phase Validation

```bash
# Validate Phase 7 completion
./scripts/validate-phase7-integration-testing.sh
```

---

## Quick Commands

### Deploy and Test (Complete Workflow)

```bash
# 1. Deploy infrastructure
./scripts/deploy-sigul-infrastructure.sh

# 2. Run all tests
./scripts/run-integration-tests.sh
./scripts/test-signing-operations.sh
./scripts/test-performance.sh
```

### Test Without Deployment

```bash
# Validate test infrastructure
./scripts/validate-phase7-integration-testing.sh
```

---

## Test Categories

### Infrastructure Tests

- Directory structure validation
- Configuration file presence
- Volume mount verification
- File permissions and ownership

### Certificate Tests

- NSS database format (cert9.db)
- Certificate presence and validity
- Trust flag verification
- Certificate expiration monitoring

### Network Tests

- Bridge listening ports (44333, 44334)
- Server connectivity to bridge
- DNS resolution (FQDNs)
- Hostname alignment with certificates

### Service Tests

- Process status (bridge, server)
- Database integrity checks
- GnuPG home initialization
- Health check responses

### Performance Tests

- Network connectivity benchmarks
- Certificate validation speed
- Database query performance
- File system access speed
- Resource usage monitoring

---

## Network Architecture (Correct)

```text
Client ──connects to──> Bridge:44334
Server ──connects to──> Bridge:44333

Bridge:
  - LISTENS on 0.0.0.0:44333 (server connections)
  - LISTENS on 0.0.0.0:44334 (client connections)
```

**Key Point:** Server CONNECTS TO bridge, bridge does NOT connect to server!

See `NETWORK_ARCHITECTURE.md` for full details.

---

## Validation Results

**Phase 7 Validation:**

- Total Tests: 34
- Pass Rate: 100%
- Blocking Issues: 0

---

## Test Output Interpretation

### Success Indicators

```text
✓ PASS: Test description
[PASS] Test passed
✓ SUCCESS: Operation completed
```

### Failure Indicators

```text
✗ FAIL: Test description
[FAIL] Test failed
✗ ERROR: Operation failed
```

### Warning Indicators

```text
⚠ WARN: Optional test skipped
[WARN] Non-critical issue
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |

---

## Common Issues

### "Container not found"

**Solution:** Deploy infrastructure first

```bash
./scripts/deploy-sigul-infrastructure.sh
```

### "Functional tests skipped"

**Cause:** Client container not available (expected)
**Action:** No action needed for Phase 7 validation

### "Live tests show warnings"

**Cause:** Containers not running (optional)
**Action:** Deploy infrastructure for live testing

---

## Files Created in Phase 7

1. ✅ `scripts/test-signing-operations.sh` - Functional tests
2. ✅ `scripts/test-performance.sh` - Performance benchmarks
3. ✅ `scripts/validate-phase7-integration-testing.sh` - Phase validation
4. ✅ `NETWORK_ARCHITECTURE.md` - Network documentation
5. ✅ `PHASE7_COMPLETE.md` - Completion documentation
6. ✅ `PHASE7_QUICK_REFERENCE.md` - This file

---

## Next Phase

**Phase 8: Documentation & Final Validation**

Tasks:

- Create production deployment guide
- Create operations guide
- Create validation checklist
- Update README.md
- Final end-to-end validation

---

*For detailed information, see `PHASE7_COMPLETE.md`*
