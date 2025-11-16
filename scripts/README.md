<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Scripts Directory

This directory contains scripts for building, testing, and managing the
sigul-sign-docker containers after the comprehensive refactoring that
unified the initialization system.

## 🚀 Quick Start

For most users, these are the scripts you'll need:

```bash
# Test all components locally
./scripts/test-all-architectures.sh

# Test specific platform
./scripts/test-local.sh --platform linux/amd64

# Test mock signing functionality
./scripts/test-mock-signing.sh

# Deploy infrastructure for testing
./scripts/deploy-sigul-infrastructure.sh
```

## 📁 Script Overview

### 🏗️ Core Infrastructure

<!-- markdownlint-disable MD013 -->
| Script | Purpose | When to Use |
|--------|---------|-------------|
| `sigul-init.sh` | **Unified initialization script** | Container startup (all roles) |
| `generate-complete-pki.sh` | Complete PKI infrastructure generation | Setting up test certificates |
| `generate-test-pki.sh` | Test PKI generation wrapper | Development and testing |
<!-- markdownlint-enable MD013 -->

### 🧪 Testing & Validation

<!-- markdownlint-disable MD013 -->
| Script | Purpose | When to Use |
|--------|---------|-------------|
| `test-local.sh` | Local platform testing | Quick validation |
| `test-all-architectures.sh` | Multi-architecture testing | Cross-platform validation |
| `test-mock-signing.sh` | Mock signing functionality testing | Development testing |
| `test-docker-build.sh` | Docker build testing | Build validation |
<!-- markdownlint-enable MD013 -->

### 🏗️ Infrastructure & Deployment

<!-- markdownlint-disable MD013 -->
| Script | Purpose | When to Use |
|--------|---------|-------------|
| `deploy-sigul-infrastructure.sh` | Deploy infrastructure stack | Test/dev environments |
| `run-integration-tests.sh` | End-to-end integration testing | CI/CD pipelines |
| `test-infrastructure.sh` | Infrastructure validation | Infrastructure testing |
<!-- markdownlint-enable MD013 -->

## 🔧 Core Infrastructure Scripts

### `sigul-init.sh` - Unified Initialization System

The **primary script** that replaced the previous separate
`sigul-server-init.sh` and `sigul-bridge-init.sh` scripts. This unified script
handles all sigul component initialization.

**Features:**

- Role-based initialization (`--role server|bridge|client`)
- Unified directory structure under `/var/sigul`
- Comprehensive secrets management
- Certificate discovery and validation
- NSS database management
- Database initialization (server role)
- Health checks and validation
- Service startup integration

**Usage:**

```bash
# Server initialization
./scripts/sigul-init.sh --role server

# Bridge initialization
./scripts/sigul-init.sh --role bridge

# Client initialization
./scripts/sigul-init.sh --role client

# With custom base directory
./scripts/sigul-init.sh --role server --base-dir /opt/sigul

# With debug logging
./scripts/sigul-init.sh --role server --debug

# Start service after initialization
./scripts/sigul-init.sh --role server --start-service
```

**Environment Variables:**

- `NSS_PASSWORD` - Custom NSS database password
- `SIGUL_ADMIN_PASSWORD` - Custom admin password (server role)
- `DEBUG` - Enable debug logging
- `SIGUL_BASE_DIR` - Custom base directory

### PKI Management Scripts

**`generate-complete-pki.sh`** - Creates comprehensive PKI infrastructure including:

- Root Certificate Authority (CA)
- Server certificates for sigul-server and sigul-bridge
- Client certificates and configuration
- Encrypted client PKI archive for workflows

**`generate-test-pki.sh`** - Wrapper script that calls the complete PKI
generation.

## 🧪 Testing Scripts

### Multi-Architecture Testing

**`test-all-architectures.sh`** - Tests both AMD64 and ARM64 builds with detailed
reporting.

**`test-local.sh`** - Platform-specific testing with auto-detection of local
architecture.

```bash
# Auto-detect platform and test
./scripts/test-local.sh

# Test specific platform
./scripts/test-local.sh --platform linux/arm64
./scripts/test-local.sh --platform linux/amd64
```

### Specialized Testing

**`test-mock-signing.sh`** - Validates mock signing functionality for development.

**`test-docker-build.sh`** - Comprehensive Docker build testing with network
resilience validation.

## 🏗️ Infrastructure Scripts

### Deployment and Integration

**`deploy-sigul-infrastructure.sh`** - Handles deployment of Sigul infrastructure
components for integration testing with improved permission handling.

**`run-integration-tests.sh`** - Runs integration tests against deployed Sigul
infrastructure.

**`test-infrastructure.sh`** - Simple infrastructure testing for the Docker stack.

## 🏆 Recommended Testing Workflow

### 1. During Development

```bash
# Quick local validation
./scripts/test-local.sh

# Test mock signing functionality
./scripts/test-mock-signing.sh
```

### 2. Before Committing

```bash
# Test all architectures
./scripts/test-all-architectures.sh

# Test Docker builds
./scripts/test-docker-build.sh
```

### 3. Infrastructure Testing

```bash
# Deploy and test infrastructure
./scripts/deploy-sigul-infrastructure.sh --verbose
./scripts/run-integration-tests.sh
```

### 4. Debugging Issues

```bash
# Test infrastructure components
./scripts/test-infrastructure.sh

# Debug specific builds
./scripts/test-docker-build.sh --verbose
```

## 🔧 Refactoring Improvements

The sigul initialization system incorporates these improvements:

### ✅ Unified Architecture

- **Single Script**: `sigul-init.sh` handles all components (server, bridge,
  client)
- **Consistent Directory Structure**: All files under `/var/sigul`
- **Role-Based Behavior**: Component-specific functionality based on `--role`
  parameter

### ✅ Enhanced Security

- **Consolidated Secrets**: All sensitive data in `/var/sigul/secrets/` with
  proper permissions
- **Secure Passwords**: Cryptographically secure password generation
- **Certificate Management**: Discovery, validation, and secure import
- **Permission Validation**: Comprehensive file and directory permission
  checking

### ✅ Improved Maintainability

- **Modular Functions**: Independent, testable functions
- **Comprehensive Logging**: Consistent logging with timestamps and component
  identification
- **Error Handling**: Robust error handling with meaningful exit codes
- **Environment Support**: Extensive environment variable configuration

### ✅ Production Ready

- **Health Checks**: Multi-level validation system
- **Service Integration**: Complete service startup and management
- **Container Optimization**: Docker-specific optimizations and health checks

## 🐳 Docker Integration

The unified script integrates into all container images:

### Dockerfile Integration

```dockerfile
# Copy unified initialization script
COPY scripts/sigul-init.sh /usr/local/bin/sigul-init.sh
RUN chmod +x /usr/local/bin/sigul-init.sh

# Default command - initialize and start service
CMD ["/usr/local/bin/sigul-init.sh", "--role", "server", \
    "--start-service"]
```

### Docker Compose Integration

```yaml
volumes:
  # Mount unified initialization script
    - ./scripts/sigul-init.sh:/usr/local/bin/sigul-init.sh:ro
```

### Health Checks

```dockerfile
# Health check using unified directory structure
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD test -f /var/sigul/pids/sigul_server.pid && \
        pgrep -f server >/dev/null || exit 1
```

## 📈 Script Consolidation

### Deprecated Scripts (Removed)

The following scripts have been **removed** as part of the refactoring:

- `sigul-server-init.sh` - Replaced by unified `sigul-init.sh --role server`
- `sigul-bridge-init.sh` - Replaced by unified `sigul-init.sh --role bridge`
- `test-minimal.sh` - Development debugging artifact

### Usage Guide

The unified script supports role-based initialization:

```bash
# Unified script with role parameter
./scripts/sigul-init.sh --role server
./scripts/sigul-init.sh --role bridge
./scripts/sigul-init.sh --role client
```

**Note**: Legacy migration functions no longer exist as they do not apply in
containerized environments where Docker volumes manage persistent data.

## 🚨 Troubleshooting

### Common Issues

**Initialization Failures:**

```bash
# Run with debug logging
./scripts/sigul-init.sh --role server --debug

# Check health status
./scripts/sigul-init.sh --role server --health-check
```

**Docker Build Issues:**

```bash
# Test builds with verbose output
./scripts/test-docker-build.sh --verbose

# Test specific architecture
./scripts/test-local.sh --platform linux/amd64
```

**Infrastructure Problems:**

```bash
# Test infrastructure stack
./scripts/test-infrastructure.sh

# Deploy with debug output
./scripts/deploy-sigul-infrastructure.sh --debug
```

### Directory Structure

The unified script creates this directory structure:

```text
/var/sigul/                    # Base directory
├── config/                    # Configuration files
├── logs/                      # Log files
│   ├── server/
│   ├── bridge/
│   └── client/
├── pids/                      # PID files
├── secrets/                   # Passwords, keys (700 perms)
│   ├── certificates/
│   ├── {role}_nss_password
└── server_admin_password  # Server role
├── nss/                       # NSS databases (700 perms)
│   ├── server/
│   ├── bridge/
│   └── client/
├── database/                  # SQLite files (server role)
├── gnupg/                     # GPG home directory
└── tmp/                       # Temporary files
```

## 📖 Further Reading

- [Refactoring Design Document](../REFACTOR_SERVER_INIT.md)
- [Phase Implementation Summaries](../PHASE*_IMPLEMENTATION_SUMMARY.md)
- [Docker BuildKit Documentation](https://docs.docker.com/build/buildkit/)
- [Multi-stage Builds](https://docs.docker.com/develop/dev-best-practices/)

## 🔗 Integration Examples

### GitHub Actions Workflow

```yaml
- name: Test Infrastructure
  run: |
    ./scripts/deploy-sigul-infrastructure.sh --verbose
    ./scripts/run-integration-tests.sh

- name: Test All Architectures
  run: ./scripts/test-all-architectures.sh
```

### Local Development

```bash
# Quick development cycle
./scripts/test-local.sh
./scripts/test-mock-signing.sh

# Full validation before commit
./scripts/test-all-architectures.sh
./scripts/test-docker-build.sh
```
