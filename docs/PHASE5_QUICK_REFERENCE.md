<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Phase 5 Quick Reference: Volume & Persistence Strategy

## What Changed

Phase 5 adds comprehensive backup and restore capabilities for Sigul volumes.

### New Scripts

- `scripts/backup-volumes.sh` - Create timestamped backups
- `scripts/restore-volumes.sh` - Restore from backups
- `scripts/validate-phase5-volume-persistence.sh` - Validate implementation

## Backup Operations

### Backup Critical Volumes (Default)

```bash
./scripts/backup-volumes.sh
```

Backs up:

- `sigul_server_data` (database + GnuPG keys) - CRITICAL
- `sigul_server_nss` (server certificates) - HIGH
- `sigul_bridge_nss` (bridge certificates) - HIGH

### Backup All Volumes

```bash
./scripts/backup-volumes.sh --all
```

Includes logs and configuration volumes.

### Custom Backup Directory

```bash
./scripts/backup-volumes.sh --backup-dir /mnt/backups
```

## Restore Operations

### Restore Single Volume

```bash
# Stop services first
docker-compose -f docker-compose.sigul.yml down

# Restore
./scripts/restore-volumes.sh sigul_server_data \
    backups/sigul_server_data-20250116-120000.tar.gz

# Start services
docker-compose -f docker-compose.sigul.yml up -d
```

### Restore All Volumes

```bash
# Stop services first
docker-compose -f docker-compose.sigul.yml down

# Restore all from timestamp
./scripts/restore-volumes.sh --restore-all 20250116-120000

# Start services
docker-compose -f docker-compose.sigul.yml up -d
```

### Force Mode (Skip Confirmations)

```bash
./scripts/restore-volumes.sh --force sigul_server_data backup.tar.gz
```

**Warning:** Use with caution! Skips safety confirmations.

## Backup Priority Levels

| Priority | Volumes | Backup Frequency |
|----------|---------|------------------|
| CRITICAL | `sigul_server_data` | Before changes, daily |
| HIGH | `sigul_server_nss`, `sigul_bridge_nss` | Weekly |
| MEDIUM | `sigul_server_logs` | Monthly |
| LOW | Bridge logs, runtime | As needed |

## Best Practices

### Before Maintenance

```bash
# 1. Create backup
./scripts/backup-volumes.sh --all

# 2. Verify backup
ls -lh backups/
cat backups/backup-manifest-*.txt

# 3. Proceed with maintenance
```

### Scheduled Backups

Add to crontab:

```bash
# Daily critical backups at 2 AM
0 2 * * * cd /path/to/sigul && ./scripts/backup-volumes.sh

# Weekly full backups at 3 AM Sunday
0 3 * * 0 cd /path/to/sigul && ./scripts/backup-volumes.sh --all
```

### Disaster Recovery

```bash
# 1. Stop services
docker-compose -f docker-compose.sigul.yml down

# 2. Restore all volumes
./scripts/restore-volumes.sh --restore-all <timestamp>

# 3. Start services
docker-compose -f docker-compose.sigul.yml up -d

# 4. Verify
docker ps
docker logs sigul-server
docker logs sigul-bridge
```

## Validation

```bash
# Run Phase 5 validation
./scripts/validate-phase5-volume-persistence.sh

# Expected: 18+ tests passed
```

## Backup Output

```
backups/
├── sigul_server_data-20250116-120000.tar.gz
├── sigul_server_nss-20250116-120000.tar.gz
├── sigul_bridge_nss-20250116-120000.tar.gz
└── backup-manifest-20250116-120000.txt
```

## Troubleshooting

### "Volume does not exist"

- Normal if services haven't created volumes yet
- Deploy services first: `docker-compose -f docker-compose.sigul.yml up -d`

### "Services are still running"

- Restore requires stopped services to prevent corruption
- Stop first: `docker-compose -f docker-compose.sigul.yml down`

### "Backup file not found"

- Verify backup path is correct
- Check: `ls -lh backups/`

## File Locations

- **Backup Script:** `scripts/backup-volumes.sh`
- **Restore Script:** `scripts/restore-volumes.sh`
- **Validation:** `scripts/validate-phase5-volume-persistence.sh`
- **Complete Summary:** `PHASE5_COMPLETE.md`

## Next Steps

Proceed to Phase 6: Network & DNS Configuration

See `ALIGNMENT_PLAN.md` for details.
