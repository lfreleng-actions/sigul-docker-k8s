<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2025 The Linux Foundation -->

# Python-NSS to Python-NSS-NG Migration Guide

## Executive Summary

This document provides a comprehensive audit of how `python-nss` is currently used in the sigul-docker stack and outlines the migration path to `python-nss-ng`.

### Current State
- **python-nss**: Unmaintained legacy Python 2.x library (no commits in ~10 years)
- **Installation**: Built from source via `build-scripts/install-python-nss.sh`
- **Repository**: https://github.com/ModeSevenIndustrialSolutions/python-nss.git
- **Issues**: Poor error reporting, C binding issues, Python 3.x compatibility problems

### Target State
- **python-nss-ng**: Modernized, actively maintained Python 3.10+ library
- **Installation**: Available on PyPI as `python-nss-ng`
- **Repository**: https://github.com/ModeSevenIndustrialSolutions/python-nss-ng
- **Benefits**: Improved error handling, modern Python support, active development

## Current python-nss Usage Analysis

### 1. Installation Points

python-nss is currently installed in all three Sigul container images:

#### Dockerfile.client (Lines 38-46)
```dockerfile
# Copy and run python-nss installation script
COPY build-scripts/install-python-nss.sh /tmp/install-python-nss.sh
RUN chmod +x /tmp/install-python-nss.sh && \
    /tmp/install-python-nss.sh --verify && \
    rm /tmp/install-python-nss.sh
```

#### Dockerfile.bridge (Lines 45-53)
```dockerfile
# Copy and run python-nss installation script
COPY build-scripts/install-python-nss.sh /tmp/install-python-nss.sh
RUN chmod +x /tmp/install-python-nss.sh && \
    /tmp/install-python-nss.sh --verify && \
    rm /tmp/install-python-nss.sh
```

#### Dockerfile.server (Lines 45-53)
```dockerfile
# Copy and run python-nss installation script
COPY build-scripts/install-python-nss.sh /tmp/install-python-nss.sh
RUN chmod +x /tmp/install-python-nss.sh && \
    /tmp/install-python-nss.sh --verify && \
    rm /tmp/install-python-nss.sh
```

### 2. Build Script Analysis

**File**: `build-scripts/install-python-nss.sh`

**Current Behavior**:
1. Clones python-nss from GitHub fork
2. Builds from source using `python3 setup.py build`
3. Installs with `python3 setup.py install`
4. Verifies with `python3 -c "import nss"`
5. Tests basic functionality with `nss.nss_init_nodb()`

**Key Configuration**:
- Default repo: `https://github.com/ModeSevenIndustrialSolutions/python-nss.git`
- Default branch: `master`
- Can be overridden via environment variables:
  - `PYTHON_NSS_REPO`
  - `PYTHON_NSS_VERSION`

### 3. NSS Module Usage in Sigul

Based on production system analysis (from `samples/` directory), Sigul uses the following NSS modules:

#### Core NSS Modules Used
```python
import nss.error      # Error handling and error codes
import nss.io         # NSPR I/O primitives (sockets, networking)
import nss.nss        # Core NSS functionality (crypto, certificates)
import nss.ssl        # SSL/TLS functionality
```

#### Detailed API Usage

**From bridge.py**:
- `nss.ssl.SSLSocket(nss.io.PR_AF_INET)` - Create SSL sockets
- `nss.io.PR_SockOpt_Reuseaddr` - Socket options
- `nss.ssl.SSL_REQUEST_CERTIFICATE` - SSL options
- `nss.ssl.SSL_REQUIRE_CERTIFICATE` - SSL options
- `nss.nss.find_cert_from_nickname()` - Certificate lookup
- `nss.nss.find_key_by_any_cert()` - Private key lookup
- `nss.io.NetworkAddress()` - Network addressing
- `nss.nss.md5_digest()` - Hashing
- `nss.error.SEC_ERROR_EXPIRED_CERTIFICATE` - Error codes
- `nss.error.NSPRError` - Exception handling

**From client.py**:
- `nss.nss.CKM_SHA512_HMAC` - PKCS#11 mechanism
- `nss.nss.get_best_slot()` - Cryptographic token/slot selection
- `nss.io.PR_SHUTDOWN_SEND` - Socket shutdown
- `nss.nss.CKM_GENERIC_SECRET_KEY_GEN` - Key generation
- `nss.error.PR_CONNECT_RESET_ERROR` - Error codes
- `nss.error.PR_END_OF_FILE_ERROR` - Error codes

**From double_tls.py** (Double-TLS implementation):
- `nss.io.Socket.poll()` - I/O multiplexing
- `nss.io.PR_POLL_ERR`, `PR_POLL_HUP`, `PR_POLL_READ`, `PR_POLL_WRITE` - Poll flags
- `nss.error.PR_CONNECT_RESET_ERROR` - Connection errors
- `nss.error.PR_WOULD_BLOCK_ERROR` - Non-blocking I/O
- `nss.error.PR_NOT_CONNECTED_ERROR` - Connection state
- `nss.ssl.SSLSocket.import_tcp_socket()` - Import existing socket
- `nss.io.Socket.import_tcp_socket()` - Socket wrapping
- `nss.io.AddrInfo()` - Address resolution
- `nss.io.PR_SockOpt_Nonblocking` - Non-blocking mode
- `nss.ssl.SSL_ERROR_EXPIRED_CERT_ALERT` - Certificate expiration

**From server.py**:
- `nss.nss.generate_random()` - Random number generation
- `nss.nss.sha512_digest()` - SHA-512 hashing

**From utils.py**:
- `nss.nss.set_password_callback()` - Password callback for NSS database
- `nss.nss.nss_init()` - NSS initialization
- `nss.nss.get_internal_key_slot().authenticate()` - Slot authentication
- `nss.error.SEC_ERROR_BAD_DATABASE` - Database errors
- `nss.error.SEC_ERROR_BAD_PASSWORD` - Password errors
- `nss.ssl.set_domestic_policy()` - Cryptographic policy
- `nss.ssl.set_ssl_default_option()` - SSL defaults
- `nss.ssl.ssl_library_version_from_name()` - TLS version parsing
- `nss.ssl.ssl_version_range_set()` - TLS version range configuration

### 4. Patched Code Analysis

**File**: `patches/01-add-comprehensive-debugging.patch`

This patch adds extensive debugging to Sigul's NSS usage, including:
- NSS initialization debugging
- Certificate lookup debugging
- SSL connection debugging
- Error message enhancement

**Key NSS operations being debugged**:
```python
# NSS initialization
nss.nss.nss_init(config.nss_dir)
nss.nss.get_internal_key_slot().authenticate()
nss.nss.get_default_certdb()

# Certificate operations
nss.nss.find_cert_from_nickname(cert_nickname)

# SSL operations
socket_fd.connect(net_addr)
socket_fd.force_handshake()
socket_fd.get_peer_certificate()
```

## Migration Strategy

### Phase 1: Verify API Compatibility

**Action Items**:
1. ✅ Confirm python-nss-ng is published to PyPI
2. ⚠️ **CRITICAL**: Verify API compatibility between python-nss and python-nss-ng
   - All module names (`nss.error`, `nss.io`, `nss.nss`, `nss.ssl`)
   - All functions and methods used by Sigul
   - All constants and error codes
   - Exception handling behavior

**Expected Compatibility**:
Based on the python-nss-ng README, it appears to be a modernization effort maintaining the same API. However, this must be verified through:
- Documentation review
- Test imports
- Runtime testing

### Phase 2: Update Build Script

**File to Modify**: `build-scripts/install-python-nss.sh`

**Option A: Install from PyPI (RECOMMENDED)**

Replace the entire script with a simpler version:

```bash
#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Python-NSS-NG installation script
# Installs python-nss-ng from PyPI

set -euo pipefail

PYTHON_NSS_NG_VERSION="${PYTHON_NSS_NG_VERSION:-latest}"

log_info() {
    echo "[INFO] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

# Install python-nss-ng from PyPI
install_from_pypi() {
    log_info "Installing python-nss-ng from PyPI"
    
    if [[ "$PYTHON_NSS_NG_VERSION" == "latest" ]]; then
        pip3 install python-nss-ng
    else
        pip3 install "python-nss-ng==${PYTHON_NSS_NG_VERSION}"
    fi
    
    log_info "python-nss-ng installed successfully"
}

# Verify installation
verify_installation() {
    log_info "Verifying python-nss-ng installation"
    
    if ! python3 -c "import nss" >/dev/null 2>&1; then
        log_error "Python-NSS-NG verification failed: module cannot be imported"
        return 1
    fi
    
    # Test basic functionality
    if ! python3 -c "import nss.nss; nss.nss.nss_init_nodb()" >/dev/null 2>&1; then
        log_error "Python-NSS-NG verification failed: NSS initialization test failed"
        return 1
    fi
    
    local version
    version=$(python3 -c "import nss; print(nss.__version__)" 2>/dev/null || echo "unknown")
    log_info "Python-NSS-NG verification passed: version $version"
    
    return 0
}

main() {
    log_info "Starting python-nss-ng installation"
    
    install_from_pypi
    
    if [[ "${1:-}" == "--verify" ]]; then
        verify_installation
    fi
    
    log_info "python-nss-ng installation completed successfully"
}

main "$@"
```

**Option B: Install from GitHub (Development/Testing)**

If you need to install a specific commit or branch before PyPI publication:

```bash
# Modify the existing script to use python-nss-ng repository
PYTHON_NSS_REPO="${PYTHON_NSS_REPO:-https://github.com/ModeSevenIndustrialSolutions/python-nss-ng.git}"
PYTHON_NSS_VERSION="${PYTHON_NSS_VERSION:-main}"

# Install using pip from git
pip3 install "git+${PYTHON_NSS_REPO}@${PYTHON_NSS_VERSION}"
```

### Phase 3: Update Dockerfiles

**No changes required** if keeping the same script name (`install-python-nss.sh`).

Optionally, update comments to reflect the new package:

```dockerfile
# Copy and run python-nss-ng installation script
COPY build-scripts/install-python-nss.sh /tmp/install-python-nss.sh
RUN chmod +x /tmp/install-python-nss.sh && \
    /tmp/install-python-nss.sh --verify && \
    rm /tmp/install-python-nss.sh
```

### Phase 4: Update Documentation

**Files to Update**:

1. **REPOSITORY_MIGRATION.md**
   - Update references from `python-nss` to `python-nss-ng`
   - Update repository URL
   - Document PyPI installation option

2. **README.md**
   - Mention python-nss-ng in dependencies
   - Update troubleshooting section

3. **DEPLOYMENT_GUIDE.md** (if exists)
   - Update dependency information

4. **Docker Compose and Configuration Files**
   - No changes needed (transparent to runtime)

### Phase 5: Testing Strategy

#### 5.1 Unit Testing
```bash
# Test import
docker run --rm <image> python3 -c "import nss; print(nss.__version__)"

# Test submodules
docker run --rm <image> python3 -c "import nss.nss, nss.error, nss.io, nss.ssl"

# Test NSS initialization
docker run --rm <image> python3 -c "import nss.nss; nss.nss.nss_init_nodb()"
```

#### 5.2 Integration Testing
1. Build all three container images (client, bridge, server)
2. Run the full stack using `docker-compose.sigul.yml`
3. Test certificate generation and PKI initialization
4. Test client-bridge-server communication
5. Test signing operations

#### 5.3 Regression Testing
- Verify all existing functionality works
- Check error messages are properly propagated
- Validate TLS connection establishment
- Confirm certificate operations succeed

### Phase 6: Rollback Plan

**If migration fails**:

1. Revert `build-scripts/install-python-nss.sh` to original version
2. Rebuild container images
3. Document specific issues encountered
4. Open issues on python-nss-ng repository

**Backup Strategy**:
```bash
# Before migration, tag current working images
docker tag sigul-client:latest sigul-client:pre-nss-ng
docker tag sigul-bridge:latest sigul-bridge:pre-nss-ng
docker tag sigul-server:latest sigul-server:pre-nss-ng
```

## Implementation Checklist

### Pre-Migration
- [ ] Review python-nss-ng release notes and changelog
- [ ] Verify PyPI package is published (check https://pypi.org/project/python-nss-ng/)
- [ ] Review API documentation for breaking changes
- [ ] Backup current working container images
- [ ] Document current python-nss version in use

### Migration
- [ ] Update `build-scripts/install-python-nss.sh` for PyPI installation
- [ ] Update documentation references
- [ ] Rebuild client container image
- [ ] Test client image independently
- [ ] Rebuild bridge container image
- [ ] Test bridge image independently
- [ ] Rebuild server container image
- [ ] Test server image independently

### Testing
- [ ] Run unit tests (module imports and basic functions)
- [ ] Run PKI initialization tests
- [ ] Run client-bridge connection tests
- [ ] Run bridge-server connection tests
- [ ] Run end-to-end signing tests
- [ ] Verify error messages are informative
- [ ] Test certificate operations
- [ ] Test TLS version negotiation

### Post-Migration
- [ ] Update CI/CD pipelines if needed
- [ ] Update production deployment documentation
- [ ] Monitor logs for NSS-related errors
- [ ] Document any behavior changes
- [ ] Update troubleshooting guides

## Expected Benefits

### 1. Improved Error Reporting
python-nss-ng passes error messages from NSS/NSPR back to Python, making debugging significantly easier.

**Before (python-nss)**:
```
Generic Python exception with minimal context
```

**After (python-nss-ng)**:
```
nss.error.NSPRError: SEC_ERROR_BAD_DATABASE: The certificate/key database is in an old, unsupported format.
```

### 2. Python 3 Compatibility
- Native Python 3.10+ support
- Modern build system (setuptools with pyproject.toml)
- No legacy Python 2.x code paths

### 3. Active Maintenance
- Recent NSS 3.117+ compatibility fixes
- Modern development practices
- Active issue tracking and resolution

### 4. Better Build System
- 40-80% faster builds with parallel compilation
- Proper dependency management
- Standard Python packaging (PEP 517, PEP 518, PEP 621)

## Potential Issues and Mitigations

### Issue 1: API Incompatibility
**Risk**: Medium  
**Impact**: High  
**Mitigation**: 
- Thorough testing before production deployment
- Keep python-nss as fallback option
- Document any API differences discovered

### Issue 2: Different Error Behavior
**Risk**: Low  
**Impact**: Medium  
**Mitigation**:
- Review error handling code in Sigul patches
- Test all error conditions
- Update exception handling if needed

### Issue 3: Performance Differences
**Risk**: Low  
**Impact**: Low  
**Mitigation**:
- Benchmark signing operations
- Monitor production performance metrics
- Document any performance changes

### Issue 4: Missing Functionality
**Risk**: Low  
**Impact**: High  
**Mitigation**:
- Verify all Sigul-used APIs are present
- Test with comprehensive test suite
- Report missing APIs to python-nss-ng project

## PyPI Installation

### Recommended Approach

Once `python-nss-ng` is published to PyPI, the recommended installation method is:

```dockerfile
# In Dockerfiles, replace source build with pip install
RUN pip3 install python-nss-ng
```

Or with version pinning for production stability:

```dockerfile
# Pin to specific version
RUN pip3 install python-nss-ng==0.1.0
```

### Advantages of PyPI Installation

1. **Simplicity**: No need to clone, build from source
2. **Speed**: Pre-built wheels for faster installation
3. **Reliability**: Checksummed packages with integrity verification
4. **Versioning**: Easy to pin and upgrade versions
5. **Standard Practice**: Aligns with Python ecosystem norms

### Verification

After installation, verify with:

```bash
pip3 show python-nss-ng
python3 -c "import nss; print(f'NSS version: {nss.__version__}')"
```

## Frequently Asked Questions

### Q: Will this break existing Sigul deployments?
A: No, if the API is compatible (which we expect). The module is still imported as `import nss`, so Sigul code doesn't need changes.

### Q: Can we test python-nss-ng before full migration?
A: Yes, build a test container with python-nss-ng and run the integration test suite.

### Q: What if python-nss-ng has bugs?
A: We can revert to python-nss easily since we're only changing the build script. Keep backup images.

### Q: Do we need to update Sigul source code?
A: No, if the API is fully compatible. We only update the installation method.

### Q: Should we install from PyPI or GitHub?
A: PyPI is recommended for production. Use GitHub only for testing unreleased features or fixes.

### Q: What version of python-nss-ng should we use?
A: Start with the latest stable release from PyPI. Test thoroughly before production deployment.

## References

- **python-nss-ng Repository**: https://github.com/ModeSevenIndustrialSolutions/python-nss-ng
- **python-nss-ng Actions**: https://github.com/ModeSevenIndustrialSolutions/python-nss-ng/actions/runs/19618298661
- **Original python-nss**: https://github.com/tiran/python-nss
- **Sigul Repository**: https://github.com/ModeSevenIndustrialSolutions/sigul
- **NSS Documentation**: https://developer.mozilla.org/en-US/docs/Mozilla/Projects/NSS
- **NSPR Documentation**: https://developer.mozilla.org/en-US/docs/Mozilla/Projects/NSPR

## Conclusion

Migrating from python-nss to python-nss-ng is a straightforward process that primarily involves updating the installation method. The expected benefits include better error reporting, modern Python 3 support, and active maintenance. The migration can be tested incrementally and rolled back easily if issues arise.

**Recommended Next Steps**:
1. Confirm python-nss-ng is published to PyPI
2. Create a test branch with the updated installation script
3. Build and test all three container images
4. Run comprehensive integration tests
5. Deploy to staging environment
6. Monitor for issues before production rollout