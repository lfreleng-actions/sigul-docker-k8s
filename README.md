<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🔏 Sigul Signing

A GitHub Action and supporting Docker stack for signing build artefacts and
git tags using a [Sigul](https://pagure.io/sigul) signing server.

This repository provides two things:

1. **A composite GitHub Action** (`sigul-sign-docker`) that workflows can use
   to sign files or git tags by talking to a Sigul server over its bridge.
2. **A complete reference Sigul stack** (server + bridge + client containers,
   Docker Compose definition, deployment scripts and end-to-end test suite)
   used to validate the action against a live Sigul instance and to provide
   a reproducible local debugging environment.

## Action usage

The action is a GitHub composite action that builds the Sigul client image
on the runner and uses it to sign one or more workspace files or a git
tag.  The build only reuses an already-present local image, so on
GitHub-hosted runners (where the Docker daemon is ephemeral) the build
runs once per workflow run; on self-hosted runners or within a single
job the image persists between steps.  If you need cross-run caching,
layer a `docker/build-push-action` step with `cache-from`/`cache-to` of
type `gha` ahead of the `uses:` line below.

### Sign a single file

```yaml
- uses: lfreleng-actions/sigul-sign-docker@v1
  with:
      sign-type: 'sign-data'
      sign-object: ${{ github.workspace }}/artifacts/mypackage.tar.gz
      sigul-key-name: 'my-release-key'
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}

# Produces ${sign-object}.asc next to the input file.
- uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
  with:
      name: Signatures
      path: ${{ github.workspace }}/artifacts/mypackage.tar.gz.asc
```

### Sign multiple files in a single invocation

```yaml
- uses: lfreleng-actions/sigul-sign-docker@v1
  with:
      sign-type: 'sign-data'
      sign-object: |
          file.tar.gz
          artifacts/my-file.jar
          docs/signme.md
      sigul-key-name: 'my-release-key'
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}

# The action preserves directory structure: dir/sub/file.ext is signed in
# place as dir/sub/file.ext.asc.
```

### Sign a git tag

```yaml
- uses: lfreleng-actions/sigul-sign-docker@v1
  with:
      sign-type: 'sign-git-tag'
      sign-object: 'v1.1' # Existing unsigned annotated tag in the repo
      sigul-key-name: 'my-release-key'
      gh-user: automation-username
      gh-key: ${{ secrets.GITHUB_TOKEN }}
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}
```

## Action inputs

All inputs reflect [`action.yml`](./action.yml).

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `sign-type` | no | `sign-data` | Either `sign-data` or `sign-git-tag`. |
| `sign-object` | yes | — | File to sign (or newline-separated list of files), or the name of a git tag. |
| `sigul-key-name` | yes | — | Name of the key on the Sigul server to sign with. |
| `sigul-ip` | yes | — | IP address of the Sigul server. Used together with `sigul-uri` to populate `/etc/hosts` inside the action's container. |
| `sigul-uri` | yes | — | Hostname (URI) of the Sigul server. |
| `sigul-conf` | yes | — | Sigul client configuration file contents. |
| `sigul-pass` | yes | — | Passphrase for the Sigul key (key-specific). |
| `sigul-pki` | yes | — | PKI material for the client, stored as a GPG-armoured file encrypted with `sigul-pass`. |
| `gh-user` | no | `github.actor` | GitHub user to push the signed tag as (`sign-git-tag` only). |
| `gh-key` | no | — | GitHub API key for `gh-user`. **Required** for `sign-git-tag`; not used for `sign-data`. |
| `sigul-mock-mode` | no | `false` | When `true`, emit deterministic mock signatures locally without contacting a Sigul server. Useful for testing workflow plumbing. |

### Requirements

To use the action against a real signing server you need:

- A reachable Sigul server with bridge.
- A Sigul key whose passphrase matches `sigul-pass`.
- PKI material (NSS database / certificates) packaged into `sigul-pki`,
  encrypted using `sigul-pass`.
- Network connectivity from the GitHub Actions runner to the Sigul bridge.

## Container architecture

This repository builds three containers, all from `fedora:44`:

| Container | Dockerfile | Role |
| --------- | ---------- | ---- |
| Client | [`Dockerfile.client`](./Dockerfile.client) | Sigul client used by the action and the integration tests. |
| Server | [`Dockerfile.server`](./Dockerfile.server) | Sigul server: holds the signing keys, runs SQLite-backed key/user database. |
| Bridge | [`Dockerfile.bridge`](./Dockerfile.bridge) | Sigul bridge: brokers double-TLS connections between clients and the server. |

### How Sigul is built

All three images install Sigul **from the upstream source tree at
[`pagure.io/sigul`](https://pagure.io/sigul)** by way of
[`build-scripts/install-sigul.sh`](./build-scripts/install-sigul.sh). The
same script is used for both `linux/amd64` and `linux/arm64`; there is no
architecture-specific install logic. Pinned local fixes live in
[`patches/`](./patches/) and apply in numeric order during the image build.

`python-nss-ng` (the Python bindings) is installed from PyPI rather than
distro packages. SQLite is the only database used by the server; there is no
PostgreSQL dependency.

### Network topology

```text
client  --(TLS, port 44334)-->  bridge  --(TLS, port 44333)-->  server
```

- `bridge-hostname` (default: `sigul-bridge`) — hostname clients and servers
  use to reach the bridge.
- `client-listen-port` (default: `44334`) — bridge port for client connections.
- `server-listen-port` (default: `44333`) — bridge port for server connections.
- The Sigul bridge unconditionally binds to `0.0.0.0` (all interfaces); access
  control is the responsibility of the surrounding container network or
  firewall configuration.

### Supported platforms

- `linux/amd64`
- `linux/arm64`

Both architectures are built and tested on every PR; the same test suite runs
against each.

## CI workflow

The `Sigul Build/Test 🐳` workflow defined in
[`.github/workflows/build-test.yaml`](./.github/workflows/build-test.yaml)
builds the three images for both architectures, runs the integration and
signing test suites against the resulting stack, and (on `workflow_dispatch`
with `publish_ghcr: true`) publishes the images to GHCR.

Workflow trigger: `pull_request` to `main`, plus `workflow_dispatch` with the
following inputs:

| Input | Default | Purpose |
| ----- | ------- | ------- |
| `clear_cache` | `false` | Bypass GitHub Actions cache and rebuild images from scratch. |
| `enable_auth_debug` | `false` | Set `SIGUL_DEBUG_AUTH=1` in the bridge and server, surfacing `AUTHDBG/*` lines in container logs. |
| `publish_ghcr` | `true` | Publish freshly-built images to `ghcr.io/<org>/<repo>/sigul-sign-docker`. Untick when iterating on the workflow itself. |

## Local development

### Prerequisites

- Docker Engine or Docker Desktop with Compose V2.
- `bash`, `git`.
- A few hundred MiB of free disk space for the three images.

### Bringing up the stack locally

```bash
# 1. Build the three images for your host architecture.
#    Replace 'linux-arm64' with 'linux-amd64' on Intel hosts.
PLATFORM_ID=linux-arm64
for component in client server bridge; do
    docker build \
        --platform "linux/${PLATFORM_ID#linux-}" \
        -f "Dockerfile.${component}" \
        -t "${component}-${PLATFORM_ID}-image:test" \
        .
done

# 2. Deploy the stack (server + bridge + cert-init).
SIGUL_RUNNER_PLATFORM=${PLATFORM_ID} ./scripts/deploy-sigul-infrastructure.sh
```

The deploy script writes an ephemeral admin password to
`test-artifacts/admin-password` and an NSS database password to
`test-artifacts/nss-password`; the test scripts read both back from disk.

### Running the test suites

The repository ships two end-to-end suites, both of which CI runs against the
live stack:

```bash
# Control-plane tests: list-users, list-keys, double-TLS handshake, etc.
SIGUL_CLIENT_IMAGE=client-${PLATFORM_ID}-image:test \
    ./scripts/run-integration-tests.sh

# Full signing workflow: key lifecycle, sign-text / sign-data / sign-rpm /
# sign-rpms, user and key-access lifecycle.  Each output is independently
# verified with the upstream tool that would consume it (gpg, rpm).
SIGUL_CLIENT_IMAGE=client-${PLATFORM_ID}-image:test \
    ./scripts/run-signing-tests.sh
```

`run-signing-tests.sh` writes its scratch state to a `mktemp` directory and
cleans up via a trap on EXIT; nothing is left behind on a successful run.

### Tearing the stack down

```bash
# Removes all containers, networks and named volumes Compose created
# from this docker-compose.sigul.yml regardless of project prefix.
docker compose -f docker-compose.sigul.yml down -v --remove-orphans
```

### Documentation

- [`DEPLOYMENT_GUIDE.md`](./DEPLOYMENT_GUIDE.md) — deploying the stack outside
  CI, including the production-aligned PKI patterns the Docker images derive
  from.
- [`OPERATIONS_GUIDE.md`](./OPERATIONS_GUIDE.md) — day-to-day operation,
  monitoring, health checks.
- [`TESTING.md`](./TESTING.md) — test infrastructure overview and the local
  ↔ CI parity guarantees the suites enforce.
- [`patches/README.md`](./patches/README.md) — what each downstream Sigul
  patch fixes and why.
- [`docs/`](./docs) — deeper dives on individual subsystems (NSS, container
  logging, network architecture).

## Contributing

See the patches `README.md` for guidance on how the Sigul source patches are
structured and applied. New CI changes should land via a pull request to
`main`; the build/test workflow gates the merge.
