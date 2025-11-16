<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Test PKI Infrastructure

This directory contains the PKI infrastructure for Sigul integration testing.

## Files

### Certificate Authority

- `ca.crt` - Root CA certificate (public)

### Server Certificates

- `server.crt` - Sigul server certificate (public)
- `server-key.pem` - Sigul server private key (private)

### Bridge Certificates

- `bridge.crt` - Sigul bridge certificate (public)
- `bridge-key.pem` - Sigul bridge private key (private)

### Configuration Templates

- `server.conf.template` - Server configuration template
- `bridge.conf.template` - Bridge configuration template

## Client PKI

The system packages client PKI separately in `pki/client-pki-encrypted.asc` and includes:

- Client certificate and private key
- CA certificate for verification
- Client configuration
- Test signing key

## Usage in Docker Compose

This script uses the existing shared CA from the repository and generates
component certificates for containerized deployments. The shared CA ensures
consistent trust relationships across all deployments.

## Usage in Workflows

The system generates client PKI dynamically during workflow execution using the
`./scripts/generate-test-pki.sh` script. The workflows will capture the
generated encrypted PKI content and pass it via environment variables.

Example workflow usage:

```yaml
- name: Generate PKI infrastructure
  run: ./scripts/generate-test-pki.sh

- name: Use Sigul signing action
  uses: ./
  with:
    sigul-pki: ${{ steps.generate-real-pki.outputs.encrypted-pki }}
    sigul-pass: ${{ steps.generate-real-pki.outputs.ephemeral-password }}
```

## Security Note

This PKI infrastructure serves testing purposes. Do not use in production.

The shared CA certificate and private key exist in the repository for
consistent testing across environments. In production, use a proper Certificate
Authority with appropriate security controls.
