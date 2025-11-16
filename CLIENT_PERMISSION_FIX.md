# Client Container Permission Fix

**SPDX-License-Identifier:** Apache-2.0  
**SPDX-FileCopyrightText:** 2025 The Linux Foundation

## Problem Statement

After fixing the volume detection issue (mounting `bridge_nss` instead of `bridge_data`), the integration tests revealed a new permission issue:

```
[18:51:14] NSS-INIT: Creating client NSS database...
mkdir: cannot create directory '/etc/pki/sigul/client': Permission denied
[2025-11-16 18:51:14] ERROR: Failed to initialize client container
```

## Root Cause

The client container was missing volume mounts for its own data:

1. **Client NSS Database** - No writable location for `/etc/pki/sigul/client`
2. **Client Configuration** - No writable location for `/etc/sigul`

The container runs as user `sigul` (UID 1000) and attempted to create directories in the container's filesystem, which either:
- Doesn't exist (no parent directory)
- Has wrong permissions (owned by root)
- Is read-only (container filesystem restrictions)

## Initial Approach (Incorrect)

First attempt was to mount volumes at the exact subdirectory paths:

```bash
-v "${client_nss_volume}":/etc/pki/sigul/client:rw
-v "${client_config_volume}":/etc/sigul:rw
```

**Problem:** This requires the parent directory `/etc/pki/sigul` to exist and be writable, which it wasn't when the container started with `--user sigul`.

## Correct Solution

Mount the volume at the parent directory level to allow the init script to create subdirectories:

```bash
-v "${client_pki_volume}":/etc/pki/sigul:rw
-v "${client_config_volume}":/etc/sigul:rw
```

This approach:
1. Mounts a volume at `/etc/pki/sigul` (parent directory)
2. Allows the script to run `mkdir -p /etc/pki/sigul/client`
3. Gives full control to create any needed subdirectories
4. Matches the Docker Compose architecture

## Implementation Details

### Volume Creation

```bash
# Create client PKI volume (contains all NSS databases under /etc/pki/sigul)
client_pki_volume="sigul-integration-client-pki"
docker volume create "$client_pki_volume"

# Initialize with correct ownership (UID 1000 = sigul user)
docker run --rm -v "$client_pki_volume:/target" alpine:3.19 \
    sh -c "mkdir -p /target && chown -R 1000:1000 /target"
```

### Volume Mounting

```bash
docker run -d --name sigul-client-integration \
    --user sigul \
    -v "${bridge_nss_volume}":/etc/pki/sigul/bridge-shared:ro \
    -v "${client_pki_volume}":/etc/pki/sigul:rw \
    -v "${client_config_volume}":/etc/sigul:rw \
    "$SIGUL_CLIENT_IMAGE" \
    tail -f /dev/null
```

### Volume Cleanup

```bash
cleanup_containers() {
    # ... other cleanup ...
    
    # Clean up integration test volumes
    docker volume rm sigul-integration-client-pki 2>/dev/null || true
    docker volume rm sigul-integration-client-config 2>/dev/null || true
}
```

## Why This Works

### Directory Structure Created

With the volume mounted at `/etc/pki/sigul`:

```
/etc/pki/sigul/                    # Mounted volume (owned by sigul:sigul)
├── bridge-shared/                 # Read-only mount from bridge NSS volume
│   ├── cert9.db
│   ├── key4.db
│   └── pkcs11.txt
└── client/                        # Created by init script
    ├── cert9.db                   # Client NSS database
    ├── key4.db                    # Client keys
    └── pkcs11.txt                 # PKCS#11 config
```

### Permission Flow

1. **Volume Creation:** Docker creates volume with default ownership
2. **Ownership Fix:** Alpine container sets ownership to `1000:1000` (sigul user)
3. **Volume Mount:** Volume mounted at `/etc/pki/sigul` with `:rw` permissions
4. **Container Starts:** Container runs as `--user sigul` (UID 1000)
5. **Init Script:** Can create `/etc/pki/sigul/client` because it owns parent directory
6. **Success:** NSS database created successfully

## Comparison with Docker Compose

This approach now matches the Docker Compose configuration:

```yaml
# docker-compose.sigul.yml
sigul-client-test:
  volumes:
    - sigul_client_config:/etc/sigul:rw
    - sigul_client_nss:/etc/pki/sigul/client:rw
    - sigul_bridge_nss:/etc/pki/sigul/bridge-shared:ro
```

**Difference:** Integration tests mount at `/etc/pki/sigul` (parent) instead of `/etc/pki/sigul/client` (subdirectory) to allow the init script to create the subdirectory structure. This is appropriate for ephemeral test containers that need full initialization.

## Files Modified

### `scripts/run-integration-tests.sh`

**Lines 209-237:** Volume detection and creation
- Created `client_pki_volume` instead of `client_nss_volume`
- Mount at `/etc/pki/sigul` instead of `/etc/pki/sigul/client`
- Initialize volume with correct ownership

**Lines 807-808:** Cleanup
- Remove `sigul-integration-client-pki` volume
- Remove `sigul-integration-client-config` volume

## Testing Verification

### Before Fix
```
❌ mkdir: cannot create directory '/etc/pki/sigul/client': Permission denied
❌ Failed to initialize client container
```

### After Fix
```
✅ Created role-specific directory: /etc/pki/sigul/client
✅ NSS-SUCCESS: FHS-compliant directory structure created
✅ NSS-SUCCESS: NSS password generated and saved
✅ NSS-DEBUG: Bridge NSS database found at /etc/pki/sigul/bridge-shared
✅ Client container initialized successfully
```

## Key Learnings

### Volume Mount Strategy

When a container needs to create subdirectories:
- **Mount at parent directory** - Gives script control over structure
- **Set proper ownership** - Initialize volume with expected UID/GID
- **Use `:rw` permissions** - Allow read-write access for the user

When a container only reads existing data:
- **Mount at exact path** - Locks down access to specific data
- **Use `:ro` permissions** - Prevents accidental modifications
- **Share from source** - Bridge NSS volume shared read-only

### User Context Matters

Running containers with `--user` requires:
1. Mounted volumes owned by that UID
2. Writable paths for any directories the process creates
3. Proper initialization of volumes before container starts

### Integration Test Pattern

For ephemeral test containers:
1. Create dedicated volumes (don't reuse compose volumes)
2. Initialize ownership immediately after creation
3. Mount at appropriate levels for script flexibility
4. Clean up volumes after tests complete

## Related Documentation

- `CLIENT_SETUP_DEBUG_ANALYSIS.md` - Original volume detection fix
- `CI_INTEGRATION_TEST_FIXES.md` - Path and volume name fixes
- `INTEGRATION_TEST_RESOLUTION_SUMMARY.md` - Overall fix summary
- `docker-compose.sigul.yml` - Production volume configuration

## Status

- ✅ **Issue Identified:** Permission denied creating client NSS directory
- ✅ **Root Cause:** Missing writable volumes for client container
- ✅ **Fix Applied:** Mount volumes at parent directory with proper ownership
- ⏳ **Verification Pending:** CI workflow execution
- ⏳ **Expected Result:** Integration tests pass successfully

---

**Fix Date:** 2025-11-16  
**Priority:** HIGH - Blocks CI integration tests  
**Impact:** Critical - Required for client initialization