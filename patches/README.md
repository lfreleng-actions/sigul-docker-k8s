<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Patches

This directory contains patches that fix critical issues in upstream Sigul v1.4 to enable proper operation in containerized environments.

## Purpose

These patches are automatically applied during the Docker image build process to fix issues that prevent Sigul from working correctly in containers. The patches are minimal and focused on critical functionality only.

## Patches

### 01-fix-double-tls-handshake-timing.patch

**Status:** CRITICAL - Required for functionality
**Upstream Status:** Not yet submitted
**Affects:** Bridge component

**Problem:**
The upstream Sigul bridge accepts the server's TCP connection but delays the TLS handshake until a client connects. In containerized environments with variable connection timing, this causes the server-side TLS handshake to timeout, resulting in `PR_END_OF_FILE_ERROR` / "Unexpected EOF in NSPR" errors.

**Fix:**
Completes the server TLS handshake immediately after accepting the TCP connection, before waiting for client connections. This ensures stable double-TLS communication.

**Impact:**

- Without this patch: All Sigul operations fail with I/O errors
- With this patch: Stable, reliable double-TLS communication

**Code Changes:**

- Adds `server_sock.force_handshake()` immediately after server accept
- Adds server certificate validation
- Adds error handling for handshake failures

## How Patches Are Applied

The Docker build process automatically applies these patches:

1. `Dockerfile.{client,bridge,server}` copies this directory to `/tmp/patches/`
2. `build-scripts/install-sigul.sh` clones Sigul v1.4 from upstream (Pagure)
3. The script applies all `*.patch` files in alphanumeric order
4. Sigul is then built and installed with the fixes included

## Upstream Strategy

These patches should be submitted to upstream Sigul (<https://pagure.io/sigul>) to benefit the community and reduce our maintenance burden. Once accepted upstream, we can remove the patches and use official releases.

**Submission Priority:**

1. **HIGH:** Double-TLS handshake timing fix (this is critical for containers)

## Testing

To verify patches apply correctly:

```bash
# Test patch application locally
cd /tmp
git clone --depth 1 --branch v1.4 https://pagure.io/sigul.git
cd sigul
patch -p1 < /path/to/sigul-docker/patches/01-fix-double-tls-handshake-timing.patch

# Verify no errors
echo $?  # Should be 0
```

## Contributing

When adding new patches:

1. Keep patches minimal - only fix critical issues
2. Use descriptive filenames with numeric prefixes: `01-`, `02-`, etc.
3. Include clear comments explaining WHY the fix is needed
4. Test that patches apply cleanly to upstream Sigul v1.4
5. Plan for upstream submission

## Maintenance

When upstream Sigul releases new versions:

1. Test if patches still apply cleanly
2. Update patches if necessary
3. Remove patches that have been accepted upstream
4. Update `build-scripts/install-sigul.sh` if using newer version
