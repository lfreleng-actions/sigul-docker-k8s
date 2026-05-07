<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🔏 Sigul Signing

A GitHub Action and supporting Docker stack for signing build artefacts and
git tags using a [Sigul](https://pagure.io/sigul) signing server.  Two
deliverables live in this repository:

1. **A composite GitHub Action** (`sigul-docker`) that workflows can use to
   sign files or git tags by talking to a Sigul server over its bridge.
2. **A complete reference Sigul stack** — server + bridge + client
   containers, Docker Compose definition, deployment scripts and
   end-to-end test suite — used to validate the action against a live
   Sigul instance and to provide a reproducible local debugging
   environment.

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
- uses: lfreleng-actions/sigul-docker@v1
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
- uses: lfreleng-actions/sigul-docker@v1
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
- uses: lfreleng-actions/sigul-docker@v1
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
| `publish_ghcr` | `true` | Publish freshly-built images to `ghcr.io/<org>/<repo>/sigul-docker`. Untick when iterating on the workflow itself. |

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

- [`DEPLOYMENT_GUIDE.md`](./DEPLOYMENT_GUIDE.md) — deploying the stack
  outside CI.
- [`OPERATIONS_GUIDE.md`](./OPERATIONS_GUIDE.md) — day-to-day operation,
  monitoring, health checks.
- [`TESTING.md`](./TESTING.md) — test infrastructure overview.
- [`patches/README.md`](./patches/README.md) — what each downstream Sigul
  patch fixes and why.
- [`docs/`](./docs) — deeper dives on individual topics.

## Contributing

Contributions land through GitHub pull requests against `main`.  The
`Sigul Build/Test 🐳` workflow is required to pass before a PR can
merge — it builds all three images for both `linux/amd64` and
`linux/arm64`, runs the integration test suite, and then runs the full
end-to-end signing test suite against the resulting stack.  Treat a
failing CI run as the source of truth.

### Where to make which change

- **Sigul behaviour fixes** — add a numbered patch to
  [`patches/`](./patches/) (`NN-short-description.patch`).  The patch
  applies on top of the bundled Sigul source during the image build.
  Document every patch in [`patches/README.md`](./patches/README.md)
  using the same `Status / Affects / Problem / Fix / Impact` structure
  as the existing entries; if a patch is critical for the stack to
  start at all, mark it as such.  Verify `git apply --check` works
  against the bundled Sigul source tree before pushing.  Note that
  upstream Sigul on Pagure has not had a commit in over a year and
  Pagure itself is scheduled to be decommissioned around mid-2026, so
  in practice these patches are a permanent local fork rather than
  a staging area for upstream submission.
- **Container build / packaging changes** — prefer
  [`build-scripts/install-sigul.sh`](./build-scripts/install-sigul.sh)
  over editing the Dockerfiles, so the install path stays uniform
  across `linux/amd64` and `linux/arm64`.  When you do touch a
  Dockerfile, change all three (`Dockerfile.{client,server,bridge}`)
  consistently — they share a base image and most of their package
  set.
- **Test changes** — the two end-to-end suites are
  [`scripts/run-integration-tests.sh`](./scripts/run-integration-tests.sh)
  (control plane: list-users, list-keys, double-TLS handshake, etc.)
  and
  [`scripts/run-signing-tests.sh`](./scripts/run-signing-tests.sh)
  (key lifecycle, sign-text/data/rpm/rpms, user and key-access
  lifecycle, with each output independently verified by gpg or rpm).
  New tests should fit into the existing `phase`/`testcase`/`pass`/
  `fail` shape and remain idempotent against repeated runs.
- **Workflow / CI changes** — [`build-test.yaml`](./.github/workflows/build-test.yaml)
  is the only workflow that exercises the stack end-to-end; iterate
  on it via `workflow_dispatch` with `publish_ghcr: false` until
  it's green.
- **Documentation changes** — keep the assertions in this README,
  `DEPLOYMENT_GUIDE.md`, `OPERATIONS_GUIDE.md` and `TESTING.md`
  consistent with what the scripts and Dockerfiles actually do.
  When you delete a script or rename a file, run a `grep -rn` for
  the old name across the repo and update or drop the dangling
  references.

### Local verification before pushing

1. Build the three images for your host architecture (see
   [Bringing up the stack locally](#bringing-up-the-stack-locally)).
2. Bring the stack up with `scripts/deploy-sigul-infrastructure.sh`.
3. Run `scripts/run-integration-tests.sh` and
   `scripts/run-signing-tests.sh`; both should exit `0` with all tests
   passing.
4. If you changed the action surface, run a manual
   `workflow_dispatch` of `Sigul Build/Test 🐳` with
   `publish_ghcr: false` to confirm both `linux/amd64` and
   `linux/arm64` legs stay green.

### Commit and PR conventions

- **Conventional Commits**, capitalised types: `Fix(scope):`,
  `Feat(scope):`, `Docs(scope):`, `Refactor(scope):`,
  `Test(scope):`, `Chore(scope):`, `CI(scope):`, `Build(scope):`,
  `Perf(scope):`, `Style(scope):`, `Revert(scope):`.  See
  [`.gitlint`](./.gitlint) for the enforced set.
- **Subject ≤ 50 chars, body wrapped at 72** (URL lines exempt).
- **DCO sign-off required** — every commit must end with
  `Signed-off-by: Name <email>`; use `git commit -s`.
- **Atomic commits** — one logical change per commit.  In particular,
  do not mix code or doc changes with task-tracking updates.
- **Pre-commit hooks** — the repository ships a
  [`.pre-commit-config.yaml`](./.pre-commit-config.yaml) that runs
  ruff, mypy, yamllint, actionlint, reuse (SPDX), codespell,
  markdownlint, gitlint and a few project-specific validators.
  Install with `pre-commit install`; never bypass with `--no-verify`.
  If a hook auto-fixes files, stage the fixes and re-commit — do
  not `git reset` after a failed commit.
- **AI-assisted commits** — include a `Co-authored-by:` trailer for
  the model used (e.g. `Co-authored-by: Claude <claude@anthropic.com>`)
  immediately above the `Signed-off-by` line.
- **SPDX headers** — every new source file needs SPDX
  `Apache-2.0` and copyright headers.  See
  [`REUSE.toml`](./REUSE.toml) for file-type-specific patterns; the
  `reuse` pre-commit hook will flag misses.

### Reporting an issue

Use [GitHub Issues](https://github.com/lfreleng-actions/sigul-docker/issues).
For TLS / NSS / handshake problems include the auth-debug capture
produced by setting `enable_auth_debug: true` on the
`workflow_dispatch` form, or by exporting `SIGUL_DEBUG_AUTH=1`
before running the deploy script locally.
