<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Operations Guide

This guide covers day-to-day operations, monitoring, and maintenance of the production-aligned Sigul container stack.

---

## Table of Contents

- [Daily Operations](#daily-operations)
- [Monitoring](#monitoring)
- [Health Checks](#health-checks)
- [Common Tasks](#common-tasks)
- [Maintenance](#maintenance)
- [Incident Response](#incident-response)
- [Troubleshooting](#troubleshooting)
- [Performance Monitoring](#performance-monitoring)

---

## Daily Operations

### Service Status Check

Check the health of all services:

```bash
# Quick status check
docker-compose -f docker-compose.sigul.yml ps

# Detailed status with health
docker ps --filter "name=sigul" --format "table {{.Names}}\t{{.Status}}\t{{.Health}}"
```

**Expected output:**

```text
NAMES           STATUS                   HEALTH
sigul-bridge    Up 2 hours              healthy
sigul-server    Up 2 hours              healthy
```

### Log Review

Review recent logs for errors or warnings:

```bash
# View recent logs (last 50 lines)
docker-compose -f docker-compose.sigul.yml logs --tail=50

# Follow logs in real-time
docker-compose -f docker-compose.sigul.yml logs -f

# Bridge logs only
docker logs sigul-bridge --tail=50

# Server logs only
docker logs sigul-server --tail=50

# Search for errors
docker-compose -f docker-compose.sigul.yml logs | grep -i error
```

### Resource Usage Check

Monitor resource consumption:

```bash
# View resource usage
docker stats sigul-bridge sigul-server --no-stream

# Disk usage
docker system df

# Volume usage
docker system df -v | grep sigul
```

---

## Monitoring

### Container Health

The containers include built-in health checks that run every 10 seconds.

**Bridge Health Check:**

```bash
# Manual health check
docker exec sigul-bridge pgrep -f sigul_bridge
```

**Server Health Check:**

```bash
# Manual health check
docker exec sigul-server pgrep -f sigul_server
```

### Network Connectivity

Verify network connectivity between components:

```bash
# Run network verification
./scripts/verify-network.sh

# Manual check: Server to Bridge
docker exec sigul-server nc -zv sigul-bridge.example.org 44333

# Check bridge listening ports
docker exec sigul-bridge netstat -tlnp | grep -E '44333|44334'
```

### Database Health

Check database integrity:

```bash
# Database integrity check
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "PRAGMA integrity_check;"

# Database size
docker exec sigul-server du -sh /var/lib/sigul/server/sigul.db

# Table count
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db ".tables"
```

### Certificate Status

Monitor certificate expiration:

```bash
# Bridge certificate expiration
docker exec sigul-bridge certutil -L -n "sigul-bridge.example.org" -d sql:/etc/pki/sigul | grep "Not After"

# Server certificate expiration
docker exec sigul-server certutil -L -n "sigul-server.example.org" -d sql:/etc/pki/sigul | grep "Not After"

# List all certificates
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul
```

---

## Health Checks

### Automated Health Check Script

Run the comprehensive infrastructure test:

```bash
./scripts/test-infrastructure.sh health
```

### Manual Health Verification

**Step 1: Check Processes**

```bash
# Bridge process
docker exec sigul-bridge ps aux | grep sigul_bridge

# Server process
docker exec sigul-server ps aux | grep sigul_server
```

**Step 2: Check Network**

```bash
# Bridge listening
docker exec sigul-bridge netstat -tlnp | grep python

# Server connections
docker exec sigul-server netstat -tnp | grep 44333
```

**Step 3: Check Files**

```bash
# Configuration files
docker exec sigul-bridge test -f /etc/sigul/bridge.conf && echo "OK" || echo "MISSING"
docker exec sigul-server test -f /etc/sigul/server.conf && echo "OK" || echo "MISSING"

# Database
docker exec sigul-server test -f /var/lib/sigul/server/sigul.db && echo "OK" || echo "MISSING"

# GnuPG home
docker exec sigul-server test -d /var/lib/sigul/server/gnupg && echo "OK" || echo "MISSING"
```

---

## Common Tasks

### View Signing Keys

```bash
# List GPG keys
docker exec sigul-server gpg --homedir /var/lib/sigul/server/gnupg --list-keys

# List secret keys
docker exec sigul-server gpg --homedir /var/lib/sigul/server/gnupg --list-secret-keys

# Key details
docker exec sigul-server ls -la /var/lib/sigul/server/gnupg
```

### Check Database Content

```bash
# List users
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "SELECT * FROM users;"

# Count users
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "SELECT COUNT(*) FROM users;"

# Database schema
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db ".schema"

# Database statistics
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "SELECT name, COUNT(*) FROM sqlite_master GROUP BY type;"
```

### Restart Services

```bash
# Restart specific service
docker-compose -f docker-compose.sigul.yml restart sigul-bridge
docker-compose -f docker-compose.sigul.yml restart sigul-server

# Restart all services
docker-compose -f docker-compose.sigul.yml restart

# Graceful restart (stop then start)
docker-compose -f docker-compose.sigul.yml stop
docker-compose -f docker-compose.sigul.yml start
```

### View Configuration

```bash
# Bridge configuration
docker exec sigul-bridge cat /etc/sigul/bridge.conf

# Server configuration
docker exec sigul-server cat /etc/sigul/server.conf

# Docker Compose configuration
cat docker-compose.sigul.yml
```

### Rotate Certificates

```bash
# 1. Backup current certificates
./scripts/backup-volumes.sh

# 2. Stop services
docker-compose -f docker-compose.sigul.yml down

# 3. Remove certificate volumes
docker volume rm sigul_bridge_nss sigul_server_nss

# 4. Redeploy (generates new certificates)
./scripts/deploy-sigul-infrastructure.sh

# 5. Verify
./scripts/test-infrastructure.sh
```

---

## Maintenance

### Backup Procedures

**Daily Backup:**

```bash
# Run backup script
./scripts/backup-volumes.sh

# Verify backup created
ls -lh backups/

# Backup to remote location
rsync -av backups/ backup-server:/sigul-backups/
```

**Backup Verification:**

```bash
# List backup contents
tar -tzf backups/sigul_server_data-*.tar.gz | head -20

# Verify backup integrity
tar -tzf backups/sigul_server_data-*.tar.gz > /dev/null && echo "OK" || echo "CORRUPT"
```

### Restore Procedures

**Restore from Backup:**

```bash
# 1. Stop services
docker-compose -f docker-compose.sigul.yml down

# 2. List available backups
ls -lh backups/

# 3. Restore specific volume
./scripts/restore-volumes.sh sigul_server_data backups/sigul_server_data-TIMESTAMP.tar.gz

# 4. Restart services
docker-compose -f docker-compose.sigul.yml up -d

# 5. Verify
./scripts/test-infrastructure.sh
```

### Log Rotation

Container logs are managed by Docker's logging driver:

```bash
# Check log size
docker inspect sigul-bridge --format='{{.LogPath}}' | xargs ls -lh
docker inspect sigul-server --format='{{.LogPath}}' | xargs ls -lh

# Configure log rotation (add to docker-compose.yml)
# logging:
#   driver: "json-file"
#   options:
#     max-size: "10m"
#     max-file: "3"
```

### Cleanup

**Remove Old Backups:**

```bash
# Remove backups older than 30 days
find backups/ -name "*.tar.gz" -mtime +30 -delete

# Keep only last 10 backups
ls -t backups/*.tar.gz | tail -n +11 | xargs rm -f
```

**Docker Cleanup:**

```bash
# Remove unused images
docker image prune -a

# Remove unused volumes (careful!)
docker volume prune

# System cleanup
docker system prune -a --volumes
```

---

## Incident Response

### Service Crashed

**Diagnosis:**

```bash
# Check exit status
docker-compose -f docker-compose.sigul.yml ps

# View crash logs
docker logs sigul-bridge --tail 100
docker logs sigul-server --tail 100

# Check system resources
df -h
free -h
```

**Recovery:**

```bash
# Restart crashed service
docker-compose -f docker-compose.sigul.yml restart sigul-bridge
docker-compose -f docker-compose.sigul.yml restart sigul-server

# If restart fails, rebuild
docker-compose -f docker-compose.sigul.yml up -d --force-recreate sigul-server
```

### Database Corruption

**Diagnosis:**

```bash
# Check database integrity
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "PRAGMA integrity_check;"
```

**Recovery:**

```bash
# 1. Stop services
docker-compose -f docker-compose.sigul.yml down

# 2. Restore from latest backup
./scripts/restore-volumes.sh sigul_server_data backups/sigul_server_data-LATEST.tar.gz

# 3. Restart
docker-compose -f docker-compose.sigul.yml up -d

# 4. Verify
docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "PRAGMA integrity_check;"
```

### Certificate Expiry

**Warning Signs:**

- TLS handshake failures
- Connection refused errors
- Certificate validation errors in logs

**Recovery:**

```bash
# 1. Check expiration dates
docker exec sigul-bridge certutil -L -n "sigul-bridge.example.org" -d sql:/etc/pki/sigul | grep "Not After"
docker exec sigul-server certutil -L -n "sigul-server.example.org" -d sql:/etc/pki/sigul | grep "Not After"

# 2. Rotate certificates (see Rotate Certificates section)
# 3. Verify new certificates
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server
```

### Network Issues

**Diagnosis:**

```bash
# Check bridge is listening
docker exec sigul-bridge netstat -tlnp | grep -E '44333|44334'

# Check server can reach bridge
docker exec sigul-server nc -zv sigul-bridge.example.org 44333

# Check DNS resolution
docker exec sigul-server getent hosts sigul-bridge.example.org
docker exec sigul-bridge getent hosts sigul-server.example.org
```

**Recovery:**

```bash
# Restart Docker network
docker-compose -f docker-compose.sigul.yml down
docker-compose -f docker-compose.sigul.yml up -d

# Verify network
./scripts/verify-network.sh
```

### Disk Space Issues

**Diagnosis:**

```bash
# Check disk usage
df -h /var/lib/docker

# Check volume sizes
docker system df -v | grep sigul

# Check log sizes
docker inspect sigul-bridge --format='{{.LogPath}}' | xargs ls -lh
docker inspect sigul-server --format='{{.LogPath}}' | xargs ls -lh
```

**Recovery:**

```bash
# Clean up Docker
docker system prune -a --volumes

# Rotate logs
docker-compose -f docker-compose.sigul.yml logs --tail=0 > /dev/null

# Remove old backups
find backups/ -name "*.tar.gz" -mtime +30 -delete
```

---

## Troubleshooting

### Common Issues

#### "Container keeps restarting"

**Cause:** Configuration error, missing files, or resource constraints

**Solution:**

```bash
# Check logs
docker logs sigul-server --tail=100

# Check configuration
docker exec sigul-server cat /etc/sigul/server.conf

# Check resources
docker stats --no-stream
```

#### "Cannot connect to bridge"

**Cause:** Bridge not listening, network issues, or firewall

**Solution:**

```bash
# Verify bridge is listening
docker exec sigul-bridge netstat -tlnp | grep 44333

# Test connectivity
docker exec sigul-server nc -zv sigul-bridge.example.org 44333

# Check network
./scripts/verify-network.sh
```

#### "Certificate validation failed"

**Cause:** Certificate CN mismatch, expired certificate, or trust flags

**Solution:**

```bash
# Verify certificate details
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server

# Check certificate validity
docker exec sigul-bridge certutil -V -n "sigul-bridge.example.org" -u V -d sql:/etc/pki/sigul
```

#### "Database locked"

**Cause:** Multiple processes accessing database simultaneously

**Solution:**

```bash
# Check for multiple processes
docker exec sigul-server pgrep -a python

# Restart server
docker-compose -f docker-compose.sigul.yml restart sigul-server
```

---

## Performance Monitoring

### Baseline Performance

Run performance tests to establish baseline:

```bash
# Run performance test suite
./scripts/test-performance.sh

# Custom iteration count
ITERATIONS=20 ./scripts/test-performance.sh
```

### Performance Metrics

Monitor key performance indicators:

```bash
# Response time
time docker exec sigul-server nc -zv sigul-bridge.example.org 44333

# Database query time
time docker exec sigul-server sqlite3 /var/lib/sigul/server/sigul.db "SELECT COUNT(*) FROM users;"

# Certificate validation time
time docker exec sigul-bridge certutil -V -n "sigul-bridge.example.org" -u V -d sql:/etc/pki/sigul
```

### Resource Monitoring

```bash
# CPU and memory usage
docker stats sigul-bridge sigul-server --no-stream

# Disk I/O
docker stats sigul-bridge sigul-server --format "table {{.Name}}\t{{.BlockIO}}"

# Network I/O
docker stats sigul-bridge sigul-server --format "table {{.Name}}\t{{.NetIO}}"
```

---

## Operational Checklist

### Daily Checklist

- [ ] Check service status: `docker-compose -f docker-compose.sigul.yml ps`
- [ ] Review logs for errors: `docker-compose -f docker-compose.sigul.yml logs --tail=50`
- [ ] Monitor resource usage: `docker stats --no-stream`
- [ ] Check disk space: `df -h /var/lib/docker`

### Weekly Checklist

- [ ] Run full health check: `./scripts/test-infrastructure.sh`
- [ ] Backup volumes: `./scripts/backup-volumes.sh`
- [ ] Review certificate expiration dates
- [ ] Check backup integrity
- [ ] Review performance metrics

### Monthly Checklist

- [ ] Test restore procedure: `./scripts/restore-volumes.sh --help`
- [ ] Run performance tests: `./scripts/test-performance.sh`
- [ ] Clean up old backups: `find backups/ -mtime +30 -delete`
- [ ] Review and update documentation
- [ ] Check for software updates

---

## Emergency Contacts

For critical issues:

1. **Check documentation**: All PHASE*.md files and NETWORK_ARCHITECTURE.md
2. **Run diagnostics**: `./scripts/collect-sigul-diagnostics.sh`
3. **GitHub Issues**: <https://github.com/lf-releng/sigul-sign-docker/issues>
4. **Review validation**: Run all `./scripts/validate-phase*.sh` scripts

---

*For deployment procedures, see DEPLOYMENT_PRODUCTION_ALIGNED.md*
