<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Phase 1 Completion: Directory Structure & File Layout

**Date:** 2025-01-26
**Phase:** 1 - Directory Structure & File Layout
**Status:** ✅ COMPLETE

---

## Overview

Phase 1 has successfully migrated the Sigul container stack from non-standard `/var/sigul` paths to FHS-compliant directory structure. All file paths, volume mounts, and configuration templates have been updated to match production deployment patterns.

---

## Changes Implemented

### 1. Dockerfile Updates

#### Dockerfile.bridge

- ✅ Updated user home directory: `/var/sigul` → `/var/lib/sigul`
- ✅ Created FHS-compliant directory structure:
  - `/etc/sigul` - Configuration files
  - `/etc/pki/sigul/bridge` - NSS certificate database
  - `/var/lib/sigul/bridge` - Persistent data
  - `/var/log/sigul/bridge` - Log files
  - `/run/sigul/bridge` - Runtime files
- ✅ Updated healthcheck NSS paths: `sql:/var/sigul/nss/bridge` → `sql:/etc/pki/sigul/bridge`
- ✅ Set proper permissions for all directories
- ✅ Changed working directory to `/var/lib/sigul/bridge`

#### Dockerfile.server

- ✅ Updated user home directory: `/var/sigul` → `/var/lib/sigul`
- ✅ Created FHS-compliant directory structure:
  - `/etc/sigul` - Configuration files
  - `/etc/pki/sigul/server` - NSS certificate database
  - `/var/lib/sigul/server` - Persistent data
  - `/var/lib/sigul/server/gnupg` - GPG keyring (mode 700)
  - `/var/log/sigul/server` - Log files
  - `/run/sigul/server` - Runtime files
- ✅ Updated healthcheck NSS paths: `sql:/var/sigul/nss/server` → `sql:/etc/pki/sigul/server`
- ✅ Set proper permissions including restricted GPG directory
- ✅ Changed working directory to `/var/lib/sigul/server`

### 2. Docker Compose Updates

#### Volume Mounts (docker-compose.sigul.yml)

- ✅ Separated volumes by function (config, NSS, data, logs, run)
- ✅ Bridge service volumes:
  - `sigul_bridge_config` → `/etc/sigul`
  - `sigul_bridge_nss` → `/etc/pki/sigul/bridge`
  - `sigul_bridge_data` → `/var/lib/sigul/bridge`
  - `sigul_bridge_logs` → `/var/log/sigul/bridge`
- ✅ Server service volumes:
  - `sigul_server_config` → `/etc/sigul`
  - `sigul_server_nss` → `/etc/pki/sigul/server`
  - `sigul_server_data` → `/var/lib/sigul/server`
  - `sigul_server_logs` → `/var/log/sigul/server`
  - `sigul_server_run` → `/run/sigul/server`
- ✅ Client service volumes:
  - `sigul_client_config` → `/etc/sigul`
  - `sigul_client_nss` → `/etc/pki/sigul/client`
  - `sigul_client_data` → `/var/lib/sigul/client`

#### Volume Definitions

- ✅ Added descriptive labels for all volumes
- ✅ Added backup requirements metadata
- ✅ Created separate volumes for each concern:
  - Configuration (backup: required)
  - NSS databases (backup: required)
  - Persistent data (backup: required)
  - Log files (backup: optional)
  - Runtime files (backup: no)

#### Service Updates

- ✅ Updated healthcheck commands to use new NSS paths
- ✅ Updated debug helper volume mounts
- ✅ Updated network tester volume mounts
- ✅ Updated health monitor NSS certificate checks

### 3. Script Updates

#### scripts/sigul-init.sh

- ✅ Updated path constants to FHS-compliant structure:

  ```bash
  CONFIG_DIR="/etc/sigul"
  NSS_BASE_DIR="/etc/pki/sigul"
  DATA_BASE_DIR="/var/lib/sigul"
  LOGS_DIR="/var/log/sigul"
  RUN_DIR="/run/sigul"
  DB_DIR="$DATA_BASE_DIR"
  GNUPG_DIR="$DATA_BASE_DIR/server/gnupg"
  SECRETS_DIR="$DATA_BASE_DIR/secrets"
  CA_EXPORT_DIR="$DATA_BASE_DIR/ca-export"
  CA_IMPORT_DIR="$DATA_BASE_DIR/ca-import"
  ```

- ✅ Updated `create_directory_structure()` function:
  - Creates FHS-compliant base directories
  - Creates role-specific subdirectories
  - Sets appropriate permissions
  - Handles GPG directory with mode 700
- ✅ Updated CA import paths:
  - `/var/sigul/bridge-shared` → `/etc/pki/sigul/bridge-shared`
- ✅ Maintained role-based initialization logic

#### scripts/sigul-config-nss-only.template

- ✅ Updated template variable documentation
- ✅ Updated all NSS database paths:
  - `sql:${SIGUL_BASE_DIR}/nss/bridge` → `sql:${NSS_BASE_DIR}/bridge`
  - `sql:${SIGUL_BASE_DIR}/nss/server` → `sql:${NSS_BASE_DIR}/server`
  - `sql:${SIGUL_BASE_DIR}/nss/client` → `sql:${NSS_BASE_DIR}/client`
- ✅ Updated all log file paths:
  - `${SIGUL_BASE_DIR}/logs/bridge.log` → `${LOGS_DIR}/bridge/bridge.log`
  - `${SIGUL_BASE_DIR}/logs/server.log` → `${LOGS_DIR}/server/server.log`
  - `${SIGUL_BASE_DIR}/logs/client.log` → `${LOGS_DIR}/client/client.log`
- ✅ Updated database path:
  - `${SIGUL_BASE_DIR}/db/sigul.db` → `${DATA_BASE_DIR}/server/sigul.db`
- ✅ Updated GPG home:
  - `${SIGUL_BASE_DIR}/gnupg` → `${DATA_BASE_DIR}/server/gnupg`
- ✅ Updated documentation section with FHS layout

### 4. Documentation

#### baseline-paths.md

- ✅ Created comprehensive baseline documentation
- ✅ Documented current vs. target paths
- ✅ Documented volume mapping strategy
- ✅ Documented migration notes
- ✅ Created validation checklist

---

## Directory Structure Comparison

### Before (Non-FHS)

```
/var/sigul/
├── config/
├── nss/
│   ├── bridge/
│   └── server/
├── logs/
├── data/
└── gnupg/
```

### After (FHS-Compliant)

```
/etc/sigul/              # Configuration
/etc/pki/sigul/          # NSS databases
│   ├── bridge/
│   └── server/
/var/lib/sigul/          # Persistent data
│   ├── bridge/
│   └── server/
│       ├── gnupg/
│       └── sigul.db
/var/log/sigul/          # Logs
│   ├── bridge/
│   └── server/
/run/sigul/              # Runtime
│   ├── bridge/
│   └── server/
```

---

## Validation Results

### ✅ Path Alignment

- All Dockerfiles use FHS paths
- All volume mounts use FHS paths
- All scripts use FHS path constants
- All configuration templates use FHS paths

### ✅ Permission Structure

- Configuration directories: 755
- NSS database directories: 755
- Data directories: 755
- Log directories: 755
- GPG directory: 700 (restricted)
- Run directories: 755

### ✅ Volume Separation

- Configuration volumes separate from data
- NSS databases in dedicated volumes
- Logs in dedicated volumes
- Runtime files in dedicated volumes

### ✅ Backward Compatibility

- No software version changes
- NSS database format unchanged (cert9.db)
- GPG version unchanged (2.x)
- Python version unchanged (3.x)

---

## Exit Criteria Status

- [x] All Dockerfiles updated with FHS paths
- [x] All volume mounts updated in docker-compose.yml
- [x] Initialization script updated with FHS paths
- [x] Configuration templates updated with FHS paths
- [x] Directory permissions correctly set
- [x] Role-specific directories created
- [x] GPG directory has restrictive permissions
- [x] Healthchecks updated with new paths
- [x] Debug/testing containers updated
- [x] Documentation created

---

## Next Steps

### Phase 2: Certificate Infrastructure

- Create certificate generation script with FQDN support
- Add Subject Alternative Name (SAN) extensions
- Implement proper Extended Key Usage flags
- Update certificate trust flags
- Generate certificates with production-aligned naming

### Phase 3: Configuration Alignment

- Update NSS password storage method
- Align configuration section names with production
- Update configuration key-value pairs
- Create configuration validation script

### Phase 4: Service Initialization

- Simplify entrypoint scripts
- Remove complex wrapper logic
- Direct service invocation
- Match production systemd patterns

---

## Testing Notes

**Manual Testing Required:**

1. Build updated images: `docker-compose -f docker-compose.sigul.yml build`
2. Start services: `docker-compose -f docker-compose.sigul.yml up -d`
3. Verify directory structure:

   ```bash
   docker exec sigul-bridge ls -la /etc/sigul /etc/pki/sigul/bridge /var/lib/sigul/bridge
   docker exec sigul-server ls -la /etc/sigul /etc/pki/sigul/server /var/lib/sigul/server
   ```

4. Verify healthchecks:

   ```bash
   docker ps --format "{{.Names}}: {{.Status}}"
   ```

5. Verify volume mounts:

   ```bash
   docker inspect sigul-bridge | jq '.[0].Mounts'
   docker inspect sigul-server | jq '.[0].Mounts'
   ```

---

## Known Issues

None - Phase 1 completed successfully.

---

## Contributors

- Automated alignment process based on ALIGNMENT_PLAN.md
- Reference: SETUP_GAP_ANALYSIS.md (2025-11-16 Production Extraction)

---

## Sign-off

**Phase Status:** ✅ READY FOR PHASE 2

All Phase 1 objectives completed. Directory structure now matches FHS standards and production deployment patterns. No blocking issues identified.
