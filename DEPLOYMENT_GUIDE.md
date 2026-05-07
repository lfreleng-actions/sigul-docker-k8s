<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Deployment Guide

Step-by-step guide for deploying the Sigul stack (server + bridge + client
container) on a host with Docker. The same flow is used in CI by
`.github/workflows/build-test.yaml` and locally by
`scripts/deploy-sigul-infrastructure.sh`.

## Architecture summary

The stack is three containers built from `fedora:44`:

| Component | Image | Listens on |
| --------- | ----- | ---------- |
| Server | `server-<platform>-image:test` | (no incoming TCP; connects out to the bridge on port 44333) |
| Bridge | `bridge-<platform>-image:test` | TCP/44333 (server side), TCP/44334 (client side); always binds `0.0.0.0` |
| Client | `client-<platform>-image:test` | (run on demand by the action and test scripts) |

`<platform>` is `linux-amd64` or `linux-arm64`. The CI workflow builds and
publishes both. For local development you typically build only the platform
matching your host.

The server uses **SQLite** (default location `/var/lib/sigul/server.sqlite`)
for the user/key database. There is no PostgreSQL dependency.

The PKI is bridge-centric: the bridge container generates a self-signed CA
on first boot and signs the server and client certificates. The
`sigul-cert-init` one-shot container in the Compose file performs the
initial certificate provisioning before the long-running services start.

## Prerequisites

### Host requirements

- **Docker Engine** 24+ or Docker Desktop with Compose V2.
- **Architecture:** `linux/amd64` or `linux/arm64`.
- **Disk:** ~2 GiB free for the three images plus volume data.
- **Memory:** 2 GiB is comfortable; the stack is mostly idle when not
  signing.

### Network requirements

- Outbound HTTPS for the initial image build (Pagure for Sigul source,
  PyPI for `python-nss-ng`, the Fedora package mirrors).
- Outbound TCP/44334 from clients to the bridge once deployed.
- Outbound TCP/44333 from the server to the bridge.

The bridge always listens on all interfaces; expose it through your
container network or use a firewall to restrict who can reach it.

## Quick start

```bash
# 1. Build the three images for your host architecture.
PLATFORM_ID=linux-arm64           # or linux-amd64 on Intel
DOCKER_PLATFORM=linux/arm64       # or linux/amd64

for component in client server bridge; do
    docker build \
        --platform "${DOCKER_PLATFORM}" \
        -f "Dockerfile.${component}" \
        -t "${component}-${PLATFORM_ID}-image:test" \
        .
done

# 2. Deploy the stack.  The script writes ephemeral admin and NSS
#    passwords to test-artifacts/, generates configs, brings up
#    sigul-cert-init, sigul-server and sigul-bridge, and waits for
#    the bridge to be healthy.
SIGUL_RUNNER_PLATFORM=${PLATFORM_ID} \
    ./scripts/deploy-sigul-infrastructure.sh

# 3. Verify the deployment.
SIGUL_CLIENT_IMAGE=client-${PLATFORM_ID}-image:test \
    ./scripts/run-integration-tests.sh

# 4. (Optional) run the full end-to-end signing suite.
SIGUL_CLIENT_IMAGE=client-${PLATFORM_ID}-image:test \
    ./scripts/run-signing-tests.sh
```

A successful integration run prints `✅ ALL TESTS PASSED`. A successful
signing run prints `Passed: 41 / Failed: 0`.

### Tearing down

```bash
docker compose -f docker-compose.sigul.yml down -v --remove-orphans
docker volume ls --format '{{.Name}}' | grep '^sigul-docker_' \
    | xargs -r docker volume rm
```

## Day-2 operations

For monitoring, health checks, common tasks, incident response and
performance tuning, see [`OPERATIONS_GUIDE.md`](./OPERATIONS_GUIDE.md).

## Validation scripts

The repository ships several validation scripts under
[`scripts/`](./scripts) that sanity-check different aspects of the
deployment:

| Script | What it checks |
| ------ | -------------- |
| `validate-nss.sh` | NSS database files exist, have the right ownership, and contain the expected certificate nicknames. |
| `validate-certificates.sh` | Certificates are valid, not expired, and correctly chain to the CA. |
| `validate-configs.sh` | Bridge / server / client configs parse and reference matching FQDNs. |
| `validate-volumes.sh` | Required Docker volumes exist with the correct ownership. |
| `verify-cert-hostname-alignment.sh` | Bridge / server certificate CNs match the hostnames the configs use. |
| `verify-network.sh` / `verify-dns.sh` | Inter-container connectivity and name resolution. |

Each script supports `--help`.

## See also

- [`README.md`](./README.md) — Action usage, container architecture overview.
- [`OPERATIONS_GUIDE.md`](./OPERATIONS_GUIDE.md) — Day-to-day operations.
- [`TESTING.md`](./TESTING.md) — Test infrastructure and CI parity guarantees.
- [`patches/README.md`](./patches/README.md) — Downstream Sigul patches.
- [`docs/CERTIFICATE_INITIALIZATION.md`](./docs/CERTIFICATE_INITIALIZATION.md)
  — Detail on the bridge-centric PKI and certificate-init modes.
- [`docs/NETWORK_ARCHITECTURE.md`](./docs/NETWORK_ARCHITECTURE.md) — Bridge
  ↔ server connection flow and port configuration.
- [`docs/CONTAINER_LOGGING.md`](./docs/CONTAINER_LOGGING.md) — Log levels,
  log destinations, debug flags.
- [`docs/TLS_DEBUGGING_GUIDE.md`](./docs/TLS_DEBUGGING_GUIDE.md) and
  [`docs/DEBUGGING_QUICK_REFERENCE.md`](./docs/DEBUGGING_QUICK_REFERENCE.md)
  — Diagnosing TLS handshake / NSS issues.
