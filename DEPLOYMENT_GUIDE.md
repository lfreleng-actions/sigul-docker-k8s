<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# NSS-Based Sigul Deployment Guide

## Overview

This guide provides step-by-step instructions for deploying the NSS-based Sigul infrastructure. The implementation uses a bridge-centric PKI architecture where the bridge component acts as the Certificate Authority, replacing the previous OpenSSL-based approach.

## Production-Aligned Deployment

For deployment aligned with production configuration patterns (AWS-based deployments), see:

- **[DEPLOYMENT_PRODUCTION_ALIGNED.md](DEPLOYMENT_PRODUCTION_ALIGNED.md)** - Complete production deployment guide
  - FHS-compliant directory structure
  - FQDN-based certificates with SANs
  - Modern cryptographic formats (cert9.db, TLS 1.2+)
  - Production-verified configuration patterns
  - Comprehensive troubleshooting and maintenance procedures

- **[OPERATIONS_GUIDE.md](OPERATIONS_GUIDE.md)** - Day-to-day operations
  - Daily operations and monitoring
  - Health checks and diagnostics
  - Common tasks and maintenance
  - Incident response procedures
  - Performance monitoring

- **[VALIDATION_CHECKLIST.md](VALIDATION_CHECKLIST.md)** - Validation checklist
  - Pre-deployment validation
  - Infrastructure validation
  - Certificate validation
  - Network and service validation
  - Production readiness checklist

- **[NETWORK_ARCHITECTURE.md](NETWORK_ARCHITECTURE.md)** - Network architecture reference
  - Correct connection flow (Server CONNECTS TO bridge)
  - Configuration evidence
  - Network verification commands
  - Troubleshooting guide

- **[ALIGNMENT_PLAN.md](ALIGNMENT_PLAN.md)** - Complete alignment plan
  - All 8 phases of production alignment
  - Phase completion documents (PHASE1-7_COMPLETE.md)
  - Detailed implementation steps

The production-aligned deployment includes:

- Direct service invocation (no wrapper scripts)
- Static IP assignment and FQDN-based hostnames
- Persistent volume strategy with backup/restore scripts
- Automated validation scripts for all phases
- Comprehensive integration and performance testing

## Prerequisites

### System Requirements

- **Docker**: Version 20.10 or higher
- **Docker Compose**: Version 2.0 or higher
- **Operating System**: Linux (tested on Ubuntu 20.04+, RHEL 8+, CentOS 8+)
- **Memory**: Minimum 4GB RAM (8GB recommended)
- **Storage**: Minimum 10GB free disk space
- **Network**: Bridge and server components need network connectivity

### Container Requirements

- **User Permissions**: Docker user must be in `docker` group
- **Volume Access**: Docker daemon must have access to mount volumes
- **Entropy Sources**: Access to `/dev/urandom` for key generation

## Quick Start

### 1. Clone and Prepare

```bash
git clone <repository-url>
cd sigul-sign-docker

# Verify all required files are present
ls -la scripts/sigul-init-nss-only.sh
ls -la scripts/validate-nss.sh
ls -la docker-compose.sigul.yml
```

### 2. Build Images

```bash
# Build all container images
docker compose -f docker-compose.sigul.yml build

# Verify images were built successfully
docker images | grep sigul-sign-docker
```

### 3. Start Services

```bash
# Start bridge first (creates CA)
docker compose -f docker-compose.sigul.yml up -d sigul-bridge

# Wait for bridge to become healthy (may take 60-120 seconds)
docker compose -f docker-compose.sigul.yml ps sigul-bridge

# Start server (inherits CA from bridge)
docker compose -f docker-compose.sigul.yml up -d sigul-server

# Start client for testing
docker compose -f docker-compose.sigul.yml up -d sigul-client-test
```

### 4. Verify Deployment

```bash
# Run certificate validation
./scripts/validate-nss.sh all

# Run integration test
./scripts/run-integration-test.sh
```

## Detailed Deployment

### Architecture Overview

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Sigul Bridge │    │   Sigul Server  │    │  Sigul Client   │
│  (Port 44334)  │    │                 │    │                 │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ NSS CA      │ │    │ │ Inherited   │ │    │ │ CA Cert     │ │
│ │ - CA Cert   │◄┼────┼►│ CA Cert+Key │ │    │ │ (Public)    │ │
│ │ - CA Key    │ │    │ │ - Server    │ │    │ │ - Client    │ │
│ │ - Bridge    │ │    │ │   Cert      │ │    │ │   Cert      │ │
│ │   Cert      │ │    │ └─────────────┘ │    │ └─────────────┘ │
│ └─────────────┘ │    └─────────────────┘    └─────────────────┘
└─────────────────┘
```

### Service Startup Sequence

1. **Bridge Initialization**
   - Creates NSS database
   - Generates self-signed CA certificate
   - Creates bridge service certificate
   - Exports CA materials for server

2. **Server Initialization**
   - Waits for bridge CA availability
   - Imports CA certificate and private key
   - Creates server service certificate
   - Enables client certificate management

3. **Client Initialization**
   - Imports CA certificate (public only)
   - Creates client certificate request
   - Receives signed client certificate

### Environment Variables

#### Global Settings

```bash
# Debug mode
DEBUG=true

# NSS password (auto-generated if not provided)
NSS_PASSWORD=auto_generated_ephemeral

# Service hostnames
SIGUL_BRIDGE_HOSTNAME=sigul-bridge
SIGUL_SERVER_HOSTNAME=sigul-server
```

#### Bridge Settings

```bash
# Bridge ports
SIGUL_BRIDGE_CLIENT_PORT=44334
SIGUL_BRIDGE_SERVER_PORT=44333

# Role identification
SIGUL_ROLE=bridge
```

#### Server Settings

```bash
# Admin credentials (auto-generated if not provided)
SIGUL_ADMIN_PASSWORD=auto_generated_ephemeral
SIGUL_ADMIN_USER=admin

# Role identification
SIGUL_ROLE=server
```

#### Client Settings

```bash
# Client configuration
SIGUL_CLIENT_USERNAME=admin
SIGUL_MOCK_MODE=false

# Role identification
SIGUL_ROLE=client
```

## Production Deployment

### Security Hardening

#### 1. NSS Database Security

```bash
# Enable FIPS mode for production
export NSS_FIPS=1

# Use strong passwords (generate with openssl)
NSS_PASSWORD=$(openssl rand -base64 32)
```

#### 2. Network Security

```yaml
# docker-compose.sigul.yml - Production network config
networks:
  sigul-network:
    driver: bridge
    internal: true  # Isolate from external networks
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/24
          gateway: 172.20.0.1
```

#### 3. Volume Permissions

```bash
# Ensure proper volume ownership
docker volume create sigul_server_data
docker volume create sigul_bridge_data
docker volume create sigul_client_data

# Set secure volume permissions
docker run --rm -v sigul_server_data:/data busybox chown -R 1000:1000 /data
```

### High Availability Setup

#### 1. Bridge Redundancy

```yaml
# Multiple bridge instances (load balanced)
services:
  sigul-bridge-1:
    extends: sigul-bridge
    container_name: sigul-bridge-1

  sigul-bridge-2:
    extends: sigul-bridge
    container_name: sigul-bridge-2

  bridge-loadbalancer:
    image: nginx:alpine
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
    ports:
      - "44334:44334"
```

#### 2. Database Persistence

```yaml
# External database for server
services:
  sigul-server:
    environment:
      DATABASE_URL: postgresql://sigul:password@postgres:5432/sigul
    depends_on:
      - postgres

  postgres:
    image: postgres:13
    environment:
      POSTGRES_USER: sigul
      POSTGRES_PASSWORD: secure_password
      POSTGRES_DB: sigul
    volumes:
      - postgres_data:/var/lib/postgresql/data
```

### Monitoring and Logging

#### 1. Health Checks

```yaml
# Enhanced health checks
services:
  sigul-bridge:
    healthcheck:
      test: |
        certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca >/dev/null 2>&1 &&
        nc -z localhost 44334
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
```

#### 2. Logging Configuration

```yaml
# Centralized logging
services:
  sigul-bridge:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
        labels: "service=bridge"
```

#### 3. Monitoring Stack

```yaml
# Add monitoring services
  prometheus:
    image: prom/prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin
    ports:
      - "3000:3000"
```

## Troubleshooting

### Common Issues

#### 1. Container Entropy Issues

**Symptoms**: NSS key generation fails with entropy errors
**Solution**: Mount entropy sources

```yaml
services:
  sigul-bridge:
    devices:
      - /dev/urandom:/dev/urandom
    volumes:
      - /dev/random:/dev/random:ro
```

#### 2. Service Startup Dependencies

**Symptoms**: Server starts before bridge CA is ready
**Solution**: Verify health check configuration

```bash
# Check service status
docker compose -f docker-compose.sigul.yml ps

# Check health check status
docker inspect sigul-bridge | jq '.[0].State.Health'
```

#### 3. Certificate Chain Validation

**Symptoms**: TLS handshake failures between components
**Solution**: Validate certificate setup

```bash
# Run certificate validation
docker exec sigul-bridge /usr/local/bin/validate-nss-certificates.sh all

# Check certificate chain
docker exec sigul-server certutil -d sql:/var/sigul/nss/server -V -n sigul-server-cert -u S
```

#### 4. Volume Permission Issues

**Symptoms**: Permission denied errors in shared volumes
**Solution**: Fix volume ownership

```bash
# Stop services
docker compose -f docker-compose.sigul.yml down

# Fix permissions
docker run --rm -v sigul_bridge_data:/data busybox chown -R 1000:1000 /data

# Restart services
docker compose -f docker-compose.sigul.yml up -d
```

### Diagnostic Commands

#### Container Status

```bash
# Check all container status
docker compose -f docker-compose.sigul.yml ps

# View container logs
docker logs sigul-bridge --tail=50
docker logs sigul-server --tail=50

# Execute commands in containers
docker exec -it sigul-bridge bash
docker exec -it sigul-server bash
```

#### Certificate Inspection

```bash
# List certificates in NSS database
docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L

# View certificate details
docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca

# Test certificate validation
docker exec sigul-bridge /usr/local/bin/validate-nss-certificates.sh bridge
```

#### Network Connectivity

```bash
# Test bridge port accessibility
docker exec sigul-client-test nc -z sigul-bridge 44334

# Test bridge-server communication
docker exec sigul-server nc -z sigul-bridge 44333

# Network inspection
docker network ls
docker network inspect sigul-sign-docker_sigul-network
```

### Recovery Procedures

#### 1. Certificate Recovery

```bash
# Stop all services
docker compose -f docker-compose.sigul.yml down

# Clean volumes (WARNING: destructive)
docker volume rm sigul-sign-docker_sigul_bridge_data
docker volume rm sigul-sign-docker_sigul_server_data

# Restart services (will regenerate certificates)
docker compose -f docker-compose.sigul.yml up -d
```

#### 2. Database Recovery

```bash
# Backup existing database
docker exec sigul-server sqlite3 /var/sigul/database/sigul.db ".dump" > sigul_backup.sql

# Restore from backup
cat sigul_backup.sql | docker exec -i sigul-server sqlite3 /var/sigul/database/sigul.db
```

## Maintenance

### Regular Tasks

#### 1. Certificate Monitoring

```bash
# Check certificate expiration
docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca | grep "Not After"

# Set up monitoring script
cat > check_cert_expiry.sh << 'EOF'
#!/bin/bash
expiry=$(docker exec sigul-bridge certutil -d sql:/var/sigul/nss/bridge -L -n sigul-ca | grep "Not After" | cut -d: -f2-)
echo "CA certificate expires: $expiry"
EOF
```

#### 2. Log Rotation

```bash
# Rotate container logs
docker system prune -f
docker container prune -f

# Clean old volumes
docker volume prune -f
```

#### 3. Security Updates

```bash
# Update base images
docker compose -f docker-compose.sigul.yml pull
docker compose -f docker-compose.sigul.yml build --no-cache

# Restart with updated images
docker compose -f docker-compose.sigul.yml down
docker compose -f docker-compose.sigul.yml up -d
```

### Backup Procedures

#### 1. NSS Database Backup

```bash
# Create backup directory
mkdir -p backups/$(date +%Y%m%d)

# Backup NSS databases
docker cp sigul-bridge:/var/sigul/nss/bridge backups/$(date +%Y%m%d)/
docker cp sigul-server:/var/sigul/nss/server backups/$(date +%Y%m%d)/

# Backup configuration
docker cp sigul-bridge:/var/sigul/config backups/$(date +%Y%m%d)/
```

#### 2. Database Backup

```bash
# Backup server database
docker exec sigul-server sqlite3 /var/sigul/database/sigul.db ".dump" > backups/$(date +%Y%m%d)/sigul.sql
```

#### 3. Secrets Backup

```bash
# Backup secrets (encrypted)
docker cp sigul-bridge:/var/sigul/secrets backups/$(date +%Y%m%d)/
gpg --symmetric --cipher-algo AES256 backups/$(date +%Y%m%d)/secrets
```

## Integration

### CI/CD Pipeline Integration

#### 1. Automated Testing

```yaml
# .github/workflows/sigul-test.yml
name: Sigul Integration Test
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build images
        run: docker compose -f docker-compose.sigul.yml build
      - name: Run integration test
        run: ./scripts/run-integration-test.sh --cleanup
```

#### 2. Production Deployment

```yaml
# Deploy to production
deploy:
  runs-on: ubuntu-latest
  needs: test
  if: github.ref == 'refs/heads/main'
  steps:
    - name: Deploy to production
      run: |
        ssh production-server 'cd /opt/sigul && git pull'
        ssh production-server 'cd /opt/sigul && docker compose -f docker-compose.sigul.yml up -d'
```

### External Integration

#### 1. API Integration

```bash
# Example client usage
docker exec sigul-client-test sigul list-users
docker exec sigul-client-test sigul sign-rpm /path/to/package.rpm
```

#### 2. Webhook Integration

```python
# webhook_listener.py
import requests
from flask import Flask, request

app = Flask(__name__)

@app.route('/webhook', methods=['POST'])
def handle_webhook():
    data = request.json
    # Process signing request
    result = sign_package(data['package_path'])
    return {'status': 'success', 'result': result}
```

## Performance Tuning

### Resource Optimization

#### 1. Memory Tuning

```yaml
# docker-compose.sigul.yml - Resource limits
services:
  sigul-bridge:
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M
```

#### 2. CPU Optimization

```yaml
services:
  sigul-server:
    deploy:
      resources:
        limits:
          cpus: '2.0'
        reservations:
          cpus: '1.0'
```

#### 3. I/O Optimization

```yaml
# Use local volumes for better performance
volumes:
  sigul_server_data:
    driver: local
    driver_opts:
      type: tmpfs
      device: tmpfs
      o: size=1g,uid=1000,gid=1000
```

## Support

### Getting Help

- **Documentation**: See `NSS_IMPLEMENTATION_GUIDE.md` for detailed technical information
- **Known Issues**: Check `KNOWN_ISSUES.md` for common problems and solutions
- **Integration Testing**: Use `./scripts/run-integration-test.sh` for validation
- **Certificate Validation**: Use `./scripts/validate-nss-certificates.sh` for debugging

### Reporting Issues

When reporting issues, include:

1. **Environment Details**:
   - Docker version: `docker --version`
   - Docker Compose version: `docker compose version`
   - Host OS and version

2. **Error Information**:
   - Complete error messages
   - Container logs: `docker logs <container>`
   - Service status: `docker compose ps`

3. **Reproduction Steps**:
   - Exact commands used
   - Configuration files
   - Environment variables

4. **Diagnostic Output**:

   ```bash
   # Run diagnostics
   ./scripts/validate-nss-certificates.sh all > diagnostics.log 2>&1
   ./scripts/run-integration-test.sh --debug >> diagnostics.log 2>&1
   ```

---

*Deployment Guide Version: 1.0*
*Last Updated: 2025-01-08*
*Compatible with: NSS-based Sigul Implementation v1.0*
