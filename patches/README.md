<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Debugging Patches

This directory contains patches that add comprehensive debugging output to the
Sigul v1.4 source code to help diagnose double-TLS connection and
authentication issues.

## Purpose

The Docker image build process applies these patches to instrument
the Sigul client, bridge, and server components with debugging logging. This
helps diagnose:

1. **NSS Database Issues**: Certificate availability, trust flags, password validation
2. **SSL/TLS Connection Problems**: Handshake failures, certificate validation errors
3. **Double-TLS Communication**: Inner and outer TLS session establishment
4. **Authentication Failures**: User creation and password handling

## Patches

### 01-add-comprehensive-debugging.patch

Adds extensive logging to:

- **`src/utils.py`**: NSS initialization and database operations
  - NSS database path and password validation
  - Certificate enumeration
  - Detailed error messages for common failures

- **`src/double_tls.py`**: Double-TLS client connection process
  - Bridge hostname and port configuration
  - Certificate lookup and validation
  - TCP connection attempts
  - SSL handshake progress
  - Peer certificate verification
  - Child process error handling with context

- **`src/client.py`**: Client connection lifecycle
  - Operation identification
  - Connection parameters
  - NSS initialization status
  - EOF and connection reset error context

## How the Build Process Applies Patches

The patches are automatically applied during Docker image build:

1. `Dockerfile.{client,bridge,server}` copies this directory to `/tmp/patches/`
2. `build-scripts/install-sigul.sh` downloads Sigul v1.4 source
3. The install script applies all `*.patch` files in order
4. Sigul is then built and installed with the debugging code included
5. The build process cleans up the patches directory after installation

## Debug Output Format

The patches add structured debug output with clear markers:

```text
==================== NSS INITIALIZATION DEBUG ====================
NSS_DIR: /etc/pki/sigul/client
NSS_PASSWORD length: 16
Calling nss.nss.nss_init(/etc/pki/sigul/client)
NSS database initialization complete
✓ NSS password authentication successful
Available certificates in NSS database:
  - CN=sigul-ca,O=Sigul Test CA
  - CN=sigul-bridge-cert,O=Sigul Test CA
  - CN=sigul-client-cert,O=Sigul Test CA
==================== NSS INITIALIZATION COMPLETE ====================
```

## Removing Patches

To build without debugging patches:

1. Remove or rename this directory
2. Rebuild the Docker images

The install script will detect the absence of patches and proceed with the build.

## Contributing

When adding new patches:

1. Use sequential numbering: `01-`, `02-`, etc.
2. Target specific issues or components
3. Include descriptive error messages with values
4. Use consistent markers (`====`, `✓`, `✗`) for visibility
5. Test that patches apply cleanly to Sigul v1.4 source

## Testing Patches Locally

To test patch application without full Docker build:

```bash
# Clone Sigul source from GitHub fork
cd /tmp
git clone --depth 1 --branch v1.4 https://github.com/ModeSevenIndustrialSolutions/sigul.git
cd sigul

# Apply the debugging changes
patch -p1 < /path/to/sigul-docker/patches/01-add-comprehensive-debugging.patch

# Verify
echo "Patch applied"
```

## Expected CI/CD Impact

With these patches applied, CI integration test logs will show:

- Detailed NSS database initialization steps
- SSL handshake progress and failures
- Certificate validation results
- Specific error locations in the double-TLS process

This makes it much easier to identify whether failures are due to:

- Missing or incorrectly trusted certificates
- NSS password mismatches
- Network connectivity issues
- Bridge/server unavailability
- Authentication/authorization problems
