<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Test PKI Infrastructure

This directory contains the PKI scaffolding for Sigul integration testing.

## Certificate generation

The runtime generates the Sigul server, bridge, and client certificates
fresh inside NSS databases (`certutil`/`pk12util`); this repository
ships no static certificate files. Container startup runs
`scripts/cert-init.sh`, which makes the bridge act as a throwaway
Certificate Authority: it creates an NSS database under
`/etc/pki/sigul/bridge`, signs a certificate for each role (bridge,
server, client), and exports the public material to distribution
directories under the bridge NSS volume
(`/etc/pki/sigul/bridge/{ca,server,client}-export`). The server and
client import their certificates from there. The bridge shares its CA
public certificate and retains the CA private key.
`pki/generate-production-aligned-certs.sh` is a separate NSS helper for
local and test tooling; `tests/test-serial-fix-e2e.sh` exercises it
directly and the container `cert-init.sh` flow does not invoke it.

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
  helper for local and test tooling. `tests/test-serial-fix-e2e.sh`
  exercises it directly; the container `cert-init.sh` flow does not
  invoke it.

## Client PKI

The system packages client PKI separately in
`pki/client-pki-encrypted.asc` (git-ignored, generated on demand) and
includes:

- Client certificate and private key
- CA certificate for verification
- Client configuration
- Test signing key

## Usage in Docker Compose

`scripts/cert-init.sh` runs at container startup, generates a fresh CA
on the bridge, and issues component certificates for the containerized
deployment. The bridge-held CA signs every component certificate, which
keeps trust relationships consistent across the stack.

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

The runtime generates the CA certificate and private key on demand; the
repository stores no CA private key. In production, use a proper
Certificate Authority with appropriate security controls.
