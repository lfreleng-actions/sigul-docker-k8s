<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Stack Setup Gap Analysis

**Analysis Date:** 2025-01-26 (Updated: 2025-11-16 with production extraction data)
**Production Reference:** AWS servers (aws-us-west-2-lfit-sigul-bridge-1, aws-us-west-2-lfit-sigul-server-1)
**Production Data Extraction:** 2025-11-16 (samples/bridge and samples/server directories)
**Containerized Implementation:** sigul-sign-docker repository
**Goal:** Modern containerized Sigul deployment using current technologies

---

## Executive Summary

This document provides a detailed gap analysis between the **working production Sigul deployment** on AWS servers and the **modernized containerized Sigul stack** under development. The analysis identifies critical **architectural, configuration, and implementation patterns** from production that must be replicated in the containerized environment, while explicitly supporting modernization efforts.

**Production Data Source:** Comprehensive configuration extraction performed on 2025-11-16 from both bridge and server hosts. Full extraction outputs available in `samples/sigul-production-data-*/` directories containing system info, configurations, certificates, database schema, GnuPG setup, systemd services, network configuration, NSS details, permissions, logging, processes, and source code analysis.

**IMPORTANT - Components Confirmed Out of Scope (Verified by Production Extraction):**

- **RabbitMQ**: Present on production hosts but NOT used by Sigul (verified: no references in configs, source code analysis shows no AMQP imports or usage)
- **LDAP/OpenLDAP**: DNS entries present but NOT integrated with Sigul (verified: no config references, no LDAP authentication code)
- **Koji/FAS**: Empty `[koji]` sections in production bridge configs, NOT actively used (verified by extraction)

**Production Configuration Confirmed Details:**

- **Sigul Version:** sigul-0.207-1.el7.x86_64 and sigul-server-0.207-1.el7.x86_64
- **Python Version:** Python 2.7.5 (production uses legacy Python 2)
- **NSS Database Format:** Legacy format (cert8.db, key3.db, secmod.db) - will modernize to cert9.db
- **Certificate Authority:** External EasyRSA CA with FQDN-based CNs and SANs
- **Config Format:** Both colon (`:`) and equals (`=`) separators work (verified by ConfigParser test)
- **Service Startup:** Direct invocation via systemd without wrapper scripts

### Analysis Philosophy

**What Matters:**

- Configuration structure and file layouts
- Directory paths and naming conventions
- Certificate trust relationships and PKI architecture
- Network communication patterns
- Database schema and storage locations

**What Doesn't Matter (Modernization Targets):**

- Python 2 vs Python 3 (containers will use Python 3)
- Legacy NSS format vs modern format (containers will use modern cert9.db)
- GPG 1.x vs GPG 2.x (containers will use current GPG)
- Old package versions (containers will use current packages)
- SELinux specific contexts (Docker has different security model)

### Critical Configuration Gaps (Verified by Production Extraction 2025-11-16)

The following gaps are **confirmed blockers** based on actual production data extraction from both bridge and server hosts:

1. **Directory Structure Misalignment**: Complete mismatch between production paths (`/etc/sigul`, `/etc/pki/sigul`, `/var/lib/sigul`) and container paths (`/var/sigul/*`)
   - **Verified**: Production uses `/etc/sigul/` for configs, `/etc/pki/sigul/` for NSS DB, `/var/lib/sigul/` for data
   - **Container Issue**: Uses `/var/sigul/config/`, `/var/sigul/nss/<component>/`, `/var/sigul/database/`

2. **NSS Password Storage Method**: Production stores password in config files, containers use separate password file
   - **Verified**: Production has `nss-password: <plaintext>` directly in config files
   - **Container Issue**: Uses `/var/sigul/secrets/nss-password` file (may not be found)

3. **Certificate Management Approach**: Production uses external CA with FQDN-based certificates; containers generate simple self-signed certs
   - **Verified**: All production certs have CN=FQDN, SAN=DNS:FQDN, both Server+Client EKU
   - **Container Issue**: Simple names without SANs, may fail TLS hostname validation

4. **Service Startup Patterns**: Production uses direct command invocation; containers use complex initialization scripts
   - **Verified**: Bridge uses `/usr/sbin/sigul_bridge -v` (no config path), Server uses explicit `-c` flag
   - **Container Issue**: Complex wrapper scripts may interfere with proper startup

5. **Network Port Binding**: Production bridge listens on 0.0.0.0 (all interfaces); server connects outbound
   - **Verified**: Bridge binds `0.0.0.0:44333` and `0.0.0.0:44334`, server has no listening ports
   - **Container Issue**: Need to verify container networking allows server→bridge connection

6. **Multi-Bridge Support**: Production server handles multiple bridge connections simultaneously
   - **Verified**: Three separate server configs (dent, lfit, odpi), each with own log/PID directories
   - **Container Issue**: Only supports single bridge connection

**Most Critical Issues to Fix First:**

1. Use standard FHS paths in containers (`/etc/sigul`, `/etc/pki/sigul`, `/var/lib/sigul`)
2. Store NSS password in config files (match production pattern)
3. Generate certificates with FQDN CNs and SANs matching hostname resolution
4. Simplify service startup to match production (no wrapper scripts)

---

## 1. Directory Structure and File Layout

**Note:** While production uses legacy file formats (cert8.db, Python 2, GPG 1.x), the critical issue is **where** files are located and **how** they're organized, not their internal format. Modern replacements should maintain the same path structure.

### 1.1 Production Setup (AWS - WORKING)

```
/etc/sigul/
├── bridge.conf                              # Bridge configuration
├── client.conf                              # Client configuration (template)
├── base.conf                                # Base server configuration
├── server-bridge-*.conf                     # Per-bridge server configurations
└── (3 different bridge-specific configs)

/etc/pki/sigul/
├── cert8.db                                 # Legacy NSS certificate database (verified in extraction)
├── key3.db                                  # Legacy NSS key database (verified in extraction)
├── secmod.db                                # Legacy NSS security module database (verified in extraction)
├── nss-password.txt                         # Plain text NSS password (NOT FOUND - password stored in configs)
</parameter>
└── *.p12                                    # PKCS#12 certificate bundles
    ├── aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org.p12
    ├── aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org.p12
    ├── sigul-bridge-us-west-2.linuxfoundation.org.p12
    └── (multiple client .p12 files on bridge)

/var/lib/sigul/
├── server.sqlite                            # Server database (verified: 12K size on production)
└── gnupg/                                   # GPG keyring directory (verified on server, absent on bridge)
```

**Key Characteristics (Verified from Production Extraction):**

- Configuration files in `/etc/sigul/` (ownership: `sigul:sigul`, mode: `600` for server configs, `644` for client.conf)
- **Shared NSS database** at `/etc/pki/sigul/` (bridge and server can share on same host)
- Legacy NSS format (cert8.db, key3.db, secmod.db) - confirmed in production
- Certificates distributed as PKCS#12 (`.p12`) files - referenced but actual files not captured in extraction
- Simple, flat structure following FHS conventions
- **NSS password stored directly in config files**, NOT in separate nss-password.txt file
- SELinux contexts: `system_u:object_r:sigul_conf_t:s0` for configs
- Certificate nicknames match FQDNs (e.g., `aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org`)

### 1.2 Containerized Setup (CURRENT - NOT WORKING)

```
/var/sigul/
├── config/
│   ├── bridge.conf                          # Generated bridge config
│   ├── server.conf                          # Generated server config
│   └── client.conf                          # Generated client config
├── nss/
│   ├── bridge/
│   │   ├── cert9.db                         # Modern NSS certificate database
│   │   ├── key4.db                          # Modern NSS key database
│   │   └── pkcs11.txt                       # Modern NSS PKCS#11 config
│   ├── server/
│   │   ├── cert9.db
│   │   ├── key4.db
│   │   └── pkcs11.txt
│   └── client/
│       ├── cert9.db
│       ├── key4.db
│       └── pkcs11.txt
├── secrets/
│   └── nss-password                         # Password file (no extension)
├── database/
│   └── server.sqlite                        # Server database (WRONG LOCATION)
├── ca-export/                               # Bridge CA export directory
│   └── bridge-ca.crt
├── ca-import/                               # Component CA import directory
├── logs/
└── gnupg/                                   # GPG keyring (WRONG LOCATION)

/var/lib/sigul/                              # May or may not exist
├── server.sqlite                            # Correct location (if used)
└── gnupg/                                   # Correct location (if used)
```

**Key Characteristics:**

- Everything under `/var/sigul/`
- **Separate NSS databases** per component (`/var/sigul/nss/<component>/`)
- Modern NSS format (cert9.db, key4.db, pkcs11.txt)
- On-the-fly certificate generation (no PKCS#12 workflow)
- Complex nested structure
- Password file without extension
- Database location inconsistency (generated configs vs templates)

### 1.3 Gap Analysis: Directory Structure

| Aspect | Production | Container | Impact |
|--------|-----------|-----------|--------|
| **Config Location** | `/etc/sigul/` | `/var/sigul/config/` | Path mismatch may prevent config loading |
| **NSS Location** | `/etc/pki/sigul/` (shared) | `/var/sigul/nss/<component>/` (isolated) | Certificate sharing broken |
| **Database Location** | `/var/lib/sigul/server.sqlite` | `/var/sigul/database/server.sqlite` OR `/var/lib/sigul/server.sqlite` | Inconsistent, may fail to find DB |
| **GnuPG Location** | `/var/lib/sigul/gnupg` | `/var/sigul/gnupg` OR `/var/lib/sigul/gnupg` | Inconsistent, GPG operations may fail |
| **NSS Sharing** | Single shared DB for bridge/server | Separate DBs per component | Certificate trust chain issues |
| **Password File** | `nss-password.txt` | `nss-password` (no extension) | May not be found by hardcoded paths |

**Critical Issue:** The production setup uses standard FHS paths (`/etc`, `/var/lib`) which Sigul expects by default. The containerized approach uses non-standard paths (`/var/sigul/*`), requiring explicit configuration overrides and complex volume mounting that may not work correctly.

**Modernization Path:** Keep standard FHS paths (`/etc/sigul`, `/etc/pki/sigul`, `/var/lib/sigul`) in containers. Modern NSS (cert9.db) and Python 3 can work with these paths - the path structure is what matters, not the file formats.

---

## 2. NSS Database Format and Location

### 2.1 Production NSS Database Location

Production systems store NSS databases at:

```bash
# /etc/pki/sigul/ - Standard FHS location for PKI materials
cert8.db    # Legacy format (verified in extraction: 65536 bytes on bridge, 32768 bytes on server)
key3.db     # Legacy format (verified in extraction: 16384 bytes on both hosts)
secmod.db   # Legacy format (verified in extraction: 520 bytes on both hosts)
```

**Key Pattern (Verified from Production Extraction):**

- Single shared location: `/etc/pki/sigul/`
- Both bridge and server can access same NSS database on same host
- Standard FHS path for certificate/key storage
- Simple, predictable location
- **Bridge has 6 certificates** (including easyrsa CA, server cert, bridge cert, 3 Jenkins client certs)
- **Server has 3 certificates** (including easyrsa CA, server cert)
- CA certificate nickname: `easyrsa` with trust flags `CT,,` (trusted CA)
- Component certificates have trust flags `u,u,u` (user cert)

### 2.2 Containerized NSS Database Location

Container deployment uses:

```bash
# /var/sigul/nss/<component>/ - Non-standard location
/var/sigul/nss/bridge/cert9.db    # Modern format
/var/sigul/nss/server/cert9.db    # Modern format
/var/sigul/nss/client/cert9.db    # Modern format
```

**Key Pattern:**

- Isolated per-component: `/var/sigul/nss/<component>/`
- Requires complex volume mounting for certificate sharing
- Non-standard path requires explicit configuration
- Modern format (appropriate for new deployment)

### 2.3 Gap Analysis: NSS Database

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **Location** | `/etc/pki/sigul/` (standard FHS) | `/var/sigul/nss/<component>/` (non-standard) | **Config override needed** |
| **Sharing Model** | Single shared database | Separate per component | **Trust chain complexity** |
| **Path Convention** | Standard system location | Custom application path | **May cause lookup failures** |
| **Format** | cert8.db (legacy, can be upgraded) | cert9.db (modern, appropriate) | Format is fine, location is the issue |

**Critical Issue:** The **location** `/var/sigul/nss/<component>/` is non-standard. Sigul may have default paths compiled in or configuration may not properly override the default `/etc/pki/sigul/` location.

**Modernization Path:**

- **Option 1 (Recommended):** Use `/etc/pki/sigul/` in containers with modern cert9.db format
- **Option 2:** Keep custom paths but ensure all configuration properly overrides defaults
- Modern NSS (cert9.db) works fine - the location matters more than the format

---

## 3. Configuration File Format

### 3.1 Production Configuration Format

**Bridge Configuration** (`/etc/sigul/bridge.conf` - ACTUAL PRODUCTION CONFIG):

```ini
# MANAGED BY PUPPET

[bridge]
bridge-cert-nickname: sigul-bridge-us-west-2.linuxfoundation.org
client-listen-port: 44334
server-listen-port: 44333

[koji]

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: /etc/pki/sigul
nss-password: uFMLuCUpppkfV+GLqjv8W7ptCoV3z8li
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

**Production Notes (Verified from Extraction):**

- `[koji]` section is present but **completely empty** - confirms Koji integration is NOT used
- Uses colon (`:`) separator format throughout (ConfigParser test confirms both `:` and `=` work)
- NSS password is stored **directly in config file** as `nss-password: <plaintext>`, NOT in separate password file
- TLS version explicitly constrained to TLS 1.2 (both min and max set to `tls1.2`)
- Bridge config stored at `/etc/sigul/bridge.conf` with ownership `sigul:sigul` and permissions `600`

**Server Configuration** (`/etc/sigul/server-bridge-aws-us-west-2-lfit-sigul-bridge-1.conf` - ACTUAL PRODUCTION CONFIG):

```ini
# MANAGED BY PUPPET

[server]
bridge-hostname: sigul-bridge-us-west-2.linuxfoundation.org
bridge-port: 44333
max-file-payload-size: 1073741824
max-memory-payload-size: 1048576
max-rpms-payload-size: 10737418240
server-cert-nickname: aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org
signing-timeout: 60

[database]
database-path: /var/lib/sigul/server.sqlite

[gnupg]
gnupg-home: /var/lib/sigul/gnupg
gnupg-key-type: RSA
gnupg-key-length: 2048
gnupg-key-usage: sign
passphrase-length: 64

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: /etc/pki/sigul
nss-password: uFMLuCUpppkfV+GLqjv8W7ptCoV3z8li
nss-min-tls: tls1.2
nss-max-tls: tls1.2

```

**Production Notes (Verified from Extraction):**

- Production has **three separate server config files**, one per bridge (dent, lfit, odpi)
- Uses systemd template unit `sigul_server@.service` with instance name as parameter (`%i`)
- Command: `/usr/sbin/sigul_server -c /etc/sigul/server-%i.conf --internal-log-dir=/var/log/sigul-%i --internal-pid-dir=/run/sigul-%i -v`
- Explicit resource limits for file (1GB), memory (1MB), and RPM (10GB) payload sizes
- GnuPG configuration specifies: RSA 2048, key-usage=sign, passphrase-length=64
- Same NSS password and TLS settings as bridge (shared database on same host)
- Server config stored at `/etc/sigul/server-<instance>.conf` with ownership `sigul:sigul` and permissions `600`
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: /etc/pki/sigul
nss-password: uFMLuCUpppkfV+GLqjv8W7ptCoV3z8li
nss-min-tls: tls1.2
nss-max-tls: tls1.2

```

**Key Characteristics:**
- **Colon separator** (`key: value`)
- **Minimal sections**: `[bridge]`, `[server]`, `[database]`, `[gnupg]`, `[daemon]`, `[nss]`, `[koji]` (empty)
- **Password embedded directly** in config file (not file reference)
- **No `sql:` prefix** on `nss-dir`
- **Specific certificate nicknames** matching hostnames
- **TLS version constraints** explicitly set
- Simple, flat configuration
- Multiple server configs for different bridges
- **No `bridge-server` or `bridge-client` sections** - just `[bridge]`

### 3.2 Containerized Configuration Format

**Bridge Configuration** (generated in `scripts/sigul-init.sh:554`):
```ini
[nss]
nss-dir = /var/sigul/nss/bridge
nss-password = <password_from_file>

[bridge]
bridge-cert-nickname = sigul-bridge-cert
client-listen-port = 44334
server-listen-port = 44333
max-file-payload-size = 67108864
required-fas-group =
# NOTE: FAS integration NOT used - can be removed

[bridge-server]
nss-dir = sql:/var/sigul/nss/bridge
nss-password-file = /var/sigul/secrets/nss-password
ca-cert-nickname = sigul-ca
bridge-cert-nickname = sigul-bridge-cert
server-hostname = sigul-server
server-port = 44333
require-tls = true

[daemon]
unix-user =
unix-group =
```

**Server Configuration** (generated in `scripts/sigul-init.sh:574`):

```ini
[nss]
nss-dir = /var/sigul/nss/server
nss-password = <password_from_file>

[server]
database-path = /var/sigul/database/server.sqlite
nss-dir = sql:/var/sigul/nss/server
nss-password-file = /var/sigul/secrets/nss-password
ca-cert-nickname = sigul-ca
server-cert-nickname = sigul-server-cert
bridge-hostname = sigul-bridge
bridge-port = 44333
require-tls = true
gnupg-home = /var/sigul/gnupg
log-level = INFO
log-file = /var/sigul/logs/server.log
```

**Key Characteristics:**

- **Equals separator** (`key = value`)
- **Additional sections**: `[bridge-server]`, `[bridge-client]`, `[logging]`
- **Password file reference** (`nss-password-file`)
- **Password also embedded** in `[nss]` section (redundant)
- **`sql:` prefix** on some `nss-dir` values (inconsistent)
- **Generic certificate nicknames** (`sigul-bridge-cert`, `sigul-server-cert`)
- Extra configuration options not in production
- **Database location wrong** (`/var/sigul/database/` instead of `/var/lib/sigul/`)
- **GnuPG location wrong** (`/var/sigul/gnupg` instead of `/var/lib/sigul/gnupg`)

### 3.3 Gap Analysis: Configuration

| Aspect | Production | Container | Compatible? |
|--------|-----------|-----------|-------------|
| **Separator** | Colon (`:`) | Equals (`=`) | **Depends on parser** |
| **[bridge] Section** | Simple, one section | Split into `[bridge]` + `[bridge-server]` | **May not parse** |
| **nss-dir** | `/etc/pki/sigul` | `/var/sigul/nss/<component>` | **Path mismatch** |
| **nss-dir prefix** | None (or `dbm:`) | `sql:` (inconsistent) | **Format mismatch** |
| **Password** | Embedded in config | File reference + embedded (redundant) | **May not read file** |
| **Cert Nicknames** | Hostname-based | Generic (`sigul-*-cert`) | **Reference mismatch** |
| **database-path** | `/var/lib/sigul/server.sqlite` | `/var/sigul/database/server.sqlite` | **Wrong location** |
| **gnupg-home** | `/var/lib/sigul/gnupg` | `/var/sigul/gnupg` | **Wrong location** |
| **TLS Config** | `nss-min-tls`, `nss-max-tls` | `require-tls` (different) | **Different options** |
| **Empty Values** | Not present | `unix-user =` (empty) | **May cause parse errors** |

**Critical Issues:**

1. **Parser Compatibility Unknown**: Sigul's config parser may expect colon separators
2. **Section Names**: Production has no `[bridge-server]` or `[bridge-client]` sections
3. **NSS Path Format**: Production doesn't use `sql:` prefix consistently
4. **Database Location**: Wrong path will cause database not found errors
5. **Certificate Nickname Mismatch**: Config references `sigul-bridge-cert` but NSS may need hostname

---

## 4. Certificate Management and PKI

### 4.1 Production Certificate Management

**Certificate Distribution Model:**

- Certificates pre-generated and distributed as **PKCS#12 (`.p12`) files**
- Each `.p12` file contains:
  - Private key
  - Certificate
  - Certificate chain (CA)
- Imported into NSS database using `pk12util`:

  ```bash
  pk12util -i certificate.p12 -d /etc/pki/sigul
  ```

**Bridge Certificate Files:**

```
aws-us-west-2-dent-jenkins-1.ci.codeaurora.org.p12
aws-us-west-2-dent-jenkins-sandbox-1.ci.codeaurora.org.p12
aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org.p12
sigul-bridge-us-west-2.linuxfoundation.org.p12
```

**Server Certificate Files:**

```
aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org.p12
```

**Certificate Nicknames in Production:**

- Bridge primary cert: `sigul-bridge-us-west-2.linuxfoundation.org`
- Server cert: `aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org`
- Client certs: Various FQDN-based names

**Production Workflow:**

1. Certificates created externally (Puppet/CA)
2. Packaged as PKCS#12 with password
3. Copied to target system
4. Imported into NSS database
5. Trust relationships established via NSS trust flags

### 4.2 Containerized Certificate Management

**Certificate Generation Model:**

- Certificates generated **on-the-fly** at container startup
- No PKCS#12 files involved
- Direct NSS certificate generation using `certutil -S`:

  ```bash
  certutil -S -d "sql:$nss_dir" -n "$cert_nickname" \
    -s "$subject" -c "$CA_NICKNAME" -t "$trust_flags" \
    -f "$password_file" -k rsa -g 2048
  ```

**Certificate Generation Flow:**

1. Bridge creates self-signed CA certificate
2. Bridge exports CA cert to shared volume
3. Server/client wait for CA cert
4. Server/client import CA cert
5. Server/client generate their own certificates signed by CA
6. All done programmatically at runtime

**Certificate Nicknames in Container:**

- CA: `sigul-ca`
- Bridge: `sigul-bridge-cert`
- Server: `sigul-server-cert`
- Client: `sigul-client-cert`

**Containerized Workflow:**

1. Bridge initializes, creates CA (self-signed)
2. Bridge exports CA to `/var/sigul/ca-export/bridge-ca.crt`
3. Server mounts bridge volume, waits for CA
4. Server imports CA, generates server cert
5. Complex timing dependencies
6. No external CA involved

### 4.3 Gap Analysis: Certificate Management

| Aspect | Production | Container | Impact |
|--------|-----------|-----------|--------|
| **Cert Distribution** | Pre-generated PKCS#12 files | On-the-fly generation | Different trust model |
| **CA Authority** | External (Puppet/real CA) | Bridge self-signed | No external trust |
| **Import Method** | `pk12util` import | `certutil -S` generate | Different NSS operations |
| **Cert Format** | PKCS#12 (`.p12`) | Direct NSS generation | No interchange format |
| **Nicknames** | FQDN-based | Generic (`sigul-*-cert`) | Config/NSS mismatch |
| **Trust Chain** | External CA chain | Internal CA only | Different trust model |
| **Timing** | Static, pre-installed | Dynamic, startup-dependent | Race conditions |
| **Sharing** | Shared NSS database | Export/import mechanism | Complex, error-prone |
| **Certificate Subject** | Full DN with O, OU | Simple CN only | May affect verification |

**Critical Issues:**

1. **No PKCS#12 Workflow**: Production expects PKCS#12 import, containers never create .p12 files
2. **Certificate Nickname Mismatch**: Config expects hostname-based nicknames, NSS has generic names
3. **Trust Chain Differences**: External CA vs self-signed bridge CA
4. **Initialization Race Conditions**: Dynamic generation requires complex timing coordination
5. **No Certificate Persistence**: Certificates recreated on every container restart (unless volumes persist)

### 4.4 Certificate Trust Flags

**Production (inferred from PKCS#12 import):**

```
CA certificates:     CT,C,C  (Certificate Authority, Client SSL trusted)
Service certificates: u,u,u  (user certs, not trusted as CA)
```

**Container (from sigul-init.sh):**

```bash
# CA import (line 215):
certutil -A -d "sql:$nss_dir" -n "$CA_NICKNAME" -t "CT,C,C" -i "$ca_cert_file"

# Component cert generation (line 297):
trust_flags="u,u,u"
certutil -S ... -t "$trust_flags" ...
```

Trust flags appear consistent, but the **overall trust chain** differs due to external CA vs internal CA model.

---

## 5. Database and Data Storage

### 5.1 Production Database Configuration

**Server Database:**

```ini
[database]
database-path: /var/lib/sigul/server.sqlite
```

**Actual Location:**

- `/var/lib/sigul/server.sqlite` - confirmed from all production configs
- SQLite database file
- Persistent storage
- Contains user accounts, keys, permissions

**Production Evidence:**
All three server configs (base.conf, server-bridge-aws-us-west-2-lfit-sigul-bridge-1.conf, etc.) use:

```
database-path: /var/lib/sigul/server.sqlite
```

### 5.2 Containerized Database Configuration

**Generated Server Config** (scripts/sigul-init.sh:574):

```ini
[server]
database-path = /var/sigul/database/server.sqlite
```

**Template Config** (pki/server.conf.template:27):

```ini
[database]
database-path = /var/sigul/database/sigul.db
```

**Dockerfile Server** (Dockerfile.server:91):

```bash
RUN mkdir -p /var/log /var/run /var/lib/sigul /var/lib/sigul/gnupg
```

**Potential Locations:**

- `/var/sigul/database/server.sqlite` (generated config)
- `/var/sigul/database/sigul.db` (template)
- `/var/lib/sigul/server.sqlite` (correct, but may not be used)
- `/var/sigul/db/sigul.db` (sigul-config-nss-only.template:148)

**Multiple Inconsistencies:**

1. Generated config: `/var/sigul/database/server.sqlite`
2. NSS-only template: `/var/sigul/db/sigul.db`
3. Server template: `/var/sigul/database/sigul.db`
4. Production standard: `/var/lib/sigul/server.sqlite`

### 5.3 Gap Analysis: Database

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **Database Path** | `/var/lib/sigul/server.sqlite` | `/var/sigul/database/server.sqlite` | **Path mismatch** |
| **Database Name** | `server.sqlite` | `server.sqlite` OR `sigul.db` | **Name inconsistency** |
| **Directory** | `/var/lib/sigul/` (standard location) | `/var/sigul/database/` (non-standard) | **Non-standard location** |
| **Initialization** | `sigul_server_create_db -c config` | Same | Same command |
| **Volume Mounting** | N/A | `/var/sigul` volume | May not persist correctly |
| **Path Consistency** | Single path across all configs | 4 different paths in templates | **Inconsistent** |

**Critical Issue:** The database path inconsistency means:

1. Database initialization may create DB in one location
2. Server service may look for DB in different location
3. Server will fail to start due to "database not found" error

---

## 6. GnuPG Configuration

### 6.1 Production GnuPG Setup

```ini
[gnupg]
gnupg-home: /var/lib/sigul/gnupg
gnupg-key-type: RSA
gnupg-key-length: 2048
gnupg-key-usage: sign
passphrase-length: 64
```

**Location:** `/var/lib/sigul/gnupg`

- Standard location under `/var/lib/`
- Persistent storage area
- Contains GPG keyrings for signing operations
- Proper permissions (700)

### 6.2 Containerized GnuPG Setup

**Generated Config** (scripts/sigul-init.sh:584):

```ini
gnupg-home = /var/sigul/gnupg
```

**Dockerfile Server** (Dockerfile.server:91):

```bash
mkdir -p /var/lib/sigul/gnupg
chmod 700 /var/lib/sigul/gnupg
```

**sigul-init.sh** (line 50):

```bash
readonly GNUPG_DIR="/var/lib/sigul/gnupg"
```

**Mismatch:**

- Dockerfile creates: `/var/lib/sigul/gnupg` ✓
- sigul-init.sh constant: `/var/lib/sigul/gnupg` ✓
- Generated config: `/var/sigul/gnupg` ✗

### 6.3 Gap Analysis: GnuPG

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **GnuPG Home** | `/var/lib/sigul/gnupg` | `/var/sigul/gnupg` (config) OR `/var/lib/sigul/gnupg` (Dockerfile) | **Inconsistent paths** |
| **Permissions** | 700 | 700 (in Dockerfile) | Consistent |
| **Location Standard** | `/var/lib/` (correct) | `/var/sigul/` (generated config, wrong) | **Non-standard in config** |

**Critical Issue:** Config file points to `/var/sigul/gnupg` but directory may be created at `/var/lib/sigul/gnupg`, causing GPG operations to fail.

---

## 7. Password Management

### 7.1 Production Password Handling

**Password File:**

```
/etc/pki/sigul/nss-password.txt
```

**Content:**

```
uFMLuCUpppkfV+GLqjv8W7ptCoV3z8li
```

**Configuration Reference:**

```ini
[nss]
nss-password: uFMLuCUpppkfV+GLqjv8W7ptCoV3z8li
```

**Key Characteristics:**

- Password **embedded directly** in config file
- Plain text password string
- Not a file reference
- Same password shared across bridge and server (same host)
- File extension: `.txt`

### 7.2 Containerized Password Handling

**Password File:**

```
/var/sigul/secrets/nss-password
```

**No file extension** (unlike production's `.txt`)

**Configuration Reference (Dual Approach):**

```ini
[nss]
nss-password = <actual_password_string>

[server]
nss-password-file = /var/sigul/secrets/nss-password
```

**Key Characteristics:**

- Password both **embedded** and **referenced as file**
- Redundant specification
- No file extension
- Different password per component (per volume)

### 7.3 Gap Analysis: Password

| Aspect | Production | Container | Compatibility |
|--------|-----------|-----------|---------------|
| **Method** | Direct embedding | File reference + embedding | Different |
| **Config Key** | `nss-password` | `nss-password` + `nss-password-file` | Redundant |
| **File Extension** | `.txt` | None | May matter for discovery |
| **File Location** | `/etc/pki/sigul/nss-password.txt` | `/var/sigul/secrets/nss-password` | Path mismatch |
| **Sharing** | Shared (same host) | Isolated (per volume) | Different model |

**Potential Issue:** If Sigul's config parser expects embedded passwords (which production uses), the file reference may be ignored. Alternatively, if both are specified, behavior is undefined.

---

## 8. DNS and Name Resolution

### 8.1 Production DNS Configuration

**AWS Bridge Hosts File** (`/etc/hosts` on aws-us-west-2-lfit-sigul-bridge-1):

```
# Bridge's own identity (AWS)
10.30.118.134   aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org   aws-us-west-2-lfit-sigul-bridge-1

# Server identity (AWS - same subnet)
10.30.118.172   aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org   aws-us-west-2-lfit-sigul-server-1.web.codeaurora.org aws-us-west-2-lfit-sigul-server-1

# Other Sigul infrastructure (VEXXHOST - remote datacenter)
10.30.249.5     vex-yul-wl-sigul-server-1.dr.codeaurora.org   vex-yul-wl-sigul-server-1
10.30.249.32    vex-yul-wl-sigul-bridge-1.dr.codeaurora.org   vex-yul-wl-sigul-bridge-1

# OTHER INFRASTRUCTURE (NOT SIGUL - OUT OF SCOPE)
# LDAP infrastructure - DNS entries only, NOT integrated with Sigul
10.30.113.143   aws-us-west-2-lfit-ingress-1.dr.codeaurora.org   ldap-proxy.linux-foundation.org
10.30.117.106   aws-us-west-2-lfit-openldap-1.dr.codeaurora.org   aws-us-west-2-lfit-openldap-1.linux-foundation.org
```

**VEXXHOST Bridge Hosts File** (`/etc/hosts` on vex-yul-wl-sigul-bridge-1):

```
# Bridge's own identity (VEXXHOST - Public IP)
199.204.45.55   vex-yul-wl-sigul-bridge-1.dr.codeaurora.org   vex-yul-wl-sigul-bridge-1

# Server identity (VEXXHOST - Private IP via VPN)
10.30.249.5     vex-yul-wl-sigul-server-1.dr.codeaurora.org   vex-yul-wl-sigul-server-1

# Remote Sigul infrastructure (AWS - via VPN tunnel)
10.30.118.134   aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org   aws-us-west-2-lfit-sigul-bridge-1
10.30.118.172   aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org   aws-us-west-2-lfit-sigul-server-1.web.codeaurora.org aws-us-west-2-lfit-sigul-server-1

# OTHER INFRASTRUCTURE (NOT SIGUL - OUT OF SCOPE)
# LDAP infrastructure - DNS entries only, NOT integrated with Sigul
10.30.113.143   aws-us-west-2-lfit-ingress-1.dr.codeaurora.org   ldap-proxy.linux-foundation.org
10.30.117.106   aws-us-west-2-lfit-openldap-1.dr.codeaurora.org   aws-us-west-2-lfit-openldap-1.linux-foundation.org

# VPN gateway
10.30.249.6     vex-yul-wl-vpn.dr.codeaurora.org   vex-yul-wl-vpn
```

**AWS DNS Configuration** (`/etc/resolv.conf` on AWS bridge):

```
options timeout:2
search us-west-2.compute.internal dr.codeaurora.org
nameserver 127.0.0.1
nameserver 10.30.112.2
```

**VEXXHOST DNS Configuration** (`/etc/resolv.conf` on VEXXHOST bridge):

```
# File managed by puppet
search codeaurora.org dr.codeaurora.org
nameserver 127.0.0.1
options timeout:2
```

**Key Characteristics:**

- **Static hosts file** with private IP addresses (managed by Puppet)
- **Geo-distributed multi-datacenter architecture**:
  - **AWS (Production)**: aws-us-west-2 (Oregon) - Subnet 10.30.118.x/24
  - **VEXXHOST (DR/Secondary)**: vex-yul (Montreal, Canada) - Subnet 10.30.249.x/24
  - **Legacy**: pdx-wl (Portland) - bastion/management infrastructure
- **VPN-interconnected private network** (10.30.0.0/16 across all datacenters)
- Bridge and server **on same subnet within each datacenter** (Layer 2 local)
- **Cross-datacenter connectivity** via VPN tunnel (10.30.x.x routes across sites)
- **Multiple FQDNs** per host (primary FQDN + short name aliases)
- Local nameserver (127.0.0.1) + internal DNS (10.30.112.2 in AWS, local cache in VEXXHOST)
- Search domains:
  - AWS: `us-west-2.compute.internal`, `dr.codeaurora.org`
  - VEXXHOST: `codeaurora.org`, `dr.codeaurora.org`
- **No external DNS dependencies** for Sigul component resolution
- **All infrastructure entries present on all hosts** (full mesh knowledge)

**Network Architecture Discovery:**

- **Private RFC1918 network**: 10.30.0.0/16 (spans all datacenters)
- **AWS Subnet**: 10.30.118.0/24 (bridge + server co-located)
- **VEXXHOST Subnet**: 10.30.249.0/24 (bridge + server co-located)
- **VEXXHOST Public IP**: 199.204.45.55 (external access point)
- **VPN Gateway**: 10.30.249.6 (vex-yul-wl-vpn)
- **Cross-site routing**: All hosts can reach all other hosts via 10.30.x.x
- **Management**: Centralized Puppet (pdx-wl-puppet) - manages all sites
- **Note**: LDAP entries in hosts file are for other services, NOT Sigul integration

**Geographic Distribution:**

```
┌─────────────────────────────────────────────────────────────┐
│ PRODUCTION / DR INFRASTRUCTURE                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  AWS us-west-2 (Oregon)           VEXXHOST vex-yul (MTL)   │
│  ━━━━━━━━━━━━━━━━━━━              ━━━━━━━━━━━━━━━━━━━      │
│  10.30.118.134 (bridge)           199.204.45.55 (bridge)    │
│  10.30.118.172 (server)           10.30.249.5 (server)      │
│                                   10.30.249.6 (VPN gw)      │
│                                                             │
│  Note: LDAP infrastructure NOT part of Sigul                │
│                                                             │
│  ◄───────────── VPN Tunnel (10.30.0.0/16) ───────────────► │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Infrastructure Purpose:**

- **AWS**: Primary production environment
- **VEXXHOST**: Disaster recovery / secondary site (Montreal)
- Each site has complete bridge + server pair
- Bridges can communicate with remote servers via VPN
- Puppet-managed configuration ensures consistency

**Name Resolution Priority:**

1. `/etc/hosts` (static entries)
2. Local nameserver (127.0.0.1) - likely dnsmasq/local cache
3. Internal DNS server (10.30.112.2)
4. Search domain expansion

### 8.2 Containerized DNS Configuration

**Docker Compose Networking:**

```yaml
networks:
  sigul-network:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1
```

**Service Discovery:**

```yaml
services:
  sigul-bridge:
    container_name: sigul-bridge
    hostname: sigul-bridge
    networks:
      - sigul-network

  sigul-server:
    container_name: sigul-server
    hostname: sigul-server
    networks:
      - sigul-network
```

**Key Characteristics:**

- **Docker embedded DNS** (automatic service discovery)
- **Short hostnames** only (`sigul-bridge`, `sigul-server`)
- **No FQDNs** in container environment
- Docker DNS resolver at 127.0.0.11
- Dynamic DNS (changes with container recreation)
- Subnet: 172.20.0.0/16 (completely different from production)
- No `/etc/hosts` customization
- No search domains configured

**Name Resolution in Containers:**

1. Docker embedded DNS (127.0.0.11)
2. Resolves service names to container IPs
3. Falls back to host DNS for external names

### 8.3 Gap Analysis: DNS and Networking

| Aspect | Production | Container | Impact |
|--------|-----------|-----------|--------|
| **Name Resolution** | Static `/etc/hosts` | Docker embedded DNS | Different resolution method |
| **Hostname Format** | FQDNs with multiple aliases | Short names only | Certificate CN mismatch |
| **IP Addresses** | Static private IPs (10.30.x.x) | Dynamic Docker IPs (172.20.x.x) | No static addressing |
| **Network Segment** | Same subnet (10.30.118.x) | Separate Docker network | Different network model |
| **DNS Server** | Internal (10.30.112.2) + local cache | Docker DNS (127.0.0.11) | Different DNS infrastructure |
| **Search Domains** | `dr.codeaurora.org`, AWS domains | None configured | Name expansion differences |
| **Connectivity Type** | Layer 2 direct (same subnet) | Docker bridge (NAT) | Different network topology |
| **Multiple Aliases** | Yes (primary + aliases) | No (single name) | Limited naming flexibility |
| **External Access** | VPN/private network | Port mapping (44334) | Different access model |

**Critical Issues:**

1. **Hostname vs FQDN Mismatch**
   - **Production**: Uses site-specific FQDNs like:
     - `aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org`
     - `vex-yul-wl-sigul-bridge-1.dr.codeaurora.org`
   - **Container**: Uses generic short names like `sigul-bridge`
   - **Impact**: Certificate Common Names (CN) may not match hostnames
   - **Config Reference**: Bridge config uses `sigul-bridge-us-west-2.linuxfoundation.org` as cert nickname
   - **Container Config**: Uses generic `sigul-bridge-cert`
   - **Multi-site Impact**: Production naming includes geographic identifiers (aws-us-west-2, vex-yul)

2. **Certificate Subject Validation**
   - Production certificates likely have full DN with FQDNs and geographic identifiers
   - Container certificates use simple CN (just `CN=sigul-bridge`)
   - TLS/SSL validation may fail due to hostname mismatch
   - **Multi-site consideration**: Certificates must be site-specific for proper validation

3. **Multi-Datacenter Geo-Distributed Architecture**
   - Production supports **multiple geographic locations with full redundancy**:
     - AWS Oregon (primary production)
     - VEXXHOST Montreal (DR/secondary)
     - Cross-datacenter VPN mesh (10.30.0.0/16)
   - **Each site has complete bridge + server pair**
   - Single bridge can communicate with **local or remote servers** via VPN
   - Container setup assumes **single-instance, single-datacenter deployment**
   - **No multi-site awareness** in container architecture

4. **Network Isolation Model**
   - **Production**:
     - Bridge and server on same subnet within each datacenter (Layer 2)
     - Cross-datacenter via VPN tunnel (Layer 3)
     - Static 10.30.x.x addressing
   - **Container**:
     - Bridge and server on isolated Docker network
     - Single-site only (no multi-datacenter concept)
     - No VPN integration
     - Dynamic 172.20.x.x addressing
   - **Trust model differs**: Production uses VPN-based trust, containers use Docker network isolation

5. **Static vs Dynamic Resolution**
   - **Production**:
     - Puppet-managed static `/etc/hosts` (identical across all sites)
     - All hosts know about all other hosts globally
     - VPN routing enables cross-site connectivity
     - Configuration changes managed centrally via Puppet
   - **Container**:
     - Dynamic Docker DNS resolution
     - Only knows about containers in same compose stack
     - Breaks on container recreation if IPs change
     - No central configuration management

6. **No Search Domain Configuration**
   - **Production**:
     - Search domains enable short name resolution (`codeaurora.org`, `dr.codeaurora.org`)
     - Can use short names or FQDNs interchangeably
     - Site-specific search domains (AWS includes `us-west-2.compute.internal`)
   - **Container**:
     - No search domains configured
     - Requires exact service names
     - May affect hostname resolution in configs

7. **Public vs Private IP Addressing**
   - **Production VEXXHOST**: Uses public IP (199.204.45.55) for external access, private IP (10.30.249.x) for internal
   - **Production AWS**: Uses private IPs only (10.30.118.x)
   - **Container**: Uses Docker bridge IPs only (172.20.x.x)
   - **Impact**: Production has external/internal IP duality for cross-datacenter access

### 8.4 Certificate CN and Hostname Alignment

**Production Certificate Naming:**

```
Bridge Certificate CN: sigul-bridge-us-west-2.linuxfoundation.org
Server Certificate CN: aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org

/etc/hosts aliases allow resolution of:
- aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org
- aws-us-west-2-lfit-sigul-bridge-1
- sigul-bridge-us-west-2.linuxfoundation.org (certificate name)
```

**Container Certificate Naming:**

```
Bridge Certificate CN: sigul-bridge (simple)
Docker hostname: sigul-bridge
DNS resolution: sigul-bridge -> 172.20.x.x

No aliases, no FQDNs
```

**Hostname Resolution for TLS:**

- Production server config: `bridge-hostname: sigul-bridge-us-west-2.linuxfoundation.org`
- This MUST match certificate CN for TLS validation
- Container server config: `bridge-hostname = sigul-bridge`
- Simple name may not match certificate expectations

**Critical Issue:** If Sigul validates that the connecting hostname matches the certificate CN/SAN (Subject Alternative Name), the short Docker service names will fail validation against FQDN-based certificates.

**Modernization Note:** FQDN-based certificates are best practice and should be retained in modern deployment. Docker service names can be configured as aliases or the certificate generation can use appropriate SANs for both FQDNs and short names.

---

## 9. Network and Port Configuration

### 9.1 Production Network Setup (Verified from Extraction)

**Bridge Port Bindings (Verified):**

```
tcp  0.0.0.0:44333  LISTEN  (python - sigul_bridge process)  # Server-facing port
tcp  0.0.0.0:44334  LISTEN  (python - sigul_bridge process)  # Client-facing port
```

**Server Port Bindings (Verified):**

```
No listening ports - Server connects OUT to bridge on port 44333
```

**Established Connection (Verified at extraction time):**

```
Bridge: 10.30.118.134:44333 → 10.30.118.172:39716 ESTABLISHED (python)
Server: 10.30.118.172:39816 → 10.30.118.134:44333 ESTABLISHED (python)
```

**Key Findings:**

- Bridge listens on **0.0.0.0** (all interfaces), not just private IP
- Server **does not listen** - it actively connects to bridge
- Connection from server to bridge uses ephemeral high ports (39xxx range)
- Both ports handled by same bridge process (PID 20038 on production bridge)

**Bridge Configuration:**

```ini
[bridge]
client-listen-port: 44334
server-listen-port: 44333
```

**Server Configuration:**

```ini
[server]
bridge-hostname: sigul-bridge-us-west-2.linuxfoundation.org
bridge-port: 44333
```

**Key Points:**

- Bridge listens on 44334 (client connections)
- Bridge listens on 44333 (server connections)
- Server connects to bridge on 44333
- Server uses **FQDN** for bridge hostname
- No explicit listen addresses (defaults to all interfaces)

### 9.2 Containerized Network Setup

**Bridge Configuration:**

```ini
[bridge]
client-listen-port = 44334
server-listen-port = 44333

[bridge-server]
server-hostname = sigul-server
server-port = 44333
```

**Server Configuration:**

```ini
[server]
bridge-hostname = sigul-bridge
bridge-port = 44333
```

**Docker Compose:**

```yaml
services:
  sigul-bridge:
    ports:
      - "44334:44334"
    # 44333 NOT exposed externally (internal only)

  sigul-server:
    depends_on:
      sigul-bridge:
        condition: service_healthy
```

**Key Points:**

- Bridge listens on 44334 (exposed to host)
- Bridge listens on 44333 (internal only)
- Server connects to `sigul-bridge:44333` (Docker DNS)
- Short hostnames (Docker service names)
- Additional `[bridge-server]` section with redundant port config

### 9.3 Gap Analysis: Network Ports

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **Bridge Client Port** | 44334 | 44334 | ✓ Consistent |
| **Bridge Server Port** | 44333 | 44333 | ✓ Consistent |
| **Hostname Format** | FQDN | Short (Docker service) | Different but OK |
| **Network Type** | Physical/AWS network | Docker bridge network | Different but OK |
| **Section Structure** | Single `[bridge]` | `[bridge]` + `[bridge-server]` | **May not parse** |
| **Port Exposure** | All ports accessible | Only 44334 exposed | Could cause issues |

**Potential Issue:** The `[bridge-server]` section is not present in production configs. This additional section may cause config parsing failures.

---

## 10. Configuration File Sections

### 10.1 Production Configuration Sections

**Bridge Config Sections:**

1. `[bridge]`
2. `[koji]`
3. `[daemon]`
4. `[nss]`

**Server Config Sections:**

1. `[server]`
2. `[database]`
3. `[gnupg]`
4. `[daemon]`
5. `[nss]`

**Simple, Standard Sections:**

- No subsections
- No duplicate sections
- No nested configuration
- Minimal options

### 10.2 Containerized Configuration Sections

**Bridge Config Sections:**

1. `[nss]`
2. `[bridge]`
3. `[bridge-server]` ← **Not in production**
4. `[daemon]`

**Server Config Sections:**

1. `[nss]`
2. `[server]` (with many combined options)
3. `[daemon]` (possibly missing [database] and [gnupg])

**Additional Complexity:**

- Custom templates with many sections: `[logging]`, `[security]`, `[performance]`, `[backup]`, etc.
- Many options not in production configs
- Unclear which template is actually used

### 10.3 Gap Analysis: Sections

| Section | Production | Container | Issue |
|---------|-----------|-----------|-------|
| `[bridge]` | ✓ Present | ✓ Present | OK |
| `[bridge-server]` | ✗ Absent | ✓ Present | **Extra section** |
| `[bridge-client]` | ✗ Absent | ✓ In templates | **Extra section** |
| `[server]` | ✓ Present | ✓ Present | OK (but different options) |
| `[database]` | ✓ Separate section | ✓ Merged into [server] | **Structure difference** |
| `[gnupg]` | ✓ Separate section | ✓ Merged into [server] | **Structure difference** |
| `[nss]` | ✓ Present | ✓ Present | OK (but different values) |
| `[daemon]` | ✓ Present | ✓ Present | OK (but empty values) |
| `[koji]` | ✓ Present (empty, unused) | ✗ Absent | **Can be removed** |
| `[logging]` | ✗ Absent | ✓ In templates | **Extra section** |
| `[security]` | ✗ Absent | ✓ In templates | **Extra section** |

**Critical Issue:** The presence of `[bridge-server]` and `[bridge-client]` sections not found in production may cause the config parser to fail or behave unexpectedly.

---

## 11. Service Initialization and Startup

### 11.1 Production Service Startup

**Service Management:**

- Likely systemd service files
- Static configuration pre-installed
- Certificates pre-installed
- Database pre-initialized
- Simple startup sequence:
  1. Read config from `/etc/sigul/<component>.conf`
  2. Load NSS database from `/etc/pki/sigul/`
  3. Open database from `/var/lib/sigul/server.sqlite`
  4. Start service

**No Dynamic Initialization:**

- No certificate generation at startup
- No CA export/import
- No complex dependencies

### 11.2 Containerized Service Startup

**Initialization Script:** `sigul-init.sh`

**Complex Startup Sequence:**

**Bridge:**

1. Create directory structure
2. Generate NSS password
3. Create NSS database (cert9.db format)
4. Generate self-signed CA certificate
5. Export CA to `/var/sigul/ca-export/bridge-ca.crt`
6. Export CA as PKCS#12 for server/client
7. Generate bridge certificate
8. Generate configuration file
9. Start `sigul_bridge` service

**Server:**

1. Create directory structure
2. Generate NSS password (or reuse)
3. Wait for bridge CA export (up to 60 seconds)
4. Create NSS database
5. Import CA certificate from bridge
6. Import CA private key from PKCS#12
7. Generate server certificate
8. Generate configuration file
9. Initialize database (create schema)
10. Create admin user
11. Start `sigul_server` service

**Client:**
1-7. Same as server
8. Generate configuration file
9. No service start (interactive)

### 11.3 Gap Analysis: Initialization

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **Cert Source** | Pre-installed | Generated at startup | Timing issues |
| **CA Authority** | External | Bridge self-signed | Different trust model |
| **Dependencies** | None | Server depends on bridge CA | Race conditions |
| **Timing** | Deterministic | Non-deterministic | Startup failures |
| **Persistence** | Permanent | Volume-dependent | Data loss risk |
| **Config Generation** | Static | Dynamic | Inconsistency risk |
| **DB Initialization** | Pre-done | At startup | Ordering issues |
| **Startup Time** | Fast (< 5 sec) | Slow (30-60 sec) | Health check failures |
| **Failure Recovery** | Restart service | Recreate certificates | Complex recovery |

**Critical Issues:**

1. **Race Conditions**: Server must wait for bridge CA export; timing not guaranteed
2. **Certificate Regeneration**: Containers recreate certificates on restart, breaking trust if volumes aren't persistent
3. **Complex Dependencies**: Multi-step initialization with many failure points
4. **Volume Persistence**: Critical data must persist across restarts or certificates break

---

## 12. Volume Mounting and Data Persistence

### 12.1 Production Data Persistence

**No Volume Concept:**

- Files stored directly on host filesystem
- `/etc/sigul/` - configuration (persistent)
- `/etc/pki/sigul/` - NSS databases (persistent)
- `/var/lib/sigul/` - data and GPG (persistent)
- No abstraction layer

### 12.2 Containerized Volume Strategy

**Docker Compose Volumes:**

```yaml
volumes:
  sigul_server_data:
    driver: local
  sigul_bridge_data:
    driver: local
  sigul_client_data:
    driver: local
```

**Volume Mounts:**

**Bridge:**

```yaml
volumes:
  - sigul_bridge_data:/var/sigul
```

**Server:**

```yaml
volumes:
  - sigul_server_data:/var/sigul
  - sigul_bridge_data:/var/sigul/bridge-shared:ro
```

**Client:**

```yaml
volumes:
  - sigul_client_data:/var/sigul
  - sigul_bridge_data:/var/sigul/bridge-shared:ro
```

**Critical Dependencies:**

1. Server must read CA from bridge volume: `/var/sigul/bridge-shared/ca-export/`
2. Client must read CA from bridge volume: `/var/sigul/bridge-shared/ca-export/`
3. Bridge must write CA to: `/var/sigul/ca-export/` (appears as `bridge-shared` to others)

### 12.3 Gap Analysis: Volumes

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **Persistence** | Direct filesystem | Docker volumes | Abstraction complexity |
| **Sharing** | Shared filesystem | Volume mounting | Different sharing model |
| **CA Distribution** | Pre-installed | Volume export/import | Race conditions |
| **Volume Structure** | N/A | Separate per component | Isolation breaks NSS sharing |
| **Initialization** | One-time | Every container creation | Regeneration issues |
| **Recovery** | Restore from backup | Volume management | Different procedures |

**Critical Issues:**

1. **NSS Database Sharing**: Production can share `/etc/pki/sigul/`; containers cannot share volumes the same way
2. **CA Distribution Timing**: Volume-based CA export is asynchronous and error-prone
3. **Data Loss Risk**: Volume deletion or corruption breaks entire certificate chain
4. **Complex Recovery**: Restoring volumes doesn't guarantee certificate validity

---

## 12. DNS and Name Resolution

### 12.1 Production DNS/Hosts Configuration

**Production hosts file** (`/etc/hosts` from bridge):

```
# Bridge's own identity
10.30.118.134   aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org   aws-us-west-2-lfit-sigul-bridge-1

# Server entry (on same subnet)
10.30.118.172   aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org   aws-us-west-2-lfit-sigul-server-1.web.codeaurora.org aws-us-west-2-lfit-sigul-server-1

# Other Sigul infrastructure
10.30.249.5     vex-yul-wl-sigul-server-1.dr.codeaurora.org   vex-yul-wl-sigul-server-1
10.30.249.32    vex-yul-wl-sigul-bridge-1.dr.codeaurora.org   vex-yul-wl-sigul-bridge-1

# NOTE: LDAP entries below are NOT used by Sigul - out of scope
10.30.113.143   aws-us-west-2-lfit-ingress-1.dr.codeaurora.org   ldap-proxy.linux-foundation.org
10.30.117.106   aws-us-west-2-lfit-openldap-1.dr.codeaurora.org   aws-us-west-2-lfit-openldap-1.linux-foundation.org
```

**Key Characteristics:**

- **Static host entries** in `/etc/hosts` for all Sigul components
- **Private IP addresses** (10.30.x.x subnet)
- Bridge and server on **same network segment** (10.30.118.x)
- **Multiple hostnames/aliases** per IP (FQDN + short name + alternate domains)
- **No external DNS dependency** for Sigul communication
- Managed by Puppet (auto-generated)
- Multiple domains: `.dr.codeaurora.org`, `.web.codeaurora.org`, `.linux-foundation.org`

**Network Architecture:**

```
10.30.118.0/24 subnet (AWS us-west-2)
├── 10.30.118.134 - Bridge (aws-us-west-2-lfit-sigul-bridge-1)
└── 10.30.118.172 - Server (aws-us-west-2-lfit-sigul-server-1)
```

**Certificate Nickname Correlation:**

- Bridge cert nickname: `sigul-bridge-us-west-2.linuxfoundation.org` (matches hostname pattern)
- Server cert nickname: `aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org` (matches FQDN)
- **Certificate nicknames are based on hostnames from /etc/hosts**

**Production Configuration References:**

```ini
[server]
bridge-hostname: sigul-bridge-us-west-2.linuxfoundation.org
```

This hostname would resolve via:

1. Check `/etc/hosts` for bridge entries
2. Likely maps to the bridge via additional hosts entries or DNS
3. Uses fully qualified domain names (FQDNs)

### 12.2 Containerized DNS Configuration

**Docker Compose Network:**

```yaml
networks:
  sigul-network:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1
```

**Service Names (Docker DNS):**

```yaml
services:
  sigul-server:
    hostname: sigul-server
  sigul-bridge:
    hostname: sigul-bridge
  sigul-client-test:
    hostname: sigul-client-test
```

**Configuration References:**

```ini
[server]
bridge-hostname = sigul-bridge

[client]
bridge-hostname = sigul-bridge
```

**Key Characteristics:**

- **Dynamic DNS** via Docker's embedded DNS server
- **Docker bridge network** (172.20.0.0/16)
- **Service name resolution** (e.g., `sigul-bridge` resolves to container IP)
- **Short hostnames** only (no FQDNs)
- **No /etc/hosts customization**
- IPs assigned dynamically by Docker
- No multiple aliases

**Network Architecture:**

```
Docker bridge network (172.20.0.0/16)
├── 172.20.0.x - sigul-bridge (dynamic IP)
├── 172.20.0.y - sigul-server (dynamic IP)
└── 172.20.0.z - sigul-client-test (dynamic IP)
```

### 12.3 Gap Analysis: DNS and Naming

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **Name Resolution** | Static `/etc/hosts` | Docker DNS | Different mechanism |
| **IP Addressing** | Static private IPs (10.30.x.x) | Dynamic IPs (172.20.x.x) | Different ranges |
| **Hostname Format** | FQDNs (multiple domains) | Short names only | Format mismatch |
| **Aliases** | Multiple per host | Single name per service | No alias support |
| **DNS Source** | Local hosts file | Docker embedded DNS | Different sources |
| **Network Segment** | Production subnet | Isolated Docker network | Different isolation |
| **IP Persistence** | Static (configured) | Dynamic (changes on restart) | Stability difference |
| **Multiple Bridges** | Supported (multiple hosts entries) | Not implemented | Architecture limitation |
| **Cert Nickname Match** | Matches FQDN in hosts | Generic name, doesn't match | **Mismatch** |

**Critical Observations:**

1. **Certificate Nickname Pattern**
   - Production cert nicknames **match hostnames** from `/etc/hosts`
   - Bridge: `sigul-bridge-us-west-2.linuxfoundation.org`
   - Server: `aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org`
   - Container cert nicknames are generic (`sigul-bridge-cert`, `sigul-server-cert`)
   - **This mismatch could cause certificate validation failures**

2. **Multi-Bridge Architecture**
   - Production has multiple bridge entries in hosts file
   - Suggests one server can work with multiple bridges
   - Container architecture assumes single bridge only
   - Server has multiple config files (one per bridge)

3. **Network Isolation**
   - Production: Bridge and server on **same subnet** (10.30.118.x)
   - Container: Isolated Docker network
   - Production implies direct routing, low latency
   - Container adds Docker network abstraction layer

4. **Hostname Stability**
   - Production: Hostnames and IPs never change
   - Container: Service names stable, but IPs can change
   - Affects certificate subject validation

5. **External Dependencies**
   - Production has LDAP DNS entries but **NO Sigul integration** (confirmed via config analysis)
   - Container does not need LDAP - users managed in SQLite database
   - Authentication is direct to Sigul server database

### 12.4 Hostname-to-Certificate Mapping

**Production Pattern:**

```
/etc/hosts entry → Configuration hostname → Certificate nickname
10.30.118.134 aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org
                       ↓
[bridge] bridge-cert-nickname: sigul-bridge-us-west-2.linuxfoundation.org
                       ↓
NSS database contains cert with nickname: sigul-bridge-us-west-2.linuxfoundation.org
```

**Container Pattern:**

```
Docker service name → Configuration hostname → Certificate nickname
sigul-bridge
     ↓
[bridge] bridge-cert-nickname = sigul-bridge-cert
     ↓
NSS database contains cert with nickname: sigul-bridge-cert
```

**Mismatch Impact:**

- Certificate subject may include hostname from generation
- If Sigul validates that cert nickname matches expected hostname, this would fail
- Certificate subject DN may not match hostname in config

### 12.5 LDAP Integration Status: OUT OF SCOPE

**Production Analysis Confirms:**

- LDAP DNS entries exist in `/etc/hosts` but **NO references in Sigul configs**
- No LDAP configuration in any `/etc/sigul/*.conf` files
- No LDAP-related code in Sigul Python source
- Users stored and authenticated directly in SQLite database

**Conclusion:**

- **LDAP is NOT used by Sigul** - DNS entries are for other infrastructure services
- Container implementation is correct: users managed in SQLite
- No LDAP integration needed for modernized stack

---

## 13. User and Permission Model

### 13.1 Production User/Group

**Configuration:**

```ini
[daemon]
unix-user: sigul
unix-group: sigul
```

**Characteristics:**

- Service runs as `sigul:sigul`
- UID/GID determined by system (likely RPM-assigned)
- Consistent across components
- Files owned by `sigul:sigul`

### 13.2 Containerized User/Group

**Dockerfile:**

```dockerfile
# Create user with UID 1000 and GID 1000
groupadd -g 1000 sigul
useradd -r -u 1000 -g 1000 -d /var/sigul -s /bin/bash sigul

USER sigul
```

**Docker Compose:**

```yaml
services:
  sigul-server:
    user: "1000:1000"
```

**Configuration:**

```ini
[daemon]
unix-user =
unix-group =
```

**Characteristics:**

- Fixed UID/GID 1000
- User specified in both Dockerfile and compose
- Config has empty `unix-user` and `unix-group`
- May conflict with sigul daemon expectations

### 13.3 Gap Analysis: Users

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **UID/GID** | System-assigned | Fixed (1000:1000) | May not match |
| **Config Values** | `sigul:sigul` | Empty strings | **Config inconsistency** |
| **User Spec** | In config only | Dockerfile + compose + config | Redundant, confusing |
| **Home Dir** | Likely `/var/lib/sigul` | `/var/sigul` | Path difference |

**Potential Issue:** Empty `unix-user` and `unix-group` in config may cause service to fail if it expects these values to determine process user.

---

## 14. TLS and Security Configuration

### 14.1 Production TLS Configuration

```ini
[nss]
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

**Characteristics:**

- Explicit TLS version constraints
- Forces TLS 1.2 only
- No newer or older versions allowed
- Security policy enforced

### 14.2 Containerized TLS Configuration

**Generated Config (sigul-init.sh):**

```ini
[bridge-server]
require-tls = true

[server]
require-tls = true
```

**Template Config:**

```ini
[nss]
require-tls = true
fips-mode = false
```

**Missing from Generated Config:**

- No `nss-min-tls`
- No `nss-max-tls`
- Only `require-tls` flag

### 14.3 Gap Analysis: TLS

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **TLS Version Control** | Explicit min/max | None | **May negotiate wrong version** |
| **Config Keys** | `nss-min-tls`, `nss-max-tls` | `require-tls` | **Different options** |
| **FIPS Mode** | Not specified | `fips-mode = false` | Additional option |
| **Security Policy** | TLS 1.2 only | Any TLS version | **Weaker security** |

**Critical Issue:** Without TLS version constraints, client and server may negotiate incompatible TLS versions, causing connection failures.

---

## 15. Command Invocation and Service Start

### 15.1 Production Service Start

**Likely Command:**

```bash
# Systemd service or init script
sigul_bridge -c /etc/sigul/bridge.conf
sigul_server -c /etc/sigul/server.conf
```

**Simple, direct invocation:**

- No initialization script
- Config path only
- Daemon mode

### 15.2 Containerized Service Start

**Docker Compose Command:**

```yaml
command: ["/usr/local/bin/sigul-init.sh", "--role", "bridge", "--debug", "--start-service"]
```

**Actual Start (from sigul-init.sh:654):**

```bash
start_sigul_service() {
    local role="$1"
    local config_file="$CONFIG_DIR/$role.conf"

    case "$role" in
        "bridge")
            exec sigul_bridge -c "$config_file"
            ;;
        "server")
            exec sigul_server -c "$config_file"
            ;;
    esac
}
```

**Difference:**

- Wrapper script instead of direct invocation
- Generated config instead of static config
- Config at `/var/sigul/config/<role>.conf` instead of `/etc/sigul/<role>.conf`

### 15.3 Gap Analysis: Service Start

| Aspect | Production | Container | Issue |
|--------|-----------|-----------|-------|
| **Invocation** | Direct | Via wrapper script | Additional complexity |
| **Config Path** | `/etc/sigul/<role>.conf` | `/var/sigul/config/<role>.conf` | **Path mismatch** |
| **Initialization** | None | Full init sequence | Startup delays |
| **Config Source** | Static file | Generated at runtime | Inconsistency risk |

**Potential Issue:** If `sigul_bridge` or `sigul_server` have hardcoded config paths (e.g., looking for `/etc/sigul/bridge.conf` by default), the `-c` flag override may not work correctly.

---

## 16. Integration Test Observations

### 16.1 Test Operations

**Integration tests attempt** (from `run-integration-tests.sh`):

1. Create user: `sigul --batch new-user --with-password`
2. Create key: `sigul --batch new-key --key-admin`
3. List keys: `sigul --batch list-keys`
4. Sign data: `sigul --batch sign-data`
5. Get public key: `sigul --batch get-public-key`

**All operations invoke:**

```bash
sigul -c /var/sigul/config/client.conf --batch <operation>
```

### 16.2 Test Failures

**Observed Failure Pattern:**

- Containers start but operations fail
- Communication issues between components
- Authentication/authorization failures
- Certificate validation errors

**Likely Root Causes (based on gaps):**

1. NSS format mismatch (cert9.db vs cert8.db expected)
2. Certificate nickname mismatches
3. Configuration format issues
4. Path mismatches (database, GPG, NSS)
5. TLS version negotiation failures
6. Password file not read correctly

---

## 17. Critical Path Issues Summary

### 17.1 Blocking Issues (Must Fix)

1. **Directory Path Mismatches**
   - **Gap**: `/etc/sigul/` vs `/var/sigul/config/`, `/etc/pki/sigul/` vs `/var/sigul/nss/<component>/`
   - **Impact**: Config/certs not found, services fail to start
   - **Priority**: CRITICAL - Must align paths

3. **Database Location Wrong**
   - **Gap**: Production uses `/var/lib/sigul/server.sqlite`, container uses `/var/sigul/database/server.sqlite`
   - **Impact**: Database not found, server initialization fails
   - **Priority**: CRITICAL - Breaks server startup

4. **Configuration Format Differences**
   - **Gap**: Colon vs equals, extra sections, embedded vs file passwords
   - **Impact**: Config parsing failures
   - **Priority**: HIGH - May cause startup failures

5. **Certificate Nickname and CN Mismatches**
   - **Gap**: FQDN-based (sigul-bridge-us-west-2.linuxfoundation.org) vs generic (sigul-bridge-cert)
   - **Impact**: Config references don't match NSS database contents, hostname validation fails
   - **Priority**: HIGH - Breaks TLS authentication

### 17.2 High-Impact Issues (Likely Causing Failures)

6. **Certificate Distribution Model**
   - **Gap**: Production uses external CA (EasyRSA) with .p12 distribution, container uses self-signed on-the-fly generation
   - **Impact**: Trust chain differences, certificate attributes may differ
   - **Priority**: HIGH - May affect trust relationships
   - **Modernization Note:** External CA is best practice; can use modern CA like Let's Encrypt or internal PKI

7. **TLS Version Configuration Missing**
   - **Gap**: Production sets `nss-min-tls`/`nss-max-tls`, container doesn't
   - **Impact**: TLS negotiation failures
   - **Priority**: HIGH - Breaks secure connections

8. **GnuPG Home Path Wrong**
   - **Gap**: `/var/lib/sigul/gnupg` vs `/var/sigul/gnupg`
   - **Impact**: Signing operations fail
   - **Priority**: HIGH - Breaks core functionality

9. **Shared vs Isolated NSS Databases**
   - **Gap**: Production shares `/etc/pki/sigul/`, container isolates per component
   - **Impact**: Trust relationships not established
   - **Priority**: HIGH - Complex certificate sharing issues

10. **DNS and Name Resolution**
    - **Gap**: Production uses `/etc/hosts` with FQDNs, container uses Docker DNS with short names
    - **Impact**: Certificate nickname mismatches, hostname validation failures
    - **Priority**: HIGH - Affects certificate validation

11. **Configuration Section Structure**
    - **Gap**: Production has no `[bridge-server]` section, container does
    - **Impact**: Config parsing may fail
    - **Priority**: MEDIUM-HIGH - Depends on parser strictness

### 17.3 Medium-Impact Issues (May Contribute)

11. **DNS and Hostname Architecture**
    - **Gap**: Production uses site-specific FQDNs with static hosts in geo-distributed architecture, container uses short names in single-site deployment
    - **Impact**: Certificate CN/hostname validation failures, no multi-datacenter support
    - **Priority**: MEDIUM-HIGH - Affects TLS authentication and scalability

12. Empty User/Group in Config
13. Password File Extension Difference
14. Multiple Inconsistent Templates
15. Complex Initialization Dependencies
16. Volume-based Certificate Distribution Race Conditions

---

## 18. Critical Production Runtime Findings

This section documents the **actual runtime configuration patterns** discovered on production servers. Focus is on **configuration structure and operational patterns**. Detailed version information is preserved in **Appendix B** for reference in case fallback to production-matching versions is needed during troubleshooting.

### 18.1 Production Software Stack Summary

**Production Software (Legacy - Reference Only):**

- Python 2.7.5 (EOL) → Modernize to Python 3.9+
- python-nss 0.16.0 → Modernize to python3-nss
- sigul 0.207 → Modernize to current version
- NSS 3.90.0 with cert8.db → Modernize to current NSS with cert9.db
- GPG 1.x with secring.gpg → Modernize to GPG 2.x

**See Appendix B for complete version details** including all package versions, file formats, and exact configurations for fallback scenarios.

**Key Insight:** The production stack is **outdated but working**. The configuration patterns and file locations are what matter - modern software can use the same configuration structure with updated syntax where needed.

### 18.2 Actual Service Startup Commands

**Bridge Systemd Service:**

```ini
[Unit]
Description=Sigul bridge server
After=network.target
Documentation=https://fedorahosted.org/sigul/

[Service]
ExecStart=/usr/sbin/sigul_bridge -v
Type=simple

[Install]
WantedBy=multi-user.target
```

**Running Process:**

```bash
sigul    20038  /usr/bin/python /usr/share/sigul/bridge.py -v
```

**Key Observations:**

- **No `-c` flag** - Bridge reads default `/etc/sigul/bridge.conf` location
- Only `-v` (verbose) flag
- Simple, direct startup
- No config path specified
- **Modernization Lesson:** Sigul expects configuration at standard FHS locations by default

**Server Systemd Service (Template):**

```ini
[Unit]
Description=Sigul vault server (template)
After=network.target
Documentation=https://fedorahosted.org/sigul/

[Service]
ExecStart=/usr/sbin/sigul_server -c /etc/sigul/server-%i.conf --internal-log-dir=/var/log/sigul-%i --internal-pid-dir=/run/sigul-%i -v
Type=simple
Restart=on-failure
RestartSec=5s
StartLimitInterval=10
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
```

**Running Process:**

```bash
# Instance: sigul_server@bridge-aws-us-west-2-lfit-sigul-bridge-1.service
/usr/bin/python /usr/share/sigul/server.py -c /etc/sigul/server-bridge-aws-us-west-2-lfit-sigul-bridge-1.conf --internal-log-dir=/var/log/sigul-bridge-aws-us-west-2-lfit-sigul-bridge-1 --internal-pid-dir=/run/sigul-bridge-aws-us-west-2-lfit-sigul-bridge-1 -v
```

**Key Observations:**

- Uses systemd template with `%i` = instance name
- Config: `/etc/sigul/server-<instance>.conf` (standard location)
- Separate log directory per instance: `/var/log/sigul-<instance>/`
- Separate PID directory per instance: `/run/sigul-<instance>/`
- Supports multiple server instances per bridge
- **Modernization Lesson:** Multiple bridge support requires instance-based configuration naming

### 18.3 Network Binding Confirmation

**Bridge Network Listeners:**

```bash
netstat -tulpn | grep -E '44333|44334'
tcp    0.0.0.0:44333    LISTEN    20038/python
tcp    0.0.0.0:44334    LISTEN    20038/python
```

**Confirmed:**

- Bridge binds to `0.0.0.0` (all interfaces)
- Ports 44333 and 44334 both listening
- Single process handles both ports

### 18.4 Database Schema (Production)

**Location:** `/var/lib/sigul/server.sqlite`

**Schema:**

```sql
CREATE TABLE keys (
    id INTEGER NOT NULL,
    name TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    PRIMARY KEY (id),
    UNIQUE (name),
    UNIQUE (fingerprint)
);

CREATE TABLE users (
    id INTEGER NOT NULL,
    name TEXT NOT NULL,
    sha512_password BLOB,
    admin BOOLEAN NOT NULL,
    PRIMARY KEY (id),
    UNIQUE (name),
    CHECK (admin IN (0, 1))
);

CREATE TABLE key_accesses (
    id INTEGER NOT NULL,
    key_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    encrypted_passphrase BLOB NOT NULL,
    key_admin BOOLEAN NOT NULL,
    PRIMARY KEY (id),
    UNIQUE (key_id, user_id),
    FOREIGN KEY(key_id) REFERENCES keys (id),
    FOREIGN KEY(user_id) REFERENCES users (id),
    CHECK (key_admin IN (0, 1))
);
```

**Key Fields:**

- `users.sha512_password`: Password stored as SHA-512 hash (BLOB)
- `users.admin`: Boolean flag for admin privileges
- `key_accesses.encrypted_passphrase`: Encrypted GPG key passphrase per user
- `key_accesses.key_admin`: Per-key admin permissions

**File Permissions:**

```bash
-rw-r--r--. sigul sigul unconfined_u:object_r:sigul_var_lib_t:s0 server.sqlite
```

### 18.5 Certificate Details (Production)

**Bridge Certificates:**

```
Certificate Nickname                                         Trust Attributes
                                                             SSL,S/MIME,JAR/XPI

easyrsa                                                      CT,,
aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org          u,u,u
aws-us-west-2-dent-jenkins-sandbox-1.ci.codeaurora.org       u,u,u
sigul-bridge-us-west-2.linuxfoundation.org                   u,u,u
aws-us-west-2-dent-jenkins-1.ci.codeaurora.org               u,u,u
```

**Server Certificates:**

```
Certificate Nickname                                         Trust Attributes
                                                             SSL,S/MIME,JAR/XPI

easyrsa                                                      CT,,
aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org          u,u,u
```

**Certificate Authority (easyrsa):**

```
Subject: CN=EasyRSA
Serial: 00:da:99:94:06:33:56:82:24
Valid: 2020-08-13 to 2030-08-11
Trust Flags: CT,, (Valid CA, Trusted CA, Trusted Client CA)
Key Usage: Certificate Signing, CRL Signing
```

**Bridge Certificate (sigul-bridge-us-west-2.linuxfoundation.org):**

```
Subject: CN=sigul-bridge-us-west-2.linuxfoundation.org
Issuer: CN=EasyRSA
Serial: 43:44:91:4e:86:fe:10:ff:85:2a:cc:7f:1c:fa:b4:15
Valid: 2021-12-01 to 2031-11-29
Trust Flags: u,u,u (User trust)
Extended Key Usage: TLS Web Server Authentication, TLS Web Client Authentication
Key Usage: Digital Signature, Key Encipherment
Subject Alt Name: sigul-bridge-us-west-2.linuxfoundation.org
```

**Server Certificate (aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org):**

```
Subject: CN=aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org
Issuer: CN=EasyRSA
Serial: 00:e9:e6:e3:06:07:53:0d:a3:ea:4c:61:19:86:9a:15:06
Valid: 2021-03-03 to 2031-03-01
Trust Flags: u,u,u (User trust)
Extended Key Usage: TLS Web Server Authentication, TLS Web Client Authentication
Key Usage: Digital Signature, Key Encipherment
Subject Alt Name: aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org
```

**Critical Findings:**

1. **External CA (EasyRSA)**: Not self-signed, uses external CA infrastructure
2. **FQDN-based CNs**: All certificates use full domain names
3. **Subject Alternative Names**: Certificates include SAN matching CN
4. **Extended Key Usage**: Both server and client authentication
5. **Trust Flags**: CA is `CT,,` (trusted), certificates are `u,u,u` (user)
6. **Multiple Client Certs on Bridge**: Bridge has multiple client certificates (Jenkins instances)

### 18.6 GnuPG Directory Structure

**Location:** `/var/lib/sigul/gnupg/`

**Contents:**

```bash
drwx------. sigul sigul system_u:object_r:gpg_secret_t:s0 gnupg/
    -rw-------. sigul sigul pubring.gpg       # Public keyring
    -rw-------. sigul sigul pubring.gpg~      # Backup
    -rw-------. sigul sigul random_seed       # Entropy
    -rw-------. sigul sigul secring.gpg       # Secret keyring (GPG 1.x format)
    -rw-------. sigul sigul trustdb.gpg       # Trust database
```

**Key Observations:**

- Uses GPG 1.x format (`secring.gpg`) - legacy, will be GPG 2.x in containers
- Permissions: `0700` directory, `0600` files
- Owner: `sigul:sigul`
- SELinux context: `gpg_secret_t`
- Contains signing keys for actual RPM/artifact signing
- **Modernization Note:** GPG 2.x uses different keyring format but same directory location

### 18.7 SELinux Contexts

**Production uses SELinux in Enforcing mode:**

```bash
SELinux status: enabled
Current mode: enforcing
Policy: targeted
```

**File Contexts:**

```bash
# NSS databases:
/etc/pki/sigul/*.db         system_u:object_r:cert_t:s0
/etc/pki/sigul/*.p12        system_u:object_r:cert_t:s0
/etc/pki/sigul/*.txt        system_u:object_r:cert_t:s0

# Database:
/var/lib/sigul/server.sqlite   unconfined_u:object_r:sigul_var_lib_t:s0

# GnuPG:
/var/lib/sigul/gnupg/          system_u:object_r:gpg_secret_t:s0
```

**Container Implications:**

- Containers use Docker's security model, not SELinux
- File permissions (0700/0600) still critical for security
- File ownership mapping via UID/GID still required
- **Modernization Note:** Focus on file permissions, not SELinux contexts

### 18.8 File Ownership and Permissions

**NSS Database:**

```bash
# /etc/pki/sigul/
drwx------.  sigul sigul  /etc/pki/sigul/
-rw-------.  sigul sigul  cert8.db
-rw-------.  sigul sigul  key3.db
-rw-------.  sigul sigul  secmod.db
-rw-------.  sigul sigul  nss-password.txt
-rw-------.  sigul sigul  *.p12
```

**Database and GnuPG:**

```bash
# /var/lib/sigul/
drwx------.  sigul sigul  /var/lib/sigul/
-rw-r--r--.  sigul sigul  server.sqlite
drwx------.  sigul sigul  gnupg/
-rw-------.  sigul sigul  gnupg/*.gpg
```

**Key Observations:**

- NSS directory: `0700` (owner only)
- NSS files: `0600` (owner read/write only)
- Database: `0644` (world-readable) - likely for backup/monitoring
- GnuPG directory: `0700`
- GnuPG files: `0600`
- All owned by `sigul:sigul` (UID 994, GID 991)

### 18.9 Additional Infrastructure Components (OUT OF SCOPE)

**RabbitMQ Message Broker:**

```bash
rabbitmq 16882  /usr/lib64/erlang/erts-5.10.4/bin/beam.smp ...
  -sname rabbit@aws-us-west-2-lfit-sigul-bridge-1
  tcp_listeners [{"auto",5672}]
```

**Status:** Present on production hosts but **NOT USED BY SIGUL**

- No references to RabbitMQ in any Sigul configuration files
- No AMQP or messaging code in Sigul Python source
- RabbitMQ is for other services on the same hosts
- **Container stack does NOT need RabbitMQ**

### 18.10 Log Directory Structure

**Server Logs (per-bridge instance):**

```bash
/var/log/sigul-bridge-aws-us-west-2-lfit-sigul-bridge-1/
/var/log/sigul-bridge-aws-us-west-2-dent-sigul-bridge-1/
/var/log/sigul-bridge-aws-us-west-2-odpi-sigul-bridge-1/
```

**Confirms:** Server can communicate with multiple bridges simultaneously, each with separate logging.

### 18.11 Gap Analysis: Production Configuration vs Container

| Aspect | Production Pattern | Container Implementation | Priority |
|--------|-------------------|-------------------------|----------|
| **Python Version** | 2.7.5 (legacy) | 3.x (modern) | ✓ **MODERNIZATION OK** |
| **NSS Bindings** | python-nss | python3-nss | ✓ **MODERNIZATION OK** |
| **NSS Format** | cert8.db (legacy) | cert9.db (modern) | ✓ **MODERNIZATION OK** |
| **GPG Format** | GPG 1.x (legacy) | GPG 2.x (modern) | ✓ **MODERNIZATION OK** |
| **Config Path** | `/etc/sigul/` (FHS standard) | `/var/sigul/config/` (non-standard) | **CRITICAL - Must use FHS paths** |
| **NSS Database Path** | `/etc/pki/sigul/` (FHS standard) | `/var/sigul/nss/<component>/` (non-standard) | **CRITICAL - Must use FHS paths** |
| **Database Location** | `/var/lib/sigul/server.sqlite` | `/var/sigul/database/server.sqlite` | **CRITICAL - Wrong path** |
| **GnuPG Location** | `/var/lib/sigul/gnupg` | `/var/sigul/gnupg` | **CRITICAL - Wrong path** |
| **Bridge Startup** | Simple: `sigul_bridge -v` | Complex init script | **HIGH - Simplify** |
| **Server Startup** | Template: `server-%i.conf` | Single config | **MEDIUM - Add template support** |
| **Certificate CN** | FQDN-based | Generic short names | **HIGH - Use FQDNs** |
| **CA Type** | External (EasyRSA) | Self-signed bridge | **MEDIUM - Use external CA** |
| **File Permissions** | 0700/0600 | May differ | **MEDIUM - Enforce permissions** |
| **Multi-Bridge Support** | Yes (via templates) | No | **LOW - Single bridge OK for testing** |

**Configuration-Critical Issues (Must Fix):**

1. **Wrong FHS paths** - Use `/etc/sigul/`, `/etc/pki/sigul/`, `/var/lib/sigul/`
2. **Certificate CNs** - Use FQDN-based names, not generic
3. **Complex initialization** - Simplify to match production pattern
4. **Database/GnuPG locations** - Use standard `/var/lib/sigul/` paths

**Version Differences (Modernization - OK):**

1. Python 3 vs Python 2 - Modern replacement appropriate
2. cert9.db vs cert8.db - Modern NSS format appropriate
3. GPG 2.x vs GPG 1.x - Modern GPG appropriate
4. Current packages vs legacy - Updates appropriate

---

## 19. Recommendations for Next Steps

### 19.1 Discovery Phase (Before Making Changes)

1. **Verify NSS Format Expectation**
   - Determine which NSS format the Sigul binaries expect
   - Check Sigul source code for NSS database access patterns
   - Test if Python NSS bindings work with both formats
   - **Action**: May need to use legacy NSS format (cert8.db)

2. **Analyze Production Sigul Binary**
   - Check which NSS libraries production binaries link against
   - Verify NSS version on production systems
   - Identify any hardcoded paths
   - **Action**: Reproduce exact production environment

3. **Configuration Parser Analysis**
   - Test Sigul config parser with container-generated configs
   - Identify which config options are required vs optional
   - Determine separator sensitivity (colon vs equals)
   - **Action**: May need to match production format exactly

4. **Certificate Chain Validation**
   - Understand how Sigul validates certificate chains
   - Test if self-signed CA works or requires external CA
   - Verify certificate subject requirements
   - **Action**: May need external CA or specific cert attributes

5. **Test DNS and Hostname Resolution**
   - Determine if Sigul validates certificate nicknames against hostnames
   - Check if LDAP is required for authentication
   - Test if short names vs FQDNs affect validation
   - **Action**: May need to add /etc/hosts in containers or use FQDN-based cert nicknames

### 18.2 Alignment Strategy

**Option A: Mirror Production Exactly**

- Use legacy NSS format (cert8.db, key3.db, secmod.db)
- Match all directory paths (`/etc/sigul/`, `/etc/pki/sigul/`, `/var/lib/sigul/`)
- Use PKCS#12 certificate distribution
- Match configuration format precisely (colon separators, sections)
- Pre-generate certificates before container build

**Option B: Hybrid Approach**

- Keep modern NSS format but verify compatibility
- Align critical paths (database, GPG, config locations)
- Keep on-the-fly certificate generation but fix nicknames
- Fix configuration to match production structure
- Maintain container-friendly initialization

**Option C: Minimal Change**

- Fix only blocking issues (paths, database location)
- Keep current architecture but align critical configs
- Test incrementally

### 19.3 Recommended Approach

**Phase 1: Critical Path Fixes (Blocking Issues)**

1. Align database path to `/var/lib/sigul/server.sqlite`
2. Align GnuPG path to `/var/lib/sigul/gnupg`
3. Align config paths to `/etc/sigul/<role>.conf`
4. Align NSS path to `/etc/pki/sigul/` (shared)
5. Configure proper hostnames/FQDNs for certificate validation
6. Test if services start successfully

**Phase 2: NSS Format Decision**

1. Test modern NSS format compatibility
2. If incompatible, migrate to legacy format
3. Update initialization scripts accordingly
4. Verify certificate operations work

**Phase 3: Configuration Alignment**

1. Match configuration format (separators, sections)
2. Remove extra sections not in production
3. Add missing TLS configuration
4. Embed passwords directly (like production)
5. Use hostname-based certificate nicknames

**Phase 4: Certificate Management**

1. Consider PKCS#12 workflow
2. Or verify on-the-fly generation works with correct nicknames
3. Ensure trust chains match production
4. Test certificate persistence across restarts

**Phase 5: Integration Testing**

1. Test basic operations (user creation, key generation)
2. Test signing operations
4. Test multi-bridge configurations
5. Stress test under load
6. Test LDAP integration if required

---

## 20. Modernization Strategy

### 20.1 Version Modernization is Appropriate

The production system uses **legacy software** (Python 2.7, cert8.db NSS format, GPG 1.x) that is outdated and should be replaced:

**Legacy Production Stack (2020-2021 era):**

- Python 2.7.5 (EOL January 2020)
- python-nss 0.16.0 (Python 2 bindings)
- NSS cert8.db format (pre-2018)
- GPG 1.x keyring format
- Sigul 0.207 (2017 release)

**Modern Container Stack (2025):**

- Python 3.9+ (current, supported)
- python3-nss (Python 3 bindings)
- NSS cert9.db format (current)
- GPG 2.x keyring format
- Current Sigul with Python 3 support

### 20.2 What to Modernize vs What to Preserve

**Modernize (Version Upgrades):**

- ✓ Python 2 → Python 3
- ✓ cert8.db → cert9.db
- ✓ GPG 1.x → GPG 2.x
- ✓ Legacy packages → Current packages
- ✓ Old NSS version → Current NSS

**Preserve (Configuration Patterns):**

- ✗ Directory paths: `/etc/sigul/`, `/etc/pki/sigul/`, `/var/lib/sigul/`
- ✗ Configuration structure: sections, key names
- ✗ Startup patterns: simple invocation, systemd templates
- ✗ Certificate naming: FQDN-based CNs
- ✗ CA model: external CA, not self-signed
- ✗ File permissions: 0700/0600 security model

### 20.3 Modern Sigul with Python 3

**Sigul Python 3 Support:**

- Sigul has been ported to Python 3 (check upstream)
- python3-nss provides modern bindings
- Modern NSS (cert9.db) fully supported
- Configuration syntax remains compatible

**Action Items:**

1. Use current Sigul version with Python 3 support
2. Use python3-nss package
3. Keep configuration file structure from production
4. Use modern cert9.db format at standard paths
5. Maintain production's directory layout

### 20.4 Recommended Approach

**Container Base:**

- Use current UBI 9 or similar modern base
- Install Python 3 and python3-nss
- Install current Sigul version
- Use modern cert9.db NSS format

**Configuration:**

- Use production's directory structure (FHS paths)
- Adapt configuration syntax for Python 3/modern packages if needed
- Maintain production's certificate naming patterns
- Keep production's file permission model

**Result:** Modern, supportable stack with production-proven configuration patterns

---

### C.1 Bridge Configuration Side-by-Side

**Production:**

```ini
[bridge]
bridge-cert-nickname: sigul-bridge-us-west-2.linuxfoundation.org
client-listen-port: 44334
server-listen-port: 44333

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: /etc/pki/sigul
nss-password: uFMLuCUpppkfV+GLqjv8W7ptCoV3z8li
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

**Container:**

```ini
[nss]
nss-dir = /var/sigul/nss/bridge
nss-password = <generated>

[bridge]
bridge-cert-nickname = sigul-bridge-cert
client-listen-port = 44334
server-listen-port = 44333
max-file-payload-size = 67108864
required-fas-group =

[bridge-server]
nss-dir = sql:/var/sigul/nss/bridge
nss-password-file = /var/sigul/secrets/nss-password
ca-cert-nickname = sigul-ca
bridge-cert-nickname = sigul-bridge-cert
server-hostname = sigul-server
server-port = 44333
require-tls = true

[daemon]
unix-user =
unix-group =
```

### C.2 Server Configuration Side-by-Side

**Production:**

```ini
[server]
bridge-hostname: sigul-bridge-us-west-2.linuxfoundation.org
bridge-port: 44333
max-file-payload-size: 1073741824
max-memory-payload-size: 1048576
max-rpms-payload-size: 10737418240
server-cert-nickname: aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org
signing-timeout: 60

[database]
database-path: /var/lib/sigul/server.sqlite

[gnupg]
gnupg-home: /var/lib/sigul/gnupg
gnupg-key-type: RSA
gnupg-key-length: 2048
gnupg-key-usage: sign
passphrase-length: 64

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: /etc/pki/sigul
nss-password: uFMLuCUpppkfV+GLqjv8W7ptCoV3z8li
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

**Container:**

```ini
[nss]
nss-dir = /var/sigul/nss/server
nss-password = <generated>

[server]
database-path = /var/sigul/database/server.sqlite
nss-dir = sql:/var/sigul/nss/server
nss-password-file = /var/sigul/secrets/nss-password
ca-cert-nickname = sigul-ca
server-cert-nickname = sigul-server-cert
bridge-hostname = sigul-bridge
bridge-port = 44333
require-tls = true
gnupg-home = /var/sigul/gnupg
log-level = INFO
log-file = /var/sigul/logs/server.log

[daemon]
unix-user =
unix-group =
```

---

## 22. Appendix A: Production Sigul Commands Reference

This appendix documents the exact commands and scripts used in production for reference.

### A.1 Sigul Binary Locations and Usage

**Bridge:**

```bash
/usr/sbin/sigul_bridge -v
# Wrapper script that invokes:
/usr/bin/python /usr/share/sigul/bridge.py -v
```

**Server:**

```bash
/usr/sbin/sigul_server -c /etc/sigul/server-<instance>.conf --internal-log-dir=/var/log/sigul-<instance> --internal-pid-dir=/run/sigul-<instance> -v
# Wrapper script that invokes:
/usr/bin/python /usr/share/sigul/server.py -c <config> --internal-log-dir=<dir> --internal-pid-dir=<dir> -v
```

**Database Management:**

```bash
/usr/sbin/sigul_server_create_db -c <config>    # Create database schema
/usr/sbin/sigul_server_add_admin -c <config>    # Add admin user
```

### A.2 NSS Database Commands

**List certificates:**

```bash
certutil -L -d /etc/pki/sigul
certutil -L -d /etc/pki/sigul -n "certificate-nickname"
certutil -L -d /etc/pki/sigul -n "certificate-nickname" -a  # Export as ASCII
```

**Database locations:**

```bash
# Legacy format (production):
/etc/pki/sigul/cert8.db
/etc/pki/sigul/key3.db
/etc/pki/sigul/secmod.db

# Modern format (containers):
/etc/pki/sigul/cert9.db
/etc/pki/sigul/key4.db
/etc/pki/sigul/pkcs11.txt
```

### A.3 Service Management

**Systemd commands:**

```bash
systemctl status sigul_bridge.service
systemctl status sigul_server@bridge-<instance>.service

systemctl start sigul_bridge.service
systemctl start sigul_server@bridge-<instance>.service
```

---

## 23. Appendix B: Complete Production Version Reference

**PURPOSE:** This appendix preserves complete version information from production systems for fallback scenarios. If modernized components fail, this data enables exact replication of the working production environment.

### B.1 Python and Core Dependencies

**Python Version (Production):**

```bash
Python 2.7.5
Command: /usr/bin/python
```

**Python NSS Bindings (Production):**

```bash
python-nss-0.16.0-3.el7.x86_64
```

**Python 3 Not Available:**

```bash
$ python3 --version
-bash: python3: command not found
```

### B.2 NSS Packages (Production)

**Complete NSS Package List:**

```bash
nss-3.90.0-2.el7_9.x86_64
nss-util-3.90.0-1.el7_9.x86_64
nss-softokn-3.90.0-6.el7_9.x86_64
nss-softokn-freebl-3.90.0-6.el7_9.x86_64
nss-tools-3.90.0-2.el7_9.x86_64
nss-pem-1.0.3-7.el7_9.1.x86_64
nss-sysinit-3.90.0-2.el7_9.x86_64
```

**Related Packages:**

```bash
jansson-2.10-1.el7.x86_64
```

### B.3 Sigul Packages (Production)

**Bridge Packages:**

```bash
sigul-0.207-1.el7.x86_64
```

**Bridge Package Contents:**

```bash
/etc/sigul/bridge.conf
/usr/lib/systemd/system/sigul_bridge.service
/usr/sbin/sigul_bridge
/usr/share/sigul/bridge.py
/usr/share/sigul/bridge.pyc
/usr/share/sigul/bridge.pyo
```

**Server Packages:**

```bash
sigul-0.207-1.el7.x86_64
sigul-server-0.207-1.el7.x86_64
```

**Server Package Contents:**

```bash
/etc/sigul/server.conf
/usr/lib/systemd/system/sigul_server.service
/usr/sbin/sigul_server
/usr/sbin/sigul_server_add_admin
/usr/sbin/sigul_server_create_db
/usr/share/sigul/server.py
/usr/share/sigul/server.pyc
/usr/share/sigul/server.pyo
/usr/share/sigul/server_add_admin.py
/usr/share/sigul/server_add_admin.pyc
/usr/share/sigul/server_add_admin.pyo
/usr/share/sigul/server_common.py
/usr/share/sigul/server_common.pyc
/usr/share/sigul/server_common.pyo
/usr/share/sigul/server_create_db.py
/usr/share/sigul/server_create_db.pyc
/usr/share/sigul/server_create_db.pyo
/var/lib/sigul
/var/lib/sigul/gnupg
```

**Additional Utilities:**

```bash
/usr/bin/sigul-ostree-helper
```

### B.4 NSS Database Format (Production)

**Legacy NSS Format Details:**

```bash
# Files in /etc/pki/sigul/:
cert8.db    - Size: 65536 bytes, format: SQLite 3.x (legacy)
key3.db     - Size: 16384 bytes, format: BerkeleyDB (legacy)
secmod.db   - Size: 16384 bytes, format: legacy security module DB

# These are NSS versions prior to 3.35 (circa 2018)
```

**Database Prefix:**

```bash
# Production may use no prefix or dbm: prefix
certutil -L -d /etc/pki/sigul
# or
certutil -L -d dbm:/etc/pki/sigul

# Modern format uses sql: prefix
certutil -L -d sql:/etc/pki/sigul
```

### B.5 GPG Version and Format (Production)

**GPG Keyring Format:**

```bash
# GPG 1.x format (legacy) in /var/lib/sigul/gnupg/:
pubring.gpg     - Public keyring (9205 bytes)
pubring.gpg~    - Backup (9205 bytes)
secring.gpg     - Secret keyring (17567 bytes) - GPG 1.x format
trustdb.gpg     - Trust database (1680 bytes)
random_seed     - Entropy (600 bytes)

# GPG 2.x uses different format:
# pubring.kbx, private-keys-v1.d/ directory
```

### B.6 Operating System (Production)

**OS Version:**

```bash
RHEL 7 / CentOS 7 (based on package versions)
Kernel: Linux (version not captured)
```

**Key OS Characteristics:**

- Python 2.7.5 system default
- Systemd service management
- SELinux enforcing mode
- Legacy NSS format support
- GPG 1.x keyring format

### B.7 Additional Infrastructure (Production)

**RabbitMQ Message Broker:**

```bash
rabbitmq-server-3.3.5
erlang-erts-5.10.4

Process:
/usr/lib64/erlang/erts-5.10.4/bin/beam.smp ...
  -sname rabbit@aws-us-west-2-lfit-sigul-bridge-1
  tcp_listeners [{"auto",5672}]
```

**Purpose:** Internal message passing for Sigul operations (confirmed running on production bridge).

### B.8 Certificate Authority (Production)

**CA Software:**

```bash
easyrsa (EasyRSA)
CA Certificate Serial: 00:da:99:94:06:33:56:82:24
Valid: 2020-08-13 to 2030-08-11
```

**CA Certificate Details:**

```
Subject: CN=EasyRSA
Issuer: CN=EasyRSA (self-signed)
Key Usage: Certificate Signing, CRL Signing
Trust Flags: CT,, (Valid CA, Trusted CA, Trusted Client CA)
```

### B.9 File Formats Summary (Production)

**NSS Database:**

- Format: cert8.db / key3.db / secmod.db (legacy)
- NSS Version: Pre-3.35 (requires older NSS libraries)
- Python Bindings: python-nss 0.16.0 (Python 2 only)

**GPG Keyring:**

- Format: secring.gpg (GPG 1.x)
- Location: /var/lib/sigul/gnupg/
- Incompatible with GPG 2.x format

**Database:**

- Format: SQLite 3
- File: server.sqlite (12288 bytes on production)
- Schema: 3 tables (keys, users, key_accesses)

### B.10 Fallback Strategy

**If Modern Stack Fails:**

1. **Use RHEL 7 / CentOS 7 base image:**

   ```dockerfile
   FROM centos:7
   ```

2. **Install exact production packages:**

   ```bash
   yum install -y python-2.7.5
   yum install -y python-nss-0.16.0-3.el7
   yum install -y sigul-0.207-1.el7
   yum install -y sigul-server-0.207-1.el7
   yum install -y nss-3.90.0-2.el7_9
   ```

3. **Use legacy NSS format:**

   ```bash
   certutil -N -d /etc/pki/sigul  # Creates cert8.db format
   ```

4. **Replicate production paths exactly:**
   - `/etc/sigul/` for configs
   - `/etc/pki/sigul/` for NSS databases
   - `/var/lib/sigul/` for database and GPG

5. **Match production startup commands:**

   ```bash
   /usr/sbin/sigul_bridge -v
   /usr/sbin/sigul_server -c /etc/sigul/server-<instance>.conf --internal-log-dir=/var/log/sigul-<instance> --internal-pid-dir=/run/sigul-<instance> -v
   ```

**Note:** This fallback should only be used for testing/validation. The goal remains modernization with Python 3, current NSS, and current Sigul.

---

## 24. Production Extraction Key Findings (2025-11-16)

This section documents critical findings from the comprehensive production data extraction performed on both bridge and server hosts.

### 24.1 Production Service Startup (Actual Commands)

**Bridge Startup (from systemd service file):**

```bash
/usr/sbin/sigul_bridge -v
```

**Server Startup (from systemd template service):**

```bash
/usr/sbin/sigul_server -c /etc/sigul/server-%i.conf --internal-log-dir=/var/log/sigul-%i --internal-pid-dir=/run/sigul-%i -v
```

**Key Findings:**

- Bridge uses **default config path** (no `-c` flag) → expects `/etc/sigul/bridge.conf`
- Server uses **explicit config path** with systemd template (`%i` = instance name)
- Server creates **per-instance log and PID directories** (e.g., `/var/log/sigul-bridge-aws-us-west-2-lfit-sigul-bridge-1/`)
- Both use `-v` for verbose logging
- No wrapper scripts, initialization scripts, or complex startup logic
- Systemd handles process management (Type=simple, Restart=on-failure for server)

**Production Server Running Processes:**

```bash
sigul 9105 /usr/bin/python /usr/share/sigul/server.py -c /etc/sigul/server-bridge-aws-us-west-2-lfit-sigul-bridge-1.conf --internal-log-dir=/var/log/sigul-bridge-aws-us-west-2-lfit-sigul-bridge-1 --internal-pid-dir=/run/sigul-bridge-aws-us-west-2-lfit-sigul-bridge-1 -v
```

### 24.2 Configuration Format Verification

**ConfigParser Test Results (Both Hosts):**

- **Colon format (`:`)**: SUCCESS - works in Python 2 ConfigParser
- **Equals format (`=`)**: SUCCESS - works in Python 2 ConfigParser
- **Conclusion**: Both separators are functionally equivalent in Python 2's ConfigParser

**Production Uses Colon Format:**

- All production configs consistently use `key: value` format
- No mixing of formats within files
- Comments use `#` prefix

### 24.3 Certificate Details (Verified from NSS Database)

**Server Certificate (`aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org`):**

- **Serial**: e9:e6:e3:06:07:53:0d:a3:ea:4c:61:19:86:9a:15:06
- **Issuer**: CN=EasyRSA
- **Validity**: 2021-03-03 to 2031-03-01 (10 years)
- **Subject CN**: aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org
- **Subject Alt Name (SAN)**: DNS:aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org
- **Extended Key Usage**: TLS Web Server Authentication, TLS Web Client Authentication
- **Key Usage**: Digital Signature, Key Encipherment
- **Public Key**: RSA 2048-bit
- **Trust Flags**: `u,u,u` (user certificate)

**Bridge Certificate (`sigul-bridge-us-west-2.linuxfoundation.org`):**

- **Serial**: 43:44:91:4e:86:fe:10:ff:85:2a:cc:7f:1c:fa:b4:15
- **Issuer**: CN=EasyRSA
- **Validity**: 2021-12-01 to 2031-11-29 (10 years)
- **Subject CN**: sigul-bridge-us-west-2.linuxfoundation.org
- **Subject Alt Name (SAN)**: DNS:sigul-bridge-us-west-2.linuxfoundation.org
- **Extended Key Usage**: TLS Web Server Authentication, TLS Web Client Authentication
- **Key Usage**: Digital Signature, Key Encipherment
- **Public Key**: RSA 2048-bit
- **Trust Flags**: `u,u,u` (user certificate)

**CA Certificate (`easyrsa`):**

- **Issuer/Subject**: CN=EasyRSA (self-signed CA)
- **Trust Flags**: `CT,,` (trusted CA for SSL)
- Used to sign all component and client certificates

**Critical Pattern:**

- CN and SAN both contain the **full FQDN**
- No short hostnames in certificates
- Both Server Authentication and Client Authentication EKU present
- All certificates signed by same external CA

### 24.4 DNS and Name Resolution (Production)

**From `/etc/hosts` (Sigul-related entries):**

```
10.30.118.172    aws-us-west-2-lfit-sigul-server-1.dr.codeaurora.org    aws-us-west-2-lfit-sigul-server-1
10.30.118.134    aws-us-west-2-lfit-sigul-bridge-1.dr.codeaurora.org    aws-us-west-2-lfit-sigul-bridge-1
10.30.118.134    sigul-bridge-us-west-2.linuxfoundation.org
```

**Key Findings:**

- Uses **private IP addresses** (10.30.x.x subnet)
- FQDN is the **primary hostname**
- Short names are aliases
- Bridge has **two FQDNs** pointing to same IP (old and new naming scheme)
- Server config references bridge by FQDN: `bridge-hostname: sigul-bridge-us-west-2.linuxfoundation.org`

**nsswitch.conf:**

```
hosts: files dns myhostname
```

- Checks `/etc/hosts` first, then DNS, then hostname

### 24.5 File Permissions and Ownership

**Configuration Files (`/etc/sigul/`):**

- **Owner**: `sigul:sigul`
- **Server configs**: `600` (owner read/write only)
- **client.conf**: `644` (world-readable)
- **SELinux context**: `system_u:object_r:sigul_conf_t:s0`

**NSS Database (`/etc/pki/sigul/`):**

- **Owner**: `sigul:sigul`
- **Permissions**: `600` for database files
- **SELinux context**: `system_u:object_r:cert_t:s0`

**Data Directory (`/var/lib/sigul/`):**

- **Owner**: `sigul:sigul`
- **Permissions**: `700` for directories, `600` for files
- **Database**: `server.sqlite` (12288 bytes on production)
- **SELinux context**: `system_u:object_r:sigul_var_lib_t:s0`

### 24.6 Database Schema (Production)

**Tables:**

1. **keys**: Stores GPG key metadata
   - `id` (INTEGER PRIMARY KEY)
   - `name` (TEXT NOT NULL UNIQUE)
   - `fingerprint` (TEXT NOT NULL UNIQUE)

2. **users**: Stores Sigul user accounts
   - `id` (INTEGER PRIMARY KEY)
   - `name` (TEXT NOT NULL UNIQUE)
   - `sha512_password` (BLOB) - SHA-512 hashed passwords
   - `admin` (BOOLEAN NOT NULL)

3. **key_accesses**: Links users to keys with encrypted passphrases
   - `id` (INTEGER PRIMARY KEY)
   - `key_id` (INTEGER NOT NULL, FOREIGN KEY → keys.id)
   - `user_id` (INTEGER NOT NULL, FOREIGN KEY → users.id)
   - `encrypted_passphrase` (BLOB NOT NULL) - GPG passphrase encrypted for user
   - `key_admin` (BOOLEAN NOT NULL)
   - UNIQUE constraint on (key_id, user_id)

**Key Security Pattern:**

- User passwords are SHA-512 hashed
- GPG key passphrases are encrypted per-user (not stored in plaintext)
- Access control at database level (user must have key_accesses entry)

### 24.7 Logging Structure

**Log Directories:**

- `/var/log/sigul-bridge-<instance-name>/sigul_server.log` (server logs, one per bridge instance)
- `/var/log/sigul_bridge.log` (bridge logs)
- `/var/log/sigul_server.log` (fallback server log)

**Production has multiple server instances:**

- `sigul-bridge-aws-us-west-2-dent-sigul-bridge-1/`
- `sigul-bridge-aws-us-west-2-lfit-sigul-bridge-1/`
- `sigul-bridge-aws-us-west-2-odpi-sigul-bridge-1/`

**Log Rotation:**

- Weekly rotation (`.log-YYYYMMDD.gz` pattern)
- Compressed archives kept for several months

### 24.8 Multi-Bridge Architecture

**Production server hosts THREE bridge connections simultaneously:**

1. `server-bridge-aws-us-west-2-dent-sigul-bridge-1.conf` → DENT bridge
2. `server-bridge-aws-us-west-2-lfit-sigul-bridge-1.conf` → LFIT bridge
3. `server-bridge-aws-us-west-2-odpi-sigul-bridge-1.conf` → ODPI bridge

**Implementation:**

- Systemd template unit: `sigul_server@.service`
- Instance name passed to service: `sigul_server@bridge-<name>.service`
- Each instance has separate:
  - Config file
  - Log directory
  - PID directory
  - Running process

**Container Implications:**

- Container stack only supports **single bridge** per server
- Production pattern allows horizontal scaling (multiple bridges)
- Consider supporting multiple bridge configs in container design

### 24.9 NSS Password Storage

**Critical Finding:** NSS password is **NOT** stored in separate file (`nss-password.txt`).

**Actual Storage:**

- Password stored directly in config files as `nss-password: <plaintext>`
- Same password shared between bridge and server on same host
- Permissions (`600`) protect config file from unauthorized access

**Container Implementation Issue:**

- Containers use separate `/var/sigul/secrets/nss-password` file
- May cause password lookup failures if Sigul expects config-based password
- Need to verify if Sigul supports file-based password loading

### 24.10 TLS Configuration

**Production TLS Settings (Both Bridge and Server):**

```ini
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

**Key Finding:**

- TLS 1.2 is **explicitly enforced** (min and max set to same version)
- No TLS 1.0, 1.1, or 1.3 support
- Ensures consistent security baseline

**Modernization Consideration:**

- Could update to TLS 1.3 for new deployment
- Would need to verify Sigul/NSS compatibility with TLS 1.3

### 24.11 GnuPG Configuration (Server Only)

**Production Server GnuPG Settings:**

```ini
[gnupg]
gnupg-home: /var/lib/sigul/gnupg
gnupg-key-type: RSA
gnupg-key-length: 2048
gnupg-key-usage: sign
passphrase-length: 64
```

**Key Findings:**

- GPG home at standard location `/var/lib/sigul/gnupg`
- RSA 2048-bit keys for signing operations
- 64-character passphrases (strong security)
- Bridge does NOT have GnuPG directory (signing only happens on server)

### 24.12 Components Confirmed NOT Used

**From Source Code Analysis and Config Review:**

1. **RabbitMQ:**
   - Process running on host (`rabbitmq 26538`)
   - **No AMQP imports** in Sigul source code
   - **No RabbitMQ references** in any Sigul config
   - Conclusion: RabbitMQ used by other services on host, NOT by Sigul

2. **LDAP:**
   - DNS entries for LDAP servers present
   - **No LDAP config** in Sigul files
   - **No LDAP authentication code** in source
   - Conclusion: No LDAP integration

3. **Koji/FAS:**
   - Empty `[koji]` section in bridge.conf
   - **No Koji parameters** configured
   - Conclusion: Koji integration disabled/unused

### 24.13 Critical Gaps Summary

**Based on Production Extraction, Container Stack MUST Fix:**

1. **Directory Paths:**
   - Use `/etc/sigul/` for configs (NOT `/var/sigul/config/`)
   - Use `/etc/pki/sigul/` for NSS database (NOT `/var/sigul/nss/`)
   - Use `/var/lib/sigul/` for database and GPG (NOT `/var/sigul/database/` or `/var/sigul/gnupg/`)

2. **Configuration:**
   - Store NSS password in config files (NOT separate password file)
   - Use colon separator format (for consistency with production)
   - Include all production config sections ([gnupg], resource limits, TLS settings)

3. **Certificates:**
   - CN and SAN must both contain FQDN
   - Include both Server and Client Authentication EKU
   - Use Key Usage: Digital Signature, Key Encipherment
   - Single CA certificate with trust flags `CT,,`

4. **Service Startup:**
   - Bridge: `/usr/sbin/sigul_bridge -v` (no config path needed)
   - Server: `/usr/sbin/sigul_server -c /etc/sigul/server-<name>.conf --internal-log-dir=/var/log/sigul-<name> --internal-pid-dir=/run/sigul-<name> -v`
   - No initialization scripts or wrappers

5. **DNS Resolution:**
   - Use FQDN for `bridge-hostname` in server config
   - Ensure bridge hostname resolves (via Docker DNS or /etc/hosts)
   - Match FQDN to certificate CN/SAN exactly

---

## 25. Prioritized Action Plan Based on Production Extraction

This section provides a prioritized, actionable plan to fix the containerized stack based on verified production data.

### 25.1 Phase 1: Critical Path Fixes (Must Fix First)

**1. Fix Directory Structure (Highest Priority)**

Replace non-standard paths with FHS-compliant paths:

```dockerfile
# In Dockerfile - create standard directories
RUN mkdir -p /etc/sigul \
    /etc/pki/sigul \
    /var/lib/sigul/gnupg \
    /var/log/sigul
```

```yaml
# In docker-compose.yml - update volume mounts
volumes:
  - ./configs/bridge.conf:/etc/sigul/bridge.conf:ro
  - ./configs/server.conf:/etc/sigul/server.conf:ro
  - sigul_nss_data:/etc/pki/sigul
  - sigul_server_data:/var/lib/sigul
```

**2. Fix NSS Password Storage**

Move NSS password from separate file into config files:

```ini
# In bridge.conf and server.conf
[nss]
nss-dir: /etc/pki/sigul
nss-password: <generate-strong-password>
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

Remove references to `/var/sigul/secrets/nss-password` file.

**3. Fix Certificate Generation**

Update certificate generation to match production pattern:

```bash
# Generate certificates with FQDN CNs and SANs
BRIDGE_FQDN="sigul-bridge.example.org"
SERVER_FQDN="sigul-server.example.org"

# CA certificate
certutil -S -n "CA" -s "CN=Sigul CA" -x -t "CT,," -k rsa -g 2048 -d /etc/pki/sigul

# Bridge certificate
certutil -S -n "${BRIDGE_FQDN}" -s "CN=${BRIDGE_FQDN}" \
  -c "CA" -t "u,u,u" -k rsa -g 2048 -d /etc/pki/sigul \
  --extKeyUsage serverAuth,clientAuth \
  --keyUsage digitalSignature,keyEncipherment \
  -8 "${BRIDGE_FQDN}"

# Server certificate
certutil -S -n "${SERVER_FQDN}" -s "CN=${SERVER_FQDN}" \
  -c "CA" -t "u,u,u" -k rsa -g 2048 -d /etc/pki/sigul \
  --extKeyUsage serverAuth,clientAuth \
  --keyUsage digitalSignature,keyEncipherment \
  -8 "${SERVER_FQDN}"
```

**4. Simplify Service Startup**

Replace initialization scripts with direct command invocation:

```dockerfile
# Bridge entrypoint
CMD ["/usr/sbin/sigul_bridge", "-v"]

# Server entrypoint
CMD ["/usr/sbin/sigul_server", "-c", "/etc/sigul/server.conf", \
     "--internal-log-dir=/var/log/sigul-default", \
     "--internal-pid-dir=/run/sigul-default", "-v"]
```

### 25.2 Phase 2: Configuration Alignment

**1. Update Bridge Configuration**

Match production bridge.conf structure:

```ini
# /etc/sigul/bridge.conf
[bridge]
bridge-cert-nickname: sigul-bridge.example.org
client-listen-port: 44334
server-listen-port: 44333

[koji]

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: /etc/pki/sigul
nss-password: <password>
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

**2. Update Server Configuration**

Match production server.conf structure:

```ini
# /etc/sigul/server.conf
[server]
bridge-hostname: sigul-bridge.example.org
bridge-port: 44333
max-file-payload-size: 1073741824
max-memory-payload-size: 1048576
max-rpms-payload-size: 10737418240
server-cert-nickname: sigul-server.example.org
signing-timeout: 60

[database]
database-path: /var/lib/sigul/server.sqlite

[gnupg]
gnupg-home: /var/lib/sigul/gnupg
gnupg-key-type: RSA
gnupg-key-length: 2048
gnupg-key-usage: sign
passphrase-length: 64

[daemon]
unix-user: sigul
unix-group: sigul

[nss]
nss-dir: /etc/pki/sigul
nss-password: <password>
nss-min-tls: tls1.2
nss-max-tls: tls1.2
```

**3. Fix DNS Resolution**

Ensure bridge hostname resolves to FQDN:

```yaml
# docker-compose.yml
services:
  sigul-bridge:
    hostname: sigul-bridge.example.org
    networks:
      sigul-network:
        aliases:
          - sigul-bridge.example.org

  sigul-server:
    hostname: sigul-server.example.org
    extra_hosts:
      - "sigul-bridge.example.org:172.20.0.2"  # Bridge IP
```

### 25.3 Phase 3: Testing and Validation

**1. Verify Directory Structure**

```bash
# Inside containers
ls -la /etc/sigul/
ls -la /etc/pki/sigul/
ls -la /var/lib/sigul/
```

Expected output should match production structure.

**2. Verify Certificate Trust**

```bash
# List certificates
certutil -L -d /etc/pki/sigul/

# Should show:
# CA                CT,,
# sigul-bridge.example.org    u,u,u
# sigul-server.example.org    u,u,u
```

**3. Verify Network Connectivity**

```bash
# Bridge should listen on both ports
netstat -tlnp | grep 44333
netstat -tlnp | grep 44334

# Server should have outbound connection to bridge
netstat -tnp | grep 44333
```

**4. Test Database Creation**

```bash
# Verify database location
ls -la /var/lib/sigul/server.sqlite

# Check schema
sqlite3 /var/lib/sigul/server.sqlite ".schema"
```

### 25.4 Phase 4: Modern Stack Verification

After fixes are applied with standard paths, verify modernization works:

**1. Python 3 Compatibility**

- Verify `python3-nss` package is available
- Test config file parsing with Python 3
- Verify NSS database operations work

**2. Modern NSS Format (cert9.db)**

- Test creating cert9.db instead of cert8.db
- Verify certificate operations work
- Ensure trust flags are properly set

**3. GPG 2.x Compatibility**

- Verify GPG 2.x can use `/var/lib/sigul/gnupg` directory
- Test key generation with modern GPG
- Verify signing operations work

### 25.5 Success Criteria

The containerized stack should demonstrate:

1. **Directory Structure**: All paths match production FHS layout
2. **Configuration**: Files parse correctly, passwords load from configs
3. **Certificates**: FQDN-based certs with proper EKU and trust flags
4. **Network**: Bridge listens on 44333/44334, server connects successfully
5. **Database**: Created at `/var/lib/sigul/server.sqlite` with correct schema
6. **Service Startup**: Simple direct invocation without errors
7. **TLS Connection**: Server-bridge connection establishes successfully
8. **Basic Operations**: Key creation, signing, and verification work

### 25.6 Troubleshooting Guide

**Issue: Config file not found**

- Verify files are in `/etc/sigul/` (not `/var/sigul/config/`)
- Check file permissions (should be `sigul:sigul`, mode `600`)

**Issue: NSS database not found**

- Verify database is in `/etc/pki/sigul/` (not `/var/sigul/nss/`)
- Check NSS_DATABASE env var is not set (should use default path)

**Issue: Certificate validation fails**

- Verify CN matches hostname in `bridge-hostname` config
- Check SAN includes the FQDN
- Verify trust flags: CA=`CT,,`, components=`u,u,u`

**Issue: Server can't connect to bridge**

- Verify bridge hostname resolves via Docker DNS or /etc/hosts
- Check bridge is listening on `0.0.0.0:44333`
- Verify no firewall rules blocking connection

**Issue: Database not created**

- Verify `/var/lib/sigul/` directory exists with correct permissions
- Check `database-path` in server config points to correct location
- Verify sigul user has write access to directory

---

## 26. Appendix C: Key File Comparisons

The containerized Sigul deployment has **configuration and architectural differences** from the production setup that prevent it from functioning. The analysis reveals that while production uses legacy software (Python 2, old NSS format), the critical issues are **configuration patterns and file locations**, not software versions.

### Critical Configuration Issues (Must Fix)

1. **Directory structure misalignment** - Container uses `/var/sigul/*` instead of standard FHS paths - **BLOCKING**
2. **Database location mismatch** - `/var/sigul/database/` instead of `/var/lib/sigul/` - **BLOCKING**
3. **NSS database location** - `/var/sigul/nss/<component>/` instead of `/etc/pki/sigul/` - **BLOCKING**
4. **GnuPG location mismatch** - `/var/sigul/gnupg` instead of `/var/lib/sigul/gnupg` - **BLOCKING**
5. **Configuration file location** - `/var/sigul/config/` instead of `/etc/sigul/` - **CRITICAL**
6. **Certificate naming** - Generic names instead of FQDN-based - **HIGH**
7. **Certificate authority model** - Self-signed instead of external CA - **HIGH**
8. **Complex initialization** - Custom scripts instead of simple direct invocation - **MEDIUM**

### Version Differences (Modernization Appropriate)

1. ✓ **Python 2 vs Python 3** - Container should use Python 3 (modern, supported)
2. ✓ **cert8.db vs cert9.db** - Container should use cert9.db (modern NSS format)
3. ✓ **GPG 1.x vs GPG 2.x** - Container should use GPG 2.x (current)
4. ✓ **Old packages vs current** - Container should use current versions

### Components Confirmed Out of Scope (No Action Required)

1. ✗ **RabbitMQ** - Present on hosts but not used by Sigul
2. ✗ **LDAP/OpenLDAP** - DNS entries only, no Sigul integration
3. ✗ **Koji/FAS** - Empty config sections, not actively used

### Path Forward

**Configuration Fixes (Critical):**

1. Use FHS-compliant paths: `/etc/sigul/`, `/etc/pki/sigul/`, `/var/lib/sigul/`
2. Simplify initialization to match production pattern
3. Use FQDN-based certificate naming
4. Implement external CA model (or proper self-signed CA)
5. Fix configuration file structure and sections

**Modernization (Appropriate):**

1. Use Python 3 with python3-nss
2. Use modern NSS format (cert9.db) at standard paths
3. Use current Sigul version with Python 3 support
4. Use GPG 2.x at standard location
5. Maintain production's configuration patterns with modern software

**Result:** A modern, containerized Sigul stack using current software versions but following production's proven configuration architecture and file layout patterns.

The key insight is that **configuration structure matters more than software versions**. Production uses outdated software (which should be upgraded), but has a working configuration pattern (which should be preserved).

---

**End of Gap Analysis**
