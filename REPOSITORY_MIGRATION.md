# Repository Migration Guide

**SPDX-License-Identifier: Apache-2.0**  
**SPDX-FileCopyrightText: 2025 The Linux Foundation**

## Overview

This document describes the migration from the original Fedora-hosted Sigul and python-nss repositories to Mode Seven Industrial Solutions forks.

## Migration Summary

### Previous Source Repositories

- **Sigul**: `https://pagure.io/sigul` (Fedora Pagure)
- **Python-NSS**: Installed via `python3-nss` RPM package from EPEL

### New Source Repositories

- **Sigul**: `https://github.com/ModeSevenIndustrialSolutions/sigul.git`
- **Python-NSS**: `https://github.com/ModeSevenIndustrialSolutions/python-nss.git`

## Changes Made

### 1. Build Scripts

#### `build-scripts/install-sigul.sh`
- **Before**: Downloaded tarball from `https://pagure.io/sigul/archive/v1.4/sigul-v1.4.tar.gz`
- **After**: Clones from GitHub fork using `git clone --depth 1 --branch v1.4`
- **Benefit**: Direct access to repository, easier to track changes and apply custom patches

#### `build-scripts/install-python-nss.sh` (NEW)
- **Purpose**: Build python-nss from source instead of using RPM package
- **Source**: Clones from `https://github.com/ModeSevenIndustrialSolutions/python-nss.git`
- **Benefit**: Full control over python-nss version and patches

### 2. Dockerfiles

All three Dockerfiles (`Dockerfile.client`, `Dockerfile.bridge`, `Dockerfile.server`) have been updated:

- **Removed**: `python3-nss` from DNF package installation
- **Added**: `nss-devel` and `nspr-devel` build dependencies
- **Added**: Build step to compile and install python-nss from source
- **Order**: python-nss is built before sigul (dependency requirement)

### 3. Documentation Updates

Updated all references from `pagure.io` to GitHub fork in:

- `patches/README.md`
- `DEBUGGING_IMPLEMENTATION_SUMMARY.md`
- `DEBUGGING_STRATEGY.md`
- `PKI_ARCHITECTURE.md`
- `PKI_REFACTOR_IMPLEMENTATION.md`
- `QUICK_START_PKI_V2.md`
- `docs/Sigul.txt`
- `scripts/sigul-init.sh`
- `scripts/test-docker-build.sh`
- `test-patch-application.sh`

## Rationale

### Why Fork?

1. **Maintenance Control**: Full control over the codebase and release cycle
2. **Custom Patches**: Easier to apply and maintain custom patches
3. **Dependency Management**: No reliance on external package repositories (EPEL)
4. **Architecture Support**: Consistent builds across x86_64 and ARM64
5. **Independence**: Not dependent on Fedora infrastructure availability

### Why Build from Source?

1. **Consistency**: Same build process across all architectures
2. **Transparency**: Full visibility into what's being built
3. **Customization**: Ability to apply patches and modifications as needed
4. **Version Control**: Explicit version pinning via git tags/branches

## Version Tracking

### Current Versions

- **Sigul**: v1.4 (git tag)
- **Python-NSS**: master branch (latest)

### Updating Versions

To update to a new version:

1. **For Sigul**:
   ```bash
   # Edit build-scripts/install-sigul.sh
   SIGUL_VERSION="1.5"  # Update version
   ```

2. **For Python-NSS**:
   ```bash
   # Edit build-scripts/install-python-nss.sh or set environment variable
   export PYTHON_NSS_VERSION="v1.0.2"  # Specific tag/branch
   ```

3. **Rebuild containers**:
   ```bash
   docker-compose build --no-cache
   ```

## Build Process

### Python-NSS Build Order

1. Install system dependencies (`nss-devel`, `nspr-devel`, `python3-devel`, `gcc`)
2. Clone python-nss from GitHub fork
3. Build using `python3 setup.py build`
4. Install using `python3 setup.py install`
5. Verify installation with `python3 -c "import nss"`

### Sigul Build Order

1. Install python-nss (prerequisite)
2. Clone sigul from GitHub fork
3. Apply patches (if present in `/tmp/patches/`)
4. Configure with `autoreconf -i` and `./configure`
5. Build with `make -j$(nproc)`
6. Install with `make install`
7. Verify installation (component-specific)

## Testing

### Verification Steps

After building containers:

1. **Verify Python-NSS**:
   ```bash
   docker run --rm <image> python3 -c "import nss; print(nss.__version__)"
   ```

2. **Verify Sigul Client**:
   ```bash
   docker run --rm <client-image> sigul --version
   ```

3. **Verify Sigul Server**:
   ```bash
   docker run --rm <server-image> which sigul_server
   ```

4. **Verify Sigul Bridge**:
   ```bash
   docker run --rm <bridge-image> which sigul_bridge
   ```

## Troubleshooting

### Build Failures

1. **NSS/NSPR headers not found**:
   - Ensure `nss-devel` and `nspr-devel` are installed
   - Check that EPEL repository is properly configured

2. **Git clone timeout**:
   - Verify network connectivity
   - Check GitHub repository access
   - Consider using SSH instead of HTTPS for authenticated access

3. **Python-NSS import errors**:
   - Verify NSS libraries are installed
   - Check that python3 is using the correct site-packages
   - Run `ldconfig` to update library cache

### Version Mismatches

If you encounter compatibility issues:

1. Check the python-nss version requirements in sigul source
2. Pin both repositories to compatible versions
3. Test locally before deploying

## Migration Checklist

- [x] Update `install-sigul.sh` to use GitHub fork
- [x] Create `install-python-nss.sh` build script
- [x] Update all three Dockerfiles
- [x] Update documentation references
- [x] Update test scripts
- [x] Verify builds on x86_64
- [x] Verify builds on ARM64
- [ ] Update CI/CD pipelines (if needed)
- [ ] Update deployment documentation
- [ ] Notify team of repository changes

## References

- **Sigul Fork**: https://github.com/ModeSevenIndustrialSolutions/sigul
- **Python-NSS Fork**: https://github.com/ModeSevenIndustrialSolutions/python-nss
- **Original Sigul**: https://pagure.io/sigul (archived reference)
- **Original Python-NSS**: https://github.com/tiran/python-nss (upstream)

## Support

For issues related to the forked repositories:

1. Check this repository's issues: https://github.com/modeseven-lfreleng-actions/sigul-docker/issues
2. For fork-specific issues, open issues in the respective fork repositories
3. For upstream issues, consider contributing fixes to the original projects

---

**Last Updated**: 2025-01-XX  
**Migration Completed**: 2025-01-XX