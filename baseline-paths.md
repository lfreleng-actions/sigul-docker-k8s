<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Baseline Directory Structure

**Document Date:** 2025-01-26
**Purpose:** Document current directory structure before production alignment

## Current Container Paths (Pre-Alignment)

### Sigul Bridge Container

```
/opt/sigul/
├── config/          # Configuration files
├── nss/             # NSS database location
├── logs/            # Log files
└── data/            # Runtime data
```

### Sigul Server Container

```
/opt/sigul/
├── config/          # Configuration files
├── nss/             # NSS database location
├── logs/            # Log files
├── data/            # Runtime data
└── gnupg/           # GPG keyring location
```

## Target Production-Aligned Paths

### FHS-Compliant Structure (Target)

```
/etc/sigul/                    # Configuration files
├── bridge.conf
└── server.conf

/etc/pki/sigul/                # NSS certificate databases
├── bridge/
│   ├── cert9.db
│   ├── key4.db
│   └── pkcs11.txt
└── server/
    ├── cert9.db
    ├── key4.db
    └── pkcs11.txt

/var/lib/sigul/                # Persistent data
├── bridge/
└── server/
    ├── gnupg/                 # GPG keyring
    └── sigul.db               # Signing database

/var/log/sigul/                # Log files
├── bridge.log
└── server.log

/run/sigul/                    # Runtime files (tmpfs)
└── server/
    └── server.pid
```

## Volume Mapping Strategy

### Current Volumes (Pre-Alignment)

- `sigul_bridge_config` → `/opt/sigul/config`
- `sigul_bridge_nss` → `/opt/sigul/nss`
- `sigul_bridge_logs` → `/opt/sigul/logs`
- `sigul_bridge_data` → `/opt/sigul/data`
- `sigul_server_config` → `/opt/sigul/config`
- `sigul_server_nss` → `/opt/sigul/nss`
- `sigul_server_logs` → `/opt/sigul/logs`
- `sigul_server_data` → `/opt/sigul/data`

### Target Volume Mappings (Production-Aligned)

- `sigul_bridge_config` → `/etc/sigul` (config files only)
- `sigul_bridge_nss` → `/etc/pki/sigul/bridge` (NSS databases)
- `sigul_bridge_logs` → `/var/log/sigul/bridge` (logs)
- `sigul_bridge_data` → `/var/lib/sigul/bridge` (persistent data)
- `sigul_server_config` → `/etc/sigul` (config files only)
- `sigul_server_nss` → `/etc/pki/sigul/server` (NSS databases)
- `sigul_server_logs` → `/var/log/sigul/server` (logs)
- `sigul_server_data` → `/var/lib/sigul/server` (persistent data, GPG, DB)
- `sigul_server_run` → `/run/sigul/server` (runtime files)

## Migration Notes

1. **NSS Database Location Change:**
   - Old: `/opt/sigul/nss/`
   - New: `/etc/pki/sigul/{bridge,server}/`
   - Rationale: Aligns with FHS standard for PKI materials

2. **Configuration File Location Change:**
   - Old: `/opt/sigul/config/`
   - New: `/etc/sigul/`
   - Rationale: FHS standard for system configuration

3. **Data Directory Separation:**
   - Old: Single `/opt/sigul/data/` directory
   - New: Separate `/var/lib/sigul/{bridge,server}/` directories
   - Rationale: Better separation of concerns, matches production

4. **Log File Location Change:**
   - Old: `/opt/sigul/logs/`
   - New: `/var/log/sigul/{bridge,server}/`
   - Rationale: FHS standard for log files

5. **Runtime Files:**
   - New: `/run/sigul/server/` for PID files
   - Rationale: FHS standard for runtime data (tmpfs-backed)

## Configuration File Updates Required

All scripts and configuration templates must be updated to reference new paths:

- `Dockerfile.bridge`
- `Dockerfile.server`
- `docker-compose.sigul.yml`
- `scripts/sigul-init.sh`
- `scripts/deploy-sigul-infrastructure.sh`
- Configuration templates in `scripts/`
- PKI generation scripts in `pki/`

## Validation Checklist

- [ ] All volume mounts updated in docker-compose.sigul.yml
- [ ] All paths in Dockerfiles updated
- [ ] Configuration templates reference new paths
- [ ] Initialization scripts create correct directory structure
- [ ] Service startup commands reference correct config paths
- [ ] Log file paths updated in configuration
- [ ] NSS database paths updated in configuration
- [ ] GPG home directory path updated
- [ ] Database file path updated
- [ ] Runtime directory created and mounted

## Compatibility Notes

- NSS database format remains cert9.db (modern format) - no change
- GPG remains version 2.x - no change
- Python 3.x - no change
- Only paths are changing, not software versions
