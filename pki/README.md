<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Test PKI Infrastructure

This directory contains the PKI scaffolding for Sigul integration testing.

## Certificate generation

The runtime generates the Sigul server, bridge, and client certificates
fresh inside an NSS database (`certutil`/`pk12util`); this repository
ships no static certificate files. Container startup runs
`scripts/cert-init.sh`, which creates a throwaway CA and signs a
component certificate for each role into
`/etc/pki/sigul/<component>`, then distributes the runtime material
under `/var/sigul/secrets/certificates/`.
`pki/generate-production-aligned-certs.sh` is the NSS generation helper
that flow invokes (and that `tests/test-serial-fix-e2e.sh` exercises
directly).

Because the runtime mints every certificate and private key on demand,
this repository commits no long-lived private keys.

> Historical note: earlier revisions committed static
> `server-key.pem` / `server.crt` and `bridge-key.pem` / `bridge.crt`
> PEM pairs here. The NSS-based runtime generation above superseded
> them; no runtime code path ever read them, so we removed them. Do
> not re-add private keys to this directory.

## Files

### Configuration Templates

- `server.conf.template` - Server configuration template
- `bridge.conf.template` - Bridge configuration template
- `client.conf.template` - Client configuration template

### Scripts

- `generate-production-aligned-certs.sh` - NSS certificate generation
  helper used by the runtime cert-init flow

## Client PKI

The system packages client PKI separately in
`pki/client-pki-encrypted.asc` (git-ignored, generated on demand) and
includes:

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
