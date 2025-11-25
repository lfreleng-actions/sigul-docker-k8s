<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🔏 Sigul Signing

Used to sign build packages, artifacts and git tags using a Sigul server.

## sigul-sign-docker

## Usage

### Sign an object that is available in the workspace

```yaml
- uses: lfreleng-actions/sigul-sign-docker@v1
  with:
      sign-type: "sign-data"
      sign-object: ${{ github.workspace }}/artifacts/mypackage.tar.gz
      sigul-key-name: "my-release-key"
      gh-user: automation-username
      gh-key: ${{ secrets.GITHUB_TOKEN }}
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}

# This should produce an object named ${sign-object}.asc. We will then need to
# upload the artifact.
<!-- markdownlint-disable-next-line MD013 -->
- uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02  # v4.6.2
  with:
      name: Signatures
      path: ${{ github.workspace }}/mypackage.tar.gz.asc
```

### Sign batch objects in the workspace

```yaml
- uses: lfreleng-actions/sigul-sign-docker@v1
  with:
      sign-type: "sign-data"
      sign-object: |
          file.tar.gz
          artifacts/my-file.jar
          docs/signme.md
      sigul-key-name: "my-release-key"
      gh-user: automation-username
      gh-key: ${{ secrets.GITHUB_TOKEN }}
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}

# The action preserves the original file paths. Files such as
# "dir/subdir/file.ext" will have their signature files created in the same
# directory, e.g., "dir/subdir/file.ext.asc".
<!-- markdownlint-disable-next-line MD013 -->
- uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02  # v4.6.2
  with:
      name: Signatures
      path: ${{ github.workspace }}/*.asc
```

### Sign a git tag

```yaml
- uses: lfreleng-actions/sigul-sign-docker@v1
  with:
      sign-type: "sign-git-tag"
      sign-object: "v1.1" # Unsigned annotated tag in repo
      sigul-key-name: "my-release-key"
      gh-user: automation-username
      gh-key: ${{ secrets.GITHUB_TOKEN }}
      sigul-ip: ${{ secrets.SIGUL_IP }}
      sigul-uri: ${{ secrets.SIGUL_URI }}
      sigul-conf: ${{ secrets.SIGUL_CONF }}
      sigul-pass: ${{ secrets.SIGUL_PASS }}
      sigul-pki: ${{ secrets.SIGUL_PKI }}
```

## Inputs

## `sign-type`

The signing operation to perform, either `"sign-data"` or `"sign-git-tag"`.
Default `"sign-data"`

## `sign-object`

**Required** The file or git tag to sign.

## `sigul-ip`

**Required** The IP address of the sigul server.

## `sigul-uri`

**Required** The URI of the sigul server. The action uses this with the IP
address to create a hosts file entry for the server.

## `sigul-conf`

**Required** The sigul config file.

## `sigul-key-name`

**Required** The key name on the server to use.

## `sigul-pass`

**Required** The password for the sigul connection (this should be specific to
the key name).

## `sigul-pki`

**Required** PKI info for the sigul connection. Store this in a GPG armor file,
encrypted
using the above sigul-pass.

## `gh-user`

For git tag signing, the action requires a user to push the signed tag as.
Default: GITHUB_ACTOR (the name of the person or app that initiated the
workflow)

## `gh-key`

An API key for the user specified in `gh-user`. This is not a required field for
sign-data actions, but **MUST** exist for sign-git-tag actions.

## Requirements

This action requires access to a valid Sigul server infrastructure with:

- A properly configured Sigul server
- Valid PKI certificates and configuration
- Network access to the Sigul server from the GitHub Actions runner

## CI/CD Workflow Configuration

The GitHub Actions workflow supports manual control over Docker build caching
through workflow dispatch inputs:

### Workflow Dispatch Parameters

#### `force_rebuild` (boolean)

- **Description**: Force rebuild containers (bypasses cache)
- **Default**: `false`
- **Usage**: Set to `true` to disable Docker layer caching and force a complete
  rebuild of all containers
- **When to use**:
  - When investigating platform-specific build issues
  - When Docker layer caching may be causing inconsistent builds
  - When testing changes to base images or dependencies

#### `cache_version` (string)

- **Description**: Cache version (increment to bust cache)
- **Default**: `v2`
- **Usage**: Increment this value (e.g., `v3`, `v4`) to invalidate existing
  cache entries
- **When to use**:
  - When you want to clear cache without forcing a complete rebuild
  - When cache corruption occurs
  - When transitioning between different dependency versions

### Running Workflow with Custom Parameters

To run the workflow with custom caching behavior:

1. Go to the **Actions** tab in the GitHub repository
2. Select **"Sigul Build/Test/Release 🐳"** workflow
3. Click **"Run workflow"**
4. Configure the parameters:
   - Check **"Force rebuild containers"** to disable caching entirely
   - Update **"Cache version"** to bust existing cache (e.g., change from
     `v2` to `v3`)

### Troubleshooting Platform-Specific Issues

If you encounter different behavior between AMD64 and ARM64 platforms:

1. **Test without caching**: Run with `force_rebuild: true` to remove caching
   as a variable
2. **Isolate cache corruption**: Increment `cache_version` to test with fresh
   cache
3. **Compare logs**: Check if the issue persists across both caching states

## Container Architecture

This project uses a **simplified, maintainable build architecture** with
dedicated build scripts and clean Dockerfiles. The containers support both
**x86_64** and **ARM64** architectures with architecture-specific installation
methods.

### Simplified Build System

The project has moved from complex, fragile Dockerfiles to a clean,
maintainable architecture:

- **`build-scripts/install-sigul.sh`** - Centralized, testable installation
  logic
- **`Dockerfile.client`** - Clean sigul client container (UBI 9 based)
- **`Dockerfile.server`** - Clean sigul server container (Red Hat UBI 9 based)
- **`Dockerfile.bridge`** - Clean sigul bridge container (Red Hat UBI 9 based)

### Key Architecture Benefits

- **Maintainable**: Build logic extracted from Dockerfiles into testable scripts
- **Debuggable**: Clear error messages and logging throughout the build process
- **Consistent**: Single source of truth for architecture-specific installation
- **Testable**: Local testing tools to check builds before CI/CD
- **Reliable**: Reduced complexity and better error handling

### Multi-Architecture Support

- **x86_64 (AMD64)**: Uses pre-built Sigul packages from Fedora infrastructure
  repository
- **ARM64 (aarch64)**: Builds Sigul from source with automated dependency
  management
- **Unified Logic**: Both architectures use the same build script with automatic
  detection

### Architecture-Specific Installation

#### x86_64 Installation

- Installs Sigul 1.4 from official Fedora infrastructure repositories
- Faster build times due to pre-compiled binaries
- Fully tested and verified package installation

#### ARM64 Installation

- Builds Sigul 1.4 from source using the official upstream repository
- Automated dependency management and build process
- Proper cleanup to reduce final image size
- Creates identical functionality to x86_64 builds

### Network Architecture

**Important:** Sigul enforces fixed Bridge networking behavior:

- **Bridge Bind Address**: The Sigul bridge **ALWAYS** binds to `0.0.0.0`
  (all interfaces)
- **No Configuration Option**: No Sigul configuration parameter exists to
  change the bind address
- **Source Code Reference**:
  `sock.bind(nss.io.NetworkAddress(nss.io.PR_IpAddrAny, port))` in
  `/usr/share/sigul/bridge.py`
- **Security Implications**: Bridge will listen on all network interfaces;
  use container networking or firewall rules for access control

**Connection Flow:**

```text
Client → Bridge (port 44334) → Server (port 44333)
```

**Port Configuration:**

- `client-listen-port`: Port where bridge listens for client connections
  (default: 44334)
- `server-listen-port`: Port where bridge listens for server connections
  (default: 44333)
- `bridge-hostname`: Hostname clients/servers use to connect to bridge
  (default: sigul-bridge)

### Container Components

#### Sigul Client (`Dockerfile.client`)

- **Base**: Red Hat UBI 9 minimal for enterprise compliance
- **Purpose**: Signing operations and client functionality
- **Size**: Optimized for minimal footprint

#### Sigul Server (`Dockerfile.server`)

- **Base**: Red Hat UBI 9 for enterprise-grade stability
- **Purpose**: Core signing server functionality
- **Features**: SQLite database, PKI management

#### Sigul Bridge (`Dockerfile.bridge`)

- **Base**: Red Hat UBI 9 for compatibility with server
- **Purpose**: Network bridge between clients and server
- **Features**: Network isolation, secure communication

### Supported Platforms

- `linux/amd64` (x86_64)
- `linux/arm64` (aarch64)

Both architectures provide identical functionality and pass the same
comprehensive test suite to ensure consistent behavior regardless of the
underlying platform.

## Local Development and Testing

This project includes comprehensive local testing and debugging tools to help
developers check changes before pushing to GitHub Actions. The simplified
build architecture makes local testing faster and more reliable.

### Quick Start - Local Testing

```bash
# Test the simplified builds (recommended for development)
# Test all components
./scripts/test-simplified-build.sh
# Test client
./scripts/test-simplified-build.sh --client

# Traditional comprehensive testing
./scripts/test-locally.sh quick     # Quick build + binary validation
./scripts/test-locally.sh stack     # Start full docker-compose stack
./scripts/test-locally.sh debug     # Interactive debugging session
```

### Testing Scripts Overview

#### 1. `scripts/test-simplified-build.sh` - **Recommended for Development**

Fast, reliable testing of the new simplified build architecture:

- **No arguments** - Test all components (client, server, bridge)
- **`--client`** - Test client build (fastest option)
- **`--server`** - Test server build
- **`--bridge`** - Test bridge build
- **`--help`** - Show usage information

This script tests the new simplified Dockerfiles and build scripts, providing
quick feedback on build issues.

#### 2. `scripts/test-locally.sh` - Comprehensive Test Runner

Full-featured script for complete testing scenarios:

- **`quick`** - Fast validation (builds containers + checks binaries)
- **`full`** - Complete test suite with integration tests
- **`build`** - Build containers and check binaries
- **`stack`** - Start docker-compose stack and watch startup
- **`logs`** - Display logs from running containers
- **`debug`** - Interactive debugging with helpful commands
- **`clean`** - Clean up all test containers and images

#### 3. `scripts/debug-local.sh` - Advanced Debugging

Comprehensive debugging tool with detailed analysis:

- **`requirements`** - Check local Docker/compose installation
- **`binaries`** - Check all required binaries in containers
- **`init`** - Test initialization scripts in isolation
- **`stack`** - Full docker-compose stack testing
- **`interactive`** - Interactive debugging mode
- **`all`** - Run complete test suite

#### 4. `scripts/test-docker-build.sh` - Docker Build Testing

Comprehensive Docker build testing with network resilience validation:

- **No arguments** - Test all components and platforms
- **`-c client`** - Test specific component (client|server|bridge)
- **`-p linux/amd64`** - Test specific platform (linux/amd64|linux/arm64)
- **`-f, --fast`** - Skip network connectivity tests
- **`-k, --keep`** - Keep test images (don't cleanup)
- **`--timeout SECONDS`** - Set build timeout (default: 600s)

This script specifically tests Docker builds with robust error handling for
network connectivity issues, including EPEL repository access problems.

#### 5. `scripts/check-binaries.sh` - Binary Validation

Utility script for checking system requirements:

- Checks for PostgreSQL tools (`pg_isready`, `psql`)
- Checks NSS/crypto tools (`certutil`, `gpg`, `openssl`)
- Verifies system utilities (`groupadd`, `useradd`, etc.)
- Used by other scripts for dependency validation

#### 5. `build-scripts/install-sigul.sh` - Core Installation Logic

The heart of the simplified build system:

- **`client`** - Install sigul client component
- **`server`** - Install sigul server component
- **`bridge`** - Install sigul bridge component
- **`--verify`** - Verify installation after completion
- **`--debug`** - Enable detailed logging
- **`--help`** - Show usage information

You can test this script independently when debugging build issues.

### Local Testing Workflow

#### 1. Quick Development Cycle (Recommended)

```bash
# Fast feedback for Docker build changes
./scripts/test-simplified-build.sh --client

# Test all components after changes
./scripts/test-simplified-build.sh
```

#### 2. Before Making Changes

```bash
# Verify current setup works
./scripts/test-locally.sh quick
```

#### 3. After Making Changes

```bash
# Test your changes with new simplified builds (fast)
./scripts/test-simplified-build.sh

# Or test with full infrastructure (comprehensive)
./scripts/test-locally.sh stack

# If you find issues, debug interactively
./scripts/test-locally.sh debug
```

#### 4. Before Pushing to GitHub

```bash
# Run full test suite
./scripts/test-locally.sh full

# Verify simplified builds work
./scripts/test-simplified-build.sh
```

### Build Script Testing

You can also test the core build logic independently:

```bash
# Test the install script directly (in a container)
docker run --rm -it registry.access.redhat.com/ubi9/ubi-minimal:latest bash -c "
  microdnf install -y dnf curl git &&
  curl -L https://raw.githubusercontent.com/your-repo/\\
sigul-sign-docker/main/build-scripts/install-sigul.sh \\
    | bash -s -- --verify client
"

# Or test locally if you have the right base system
./build-scripts/install-sigul.sh --help
```

### Debugging Container Issues

#### Check Binary Dependencies

```bash
# See what binaries are missing/available
./scripts/debug-local.sh binaries
```

#### Interactive Debugging

```bash
# Start stack and enter debug mode
./test-local debug

# Then use these commands:
docker compose -f docker-compose.sigul.yml exec sigul-server /bin/bash
docker compose -f docker-compose.sigul.yml logs -f sigul-server
```

#### Container Build Issues

```bash
# Test individual container builds
./scripts/debug-local.sh build

# View detailed build logs and binary availability
```

### Required Local Dependencies

- **Docker Desktop** or Docker Engine with Compose V2
- **Git** (for repository operations)
- **Bash** (for running test scripts)

### Container Binary Dependencies

#### Sigul Server Container

- `pg_isready`, `psql` (PostgreSQL client tools)
- `certutil` (NSS certificate utilities)
- `gpg` (GNU Privacy Guard)
- `groupadd`, `useradd` (user management)
- System utilities: `hostname`, `chown`, `mkdir`, etc.

#### Sigul Bridge Container

- `nc` (netcat for network testing)
- `certutil`, `pk12util` (NSS tools)
- `openssl` (SSL/TLS utilities)
- `groupadd`, `useradd` (user management)
- System utilities: `hostname`, `chown`, etc.

### Common Issues and Solutions

#### Container Privilege Dropping Issues

**Important**: Sigul daemons attempt to drop privileges by default using the
`unix-user` and `unix-group` configuration settings. In containerized
environments where the container already runs as a non-root user (like our UID
1000 `sigul` user), this privilege dropping can fail and cause startup issues.

**Symptoms**:

- Bridge or server containers stuck in restart loops
- Log messages like "Error switching to user 1000: name 'fedora' is not defined"
- SSL certificate errors after privilege dropping failures

**Solution**: The initialization script automatically sets empty `unix-user` and
`unix-group` values in the daemon configuration for containers:

```ini
[daemon]
unix-user =
unix-group =
```

This disables privilege dropping since the container runtime already provides
the correct user context. This is safe because:

- Containers already run as the intended `sigul` user (UID 1000)
- Container isolation provides security boundaries
- No privilege dropping provides any benefit

**Technical Details**: Setting `unix-user = ""` causes `config.daemon_uid =
None` in the Python code, which skips the `os.seteuid()` calls in the daemon
startup process.

#### Missing Binaries

If containers fail due to missing binaries:

```bash
# Check what's missing
./scripts/debug-local.sh binaries

# The output will show missing packages to install
```

#### Database Connection Issues

```bash
# Check PostgreSQL connectivity
./scripts/test-locally.sh logs

# Look for database initialization errors
docker compose -f docker-compose.sigul.yml logs postgres
```

#### Network Issues

```bash
# Verify container networking
docker compose -f docker-compose.sigul.yml ps
docker network ls | grep sigul
```

### Advanced Debugging

#### Manual Container Testing

```bash
# Build and test individual containers
docker build -f docker-compose.sigul.yml --target sigul-server -t debug-server .
docker run -it debug-server /bin/bash

# Test init scripts manually
/usr/local/bin/sigul-server-init.sh
```

#### Initialization Script Debugging

The init scripts include comprehensive logging and validation:

- Remove `set -e` temporarily for debugging
- Add `set -x` for verbose execution tracing
- Use `validate_prerequisites` function for binary checking

### Integration with GitHub Actions

The local testing scripts mirror the GitHub Actions workflow:

- Same container builds and configurations
- Identical binary requirements and validation
- Similar initialization and startup procedures

This ensures that issues found locally will match production behavior, and
fixes tested locally will work in GitHub Actions.

### Contributing

When contributing to this project:

1. **Use simplified builds for development** with
   `./scripts/test-simplified-build.sh`
2. **Test locally before pushing** using the appropriate test script
3. **Update build-scripts/install-sigul.sh** for installation changes rather
   than modifying Dockerfiles
4. **Add binary validation** for any new dependencies in the install script
5. **Test both architectures** if possible (x86_64 and ARM64)
6. **Update this README** for any new requirements or script changes

The simplified architecture and local testing tools make development much more
efficient and reliable.

### Available Local Testing Commands

#### Quick Development (Recommended)

- `./scripts/test-simplified-build.sh` - Test all simplified builds (fast)
- `./scripts/test-simplified-build.sh --client` - Test client (fastest)

#### Comprehensive Testing

- `./scripts/test-locally.sh quick` - Fast validation with binary checks
- `./scripts/test-locally.sh stack` - Full infrastructure stack testing
- `./scripts/test-locally.sh debug` - Interactive debugging mode
- `./scripts/test-locally.sh clean` - Clean up test containers

#### Advanced Debugging Tools

- `./scripts/debug-local.sh all` - Comprehensive debugging suite
- `./scripts/debug-local.sh binaries` - Check binary dependencies
- `./scripts/debug-local.sh requirements` - Verify local setup

#### Build Script Testing Tools

- `./build-scripts/install-sigul.sh --help` - Show install script options
- `./build-scripts/install-sigul.sh --verify client` - Test client installation

## Stack Testing with Local Docker Environments

For local development and troubleshooting, the deployment scripts support a special **local debugging mode** that persists infrastructure containers for analysis and prevents automatic cleanup.

### Local Debug Mode

When developing or debugging Sigul integration issues locally, use the `--local-debug` flag to:

- **Persist Infrastructure**: Containers remain running after tests complete
- **Skip Cleanup**: No automatic cleanup of containers, networks, or volumes
- **Enable Verbose Output**: Detailed logging for troubleshooting
- **Clear Local Indicators**: Visual warnings that you're in local debug mode

### Usage Examples

#### Deploy Infrastructure for Local Debugging

```bash
# Deploy with persistent infrastructure
./scripts/deploy-sigul-infrastructure.sh --local-debug

# This will show:
# 🔧 --- LOCAL DEBUGGING MODE ENABLED ---
#    Infrastructure will persist for troubleshooting
#    Use 'docker compose -f docker-compose.sigul.yml down -v' to cleanup
```

#### Run Integration Tests with Persistent Containers

```bash
# Run tests without cleanup
export SIGUL_CLIENT_IMAGE="client-linux-arm64-image:test"
./scripts/run-integration-tests.sh --local-debug

# This will show:
# 🔧 --- LOCAL DEBUGGING MODE ENABLED ---
#    Infrastructure will remain for troubleshooting
```

#### Manual Certificate Exchange for Debugging

```bash
# After deployment, fix SSL certificates manually
./debug/fix_backend_ssl_certs.sh --verbose

# Test client connectivity
./debug/test_client_connection.sh --verbose
```

### Local Debugging Workflow

1. **Deploy Fresh Infrastructure**:

   ```bash
   # Clean up any existing containers first
   docker compose -f docker-compose.sigul.yml down -v --remove-orphans

   # Deploy with persistence
   ./scripts/deploy-sigul-infrastructure.sh --local-debug
   ```

2. **Fix SSL Certificates** (required for current version):

   ```bash
   ./debug/fix_backend_ssl_certs.sh --verbose
   ```

3. **Run Tests with Persistence**:

   ```bash
   export SIGUL_CLIENT_IMAGE="client-linux-arm64-image:test"
   ./scripts/run-integration-tests.sh --local-debug
   ```

4. **Debug Infrastructure State**:

   ```bash
   # Check container status
   docker ps

   # Check container logs
   docker logs sigul-server
   docker logs sigul-bridge

   # Check NSS databases
   docker exec sigul-bridge certutil -L -d /var/sigul/nss/bridge
   docker exec sigul-server certutil -L -d /var/sigul/nss/server

   # Check network connectivity
   docker exec sigul-bridge ss -tlnp | grep 4433
   docker exec sigul-server ss -tn | grep 44333
   ```

5. **Manual Cleanup When Done**:

   ```bash
   # Clean up everything
   docker compose -f docker-compose.sigul.yml down -v --remove-orphans
   docker system prune -f
   ```

### Platform Compatibility

The local debug mode works on **all platforms** where Docker is available:

- **macOS** (Intel and Apple Silicon)
- **Linux** (x86_64 and ARM64)
- **Windows** (with WSL2/Docker Desktop)

### Key Benefits for Local Development

- **Faster Iteration**: No need to redeploy infrastructure for each test
- **Deep Debugging**: Containers remain accessible for log analysis
- **State Inspection**: Examine NSS databases, certificates, and configuration
- **Network Analysis**: Debug SSL/TLS connections and certificate exchange
- **Persistent Testing**: Multiple test runs against same infrastructure

### Current Known Issues (Local Debug Mode)

1. **SSL Certificate Exchange**: Requires manual fix after deployment

   ```bash
   ./debug/fix_backend_ssl_certs.sh --verbose
   ```

2. **Admin User Creation**: EOFError in batch mode during server initialization
   - Admin user creation fails during container startup
   - This causes client authentication to fail
   - Fix in development for server initialization script

3. **Integration Test Dependencies**: Some tests expect fresh containers
   - Client certificate import to bridge happens in integration script
   - May need multiple runs to get full certificate exchange

### Troubleshooting Tips

- **Always start with fresh deployment** when debugging new issues
- **Check SSL certificates first** - most communication issues are certificate-related
- **Use verbose mode** to get detailed logging output
- **Check container logs** before assuming configuration issues
- **Verify network connectivity** at the socket level before debugging application layer

### Debugging Resources

- **`debug/fix_backend_ssl_certs.sh`** - Fix server↔bridge certificate exchange
- **`debug/test_client_connection.sh`** - Test client↔bridge SSL connectivity
- **`DEBUGGING_PROCESS_AND_FINDINGS.md`** - Comprehensive debugging documentation
- **`debug/correct_testing_process.sh`** - Demonstrates proper fresh container testing
- **`docs/CONTAINER_LOGGING.md`** - Container logging configuration and troubleshooting
- **`DEBUG_MODE.md`** - Advanced debugging mode for monitoring container processes

### Integration with CI/CD

The local debug mode is **automatically disabled in CI/CD environments**. The scripts detect GitHub Actions and other CI environments and always perform proper cleanup.

Local debug mode only activates when:

- `--local-debug` flag is explicitly provided
- Running in interactive terminal (not CI/CD)
- Docker environment is available locally
