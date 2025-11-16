<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Phase 4 Quick Reference: Service Initialization Changes

## What Changed

### Before Phase 4

- Services used complex `sigul-init.sh` wrapper script
- Combined initialization, validation, and service startup
- Slow healthchecks (45-60 second intervals)
- Non-standard startup patterns

### After Phase 4

- Direct service invocation matching production
- Simplified entrypoints with minimal wrapper logic
- Fast healthchecks (10 second intervals)
- Production-aligned command lines

## Service Commands

### Bridge

```bash
# Production & Container (aligned):
/usr/sbin/sigul_bridge -v
```

### Server

```bash
# Production & Container (aligned):
/usr/sbin/sigul_server -c /etc/sigul/server.conf \
    --internal-log-dir=/var/log/sigul-default \
    --internal-pid-dir=/run/sigul-default \
    -v
```

## Rebuilding Containers

After Phase 4, containers must be rebuilt:

```bash
# Stop existing containers
docker-compose -f docker-compose.sigul.yml down

# Rebuild with new entrypoints
docker-compose -f docker-compose.sigul.yml build --no-cache

# Start services
docker-compose -f docker-compose.sigul.yml up -d

# Verify startup
docker logs sigul-bridge
docker logs sigul-server
```

## Validation

```bash
# Run Phase 4 validation
./scripts/validate-phase4-service-initialization.sh

# Expected: 16/16 tests passed
```

## Troubleshooting

### Service Won't Start

**Check entrypoint logs:**

```bash
docker logs sigul-bridge
docker logs sigul-server
```

**Common Issues:**

- Missing configuration: Ensure `/etc/sigul/bridge.conf` or `server.conf` exists
- Missing certificates: Run certificate generation first
- Bridge not available: Server waits 60s for bridge, check bridge health

### Verify Process Command Lines

```bash
# Bridge should show: /usr/sbin/sigul_bridge -v
docker exec sigul-bridge pgrep -af sigul_bridge

# Server should show production command with all flags
docker exec sigul-server pgrep -af sigul_server
```

## File Locations

- **Bridge Entrypoint:** `scripts/entrypoint-bridge.sh`
- **Server Entrypoint:** `scripts/entrypoint-server.sh`
- **Validation Script:** `scripts/validate-phase4-service-initialization.sh`
- **Complete Summary:** `PHASE4_COMPLETE.md`

## Next Steps

Proceed to Phase 5: Volume & Persistence Strategy

See `ALIGNMENT_PLAN.md` for details.
