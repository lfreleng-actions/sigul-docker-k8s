<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Phase 6 Quick Reference: Network & DNS Configuration

## What Changed

Phase 6 implements production-aligned network and DNS configuration with FQDNs, static IPs, and verification scripts.

### Key Changes

- **Hostnames:** Now use FQDNs (sigul-bridge.example.org)
- **IP Addresses:** Static assignments (bridge: 172.20.0.2, server: 172.20.0.3)
- **Network Aliases:** Both FQDN and short names supported
- **Verification:** New scripts to validate DNS and network connectivity

## Network Configuration

### IP Addresses

| Component | IP Address | Hostname |
|-----------|------------|----------|
| Gateway | 172.20.0.1 | N/A |
| Bridge | 172.20.0.2 | sigul-bridge.example.org |
| Server | 172.20.0.3 | sigul-server.example.org |

### Ports

- **44333:** Server connection port (bridge)
- **44334:** Client connection port (bridge)

Both ports exposed to host.

## New Verification Scripts

### DNS Verification

```bash
# Verify bridge DNS
./scripts/verify-dns.sh bridge

# Verify server DNS
./scripts/verify-dns.sh server
```

**Checks:**

- Container hostname configuration
- Self-resolution
- Cross-resolution (server → bridge)
- Network aliases
- Static IP assignment

### Network Verification

```bash
./scripts/verify-network.sh
```

**Checks:**

- Containers running
- Bridge listening ports
- Server connectivity to bridge
- Established connections
- Docker network configuration
- Port forwarding

### Certificate-Hostname Alignment

```bash
# Verify bridge
./scripts/verify-cert-hostname-alignment.sh bridge

# Verify server
./scripts/verify-cert-hostname-alignment.sh server
```

**Checks:**

- Certificate exists
- CN matches hostname
- SAN includes hostname
- Certificate validity
- CA certificate present

## Applying Changes

Phase 6 requires container rebuild:

```bash
# 1. Stop services
docker-compose -f docker-compose.sigul.yml down

# 2. Rebuild images
docker-compose -f docker-compose.sigul.yml build

# 3. Start with new config
docker-compose -f docker-compose.sigul.yml up -d

# 4. Verify
./scripts/verify-dns.sh bridge
./scripts/verify-dns.sh server
./scripts/verify-network.sh
```

## Manual Verification

### Check Hostnames

```bash
docker exec sigul-bridge hostname
# Expected: sigul-bridge.example.org

docker exec sigul-server hostname
# Expected: sigul-server.example.org
```

### Check IPs

```bash
docker inspect sigul-bridge | grep IPAddress
# Expected: 172.20.0.2

docker inspect sigul-server | grep IPAddress
# Expected: 172.20.0.3
```

### Check DNS Resolution

```bash
# Server resolving bridge
docker exec sigul-server getent hosts sigul-bridge.example.org
# Expected: 172.20.0.2 sigul-bridge.example.org

# Bridge resolving itself
docker exec sigul-bridge getent hosts sigul-bridge.example.org
# Expected: 172.20.0.2 sigul-bridge.example.org
```

### Check Connectivity

```bash
# Server to bridge
docker exec sigul-server nc -zv sigul-bridge.example.org 44333
# Expected: succeeded

# Bridge listening
docker exec sigul-bridge netstat -tlnp | grep -E "(44333|44334)"
# Expected: Two LISTEN entries
```

## Troubleshooting

### Hostname Incorrect

**Problem:** Container hostname doesn't match FQDN

**Solution:**

```bash
# Rebuild containers
docker-compose -f docker-compose.sigul.yml down
docker-compose -f docker-compose.sigul.yml build
docker-compose -f docker-compose.sigul.yml up -d
```

### DNS Not Resolving

**Problem:** Server cannot resolve bridge FQDN

**Check:**

```bash
# View /etc/hosts
docker exec sigul-server cat /etc/hosts

# Check network aliases
docker inspect sigul-bridge | grep -A 10 Aliases
```

**Solution:** Verify network aliases in docker-compose.sigul.yml

### Wrong IP Address

**Problem:** Containers have dynamic IPs instead of static

**Check:**

```bash
docker-compose -f docker-compose.sigul.yml config | grep ipv4_address
```

**Solution:** Ensure static IPs configured in docker-compose.sigul.yml

### Connection Refused

**Problem:** Server cannot connect to bridge

**Check:**

```bash
# Bridge listening?
docker exec sigul-bridge netstat -tlnp | grep 44333

# Network connectivity?
docker exec sigul-server ping -c 1 172.20.0.2
```

## Validation

```bash
# Run Phase 6 validation
./scripts/validate-phase6-network-dns.sh

# Expected: Configuration tests pass
# Runtime tests require container rebuild
```

## File Locations

- **DNS Verification:** `scripts/verify-dns.sh`
- **Network Verification:** `scripts/verify-network.sh`
- **Cert Alignment:** `scripts/verify-cert-hostname-alignment.sh`
- **Phase 6 Validation:** `scripts/validate-phase6-network-dns.sh`
- **Complete Summary:** `PHASE6_COMPLETE.md`

## Next Steps

Proceed to Phase 7: Integration Testing

See `ALIGNMENT_PLAN.md` for details.

## Quick Commands

```bash
# Complete verification suite
./scripts/verify-dns.sh bridge
./scripts/verify-dns.sh server
./scripts/verify-network.sh
./scripts/verify-cert-hostname-alignment.sh bridge
./scripts/verify-cert-hostname-alignment.sh server

# Or run phase validation
./scripts/validate-phase6-network-dns.sh
```
