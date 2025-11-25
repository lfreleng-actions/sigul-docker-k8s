<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Container Logging Configuration

**Last Updated:** 2025-11-24
**Status:** ✅ Production Ready

This document describes the logging configuration for Sigul containers, ensuring proper log output in both development and CI/CD environments.

---

## Table of Contents

- [Overview](#overview)
- [Log Levels and Verbosity](#log-levels-and-verbosity)
- [Container Configuration](#container-configuration)
- [Accessing Logs](#accessing-logs)
- [Troubleshooting](#troubleshooting)
- [CI/CD Considerations](#cicd-considerations)
- [Best Practices](#best-practices)

---

## Overview

All Sigul containers (bridge, server, client) use Python's logging subsystem with **dual output**:

1. **File logging:** `/var/log/sigul_<component>.log`
2. **Console logging:** stdout/stderr (captured by Docker)

Both outputs are active simultaneously, ensuring logs are available via:
- `docker compose logs`
- `docker logs <container>`
- Direct file access inside containers

---

## Log Levels and Verbosity

### Python Logging Configuration

Sigul uses a verbosity-based log level system defined in `src/utils.py`:

```python
def logging_level_from_options(options):
    '''Return a logging verbosity level depending on options.verbose'''
    if options.verbose <= 0:
        return logging.WARNING      # Default: only warnings and errors
    elif options.verbose == 1:
        return logging.INFO         # -v: informational messages
    else:  # options.verbose >= 2
        return logging.DEBUG        # -vv: debug messages
```

### Verbosity Flags

| Verbose Flag | Log Level | What Gets Logged | Use Case |
|--------------|-----------|------------------|----------|
| (none) | `WARNING` | Only warnings and errors | Production (quiet) |
| `-v` | `INFO` | Informational + warnings/errors | Normal operation |
| `-vv` | `DEBUG` | All messages including debug | Development/troubleshooting |

### Current Default Configuration

**All containers use `-vv` (DEBUG level) by default** for maximum visibility during development and CI/CD testing.

This is configured in the entrypoint scripts:
- `scripts/entrypoint-bridge.sh`
- `scripts/entrypoint-server.sh`

```bash
exec /usr/sbin/sigul_bridge \
    -c "$CONFIG_FILE" \
    -vv                    # ← DEBUG level logging
```

---

## Container Configuration

### Bridge Container

**Process:** `/usr/sbin/sigul_bridge`

**Log Files:**
- `/var/log/sigul_bridge.log` (inside container)
- Mounted volume: `sigul_bridge_logs:/var/log/sigul/bridge`

**Key Log Messages:**
```
🔧 [LOGGING] Logging subsystem initialized
🚀 [BRIDGE] Sigul Bridge starting
✅ [BRIDGE] Configuration loaded successfully
🔐 [BRIDGE] Initializing NSS
✅ [BRIDGE] NSS initialized successfully
🔌 [BRIDGE] Creating listen sockets
✅ [BRIDGE] Server listen socket created on port 44333
✅ [BRIDGE] Client listen socket created on port 44334
🎯 [BRIDGE] Bridge is ready to accept connections
```

### Server Container

**Process:** `/usr/sbin/sigul_server`

**Log Files:**
- `/var/log/sigul_server.log` (inside container)
- Mounted volume: `sigul_server_logs:/var/log/sigul/server`

**Key Log Messages:**
```
🔧 [LOGGING] Logging subsystem initialized
🚀 [SERVER] Sigul Server starting
✅ [SERVER] Configuration loaded successfully
🔐 [SERVER] Initializing NSS
✅ [SERVER] NSS initialized successfully
🎯 [SERVER] Connecting to bridge
```

### Client Container

**Process:** `/usr/bin/sigul` (CLI tool)

**Log Files:**
- Client typically logs to console only
- Debug output available with `sigul -v` or `sigul -vv`

---

## Accessing Logs

### View Real-Time Logs

```bash
# All services
docker compose -f docker-compose.sigul.yml logs -f

# Specific service
docker compose -f docker-compose.sigul.yml logs -f sigul-bridge
docker compose -f docker-compose.sigul.yml logs -f sigul-server

# Last 50 lines
docker compose -f docker-compose.sigul.yml logs --tail=50 sigul-bridge
```

### View Log Files Inside Container

```bash
# Bridge
docker compose -f docker-compose.sigul.yml exec sigul-bridge cat /var/log/sigul_bridge.log

# Server
docker compose -f docker-compose.sigul.yml exec sigul-server cat /var/log/sigul_server.log

# Tail in real-time
docker compose -f docker-compose.sigul.yml exec sigul-bridge tail -f /var/log/sigul_bridge.log
```

### View Logs from Volumes

```bash
# List log files in volume
docker run --rm -v sigul-docker_sigul_bridge_logs:/logs alpine ls -la /logs

# Cat log file from volume
docker run --rm -v sigul-docker_sigul_bridge_logs:/logs alpine cat /logs/sigul_bridge.log
```

### Export Logs for Analysis

```bash
# Export bridge logs
docker compose -f docker-compose.sigul.yml logs sigul-bridge > bridge.log

# Export all logs with timestamps
docker compose -f docker-compose.sigul.yml logs --timestamps > sigul-stack.log

# Export specific time range (last 1 hour)
docker compose -f docker-compose.sigul.yml logs --since 1h > recent.log
```

---

## Troubleshooting

### No Log Output

**Symptom:** Container runs but produces no logs

**Diagnosis:**
```bash
# Check if process is running
docker compose -f docker-compose.sigul.yml exec sigul-bridge ps aux

# Check log file exists and is writable
docker compose -f docker-compose.sigul.yml exec sigul-bridge ls -la /var/log/sigul_bridge.log

# Check verbosity flags are present
docker compose -f docker-compose.sigul.yml exec sigul-bridge ps aux | grep sigul_bridge
# Should show: /usr/sbin/sigul_bridge -c /etc/sigul/bridge.conf -vv
```

**Fixes:**
1. Ensure entrypoint script includes `-vv` flags
2. Verify log file ownership: `sigul:sigul` (UID/GID 1000)
3. Check Python bytecode ownership (should be `1000:1000`)

### Log File Permission Denied

**Symptom:** `ERROR: Cannot write to log file`

**Fix:**
```bash
# Inside container, verify ownership
docker compose -f docker-compose.sigul.yml exec sigul-bridge ls -la /var/log/

# Should show:
# drwxr-xr-x sigul sigul /var/log/sigul/
# -rw-r--r-- sigul sigul /var/log/sigul_bridge.log
```

If incorrect, rebuild container (fixed in Dockerfile).

### Only WARNING Level Logs

**Symptom:** Container runs but only shows warnings/errors, no INFO/DEBUG messages

**Cause:** Missing `-vv` flags in entrypoint

**Fix:**
1. Check entrypoint script has `-vv` flags
2. Rebuild container image
3. Restart stack

### Logs Not Visible in CI/CD

**Symptom:** GitHub Actions shows no logs from containers

**Causes:**
1. Container exits before logs are captured
2. Logs only written to file, not stdout
3. Log level too high (WARNING only)

**Fixes:**
1. Ensure `-vv` flags are present (enables DEBUG level)
2. Verify console handler is active in `utils.py:setup_logging()`
3. Use `docker compose logs` to capture stdout in CI
4. Add `sleep` or `wait` commands in tests to allow logs to flush

---

## CI/CD Considerations

### GitHub Actions Configuration

Ensure your workflow captures logs:

```yaml
- name: Start Sigul Stack
  run: |
    docker compose -f docker-compose.sigul.yml up -d

- name: Wait for services
  run: |
    sleep 10  # Allow services to start and log initialization

- name: Capture logs
  if: always()
  run: |
    docker compose -f docker-compose.sigul.yml logs > sigul-logs.txt

- name: Upload logs
  if: always()
  uses: actions/upload-artifact@v3
  with:
    name: sigul-logs
    path: sigul-logs.txt
```

### Debug Mode in CI

For enhanced debugging in CI environments, use `DEBUG_MODE=1`:

```yaml
- name: Start Sigul Stack with Debug Mode
  run: |
    DEBUG_MODE=1 docker compose -f docker-compose.sigul.yml up -d
```

This enables:
- Entrypoint remains active (not replaced by `exec`)
- Real-time log tailing to console
- Process monitoring and exit code capture
- Final log summary on exit

**Note:** `DEBUG_MODE` is for development/CI only, not production.

---

## Best Practices

### Development

1. **Use DEBUG level** (`-vv`) for all development work
2. **Check both outputs:** Console (Docker logs) and file (inside container)
3. **Use DEBUG_MODE** when debugging startup issues
4. **Tail logs in real-time** during testing:
   ```bash
   docker compose -f docker-compose.sigul.yml logs -f sigul-bridge
   ```

### Production

1. **Consider INFO level** (`-v`) for production to reduce log volume
2. **Configure log rotation** in docker-compose.yml:
   ```yaml
   services:
     sigul-bridge:
       logging:
         driver: "json-file"
         options:
           max-size: "10m"
           max-file: "3"
   ```
3. **Monitor log volumes** for disk space
4. **Do NOT use DEBUG_MODE** in production

### Testing

1. **Always capture logs** in test scripts:
   ```bash
   docker compose logs > test-logs.txt
   ```
2. **Check log output** for expected initialization messages
3. **Verify DEBUG level** is active (check for 🔧 emoji messages)
4. **Test log file accessibility** from volumes

---

## Log Message Reference

### Emoji Indicators

- 🔧 `[LOGGING]` - Logging subsystem messages
- 🚀 `[BRIDGE]` or `[SERVER]` - Main component startup
- ✅ Success messages (configuration loaded, NSS initialized, etc.)
- 🔐 `[NSS]` - NSS/certificate operations
- 🔌 `[SOCKET]` - Network socket operations
- 🎯 `[READY]` - Service ready to accept connections
- 🔄 `[REQUEST]` - Request processing
- ❌ Error messages
- ⚠️ Warning messages

### Critical Startup Messages

Every container should show these on successful startup:

1. `🔧 [LOGGING] Logging subsystem initialized`
2. `🚀 [COMPONENT] Starting`
3. `✅ [COMPONENT] Configuration loaded successfully`
4. `🔐 [COMPONENT] NSS initialized successfully`
5. Component-specific ready message

If any of these are missing, check:
- Log level (should be DEBUG with `-vv`)
- Configuration file present and valid
- NSS database present and accessible
- Certificate nicknames correct in config

---

## File Locations

### Source Code
- `sigul/src/utils.py` - Logging setup (`setup_logging()`, `logging_level_from_options()`)
- `sigul/src/bridge.py` - Bridge main entry point
- `sigul/src/server.py` - Server main entry point

### Scripts
- `scripts/entrypoint-bridge.sh` - Bridge entrypoint (adds `-vv`)
- `scripts/entrypoint-server.sh` - Server entrypoint (adds `-vv`)

### Configuration
- `/etc/sigul/bridge.conf` - Bridge configuration
- `/etc/sigul/server.conf` - Server configuration

### Log Files (Inside Containers)
- `/var/log/sigul_bridge.log` - Bridge logs
- `/var/log/sigul_server.log` - Server logs

### Docker Volumes
- `sigul_bridge_logs:/var/log/sigul/bridge`
- `sigul_server_logs:/var/log/sigul/server`

---

## Verification Checklist

Use this checklist to verify logging is working correctly:

- [ ] Containers start without errors
- [ ] `docker compose logs` shows log output
- [ ] Log files exist inside containers (`/var/log/sigul_*.log`)
- [ ] Log files are owned by `sigul:sigul` (UID/GID 1000)
- [ ] Log files are writable
- [ ] Initialization messages appear (🔧, 🚀, ✅)
- [ ] Log level is DEBUG (shows all messages)
- [ ] Console and file logs both contain output
- [ ] In CI: logs are captured and available as artifacts

---

## Related Documentation

- [DEBUG_MODE.md](../DEBUG_MODE.md) - Debug mode for advanced troubleshooting
- [DEBUGGING_QUICK_REFERENCE.md](DEBUGGING_QUICK_REFERENCE.md) - Quick debugging commands
- [TLS_DEBUGGING_GUIDE.md](TLS_DEBUGGING_GUIDE.md) - TLS-specific debugging

---

## Change Log

| Date | Change | Reason |
|------|--------|--------|
| 2025-11-24 | Initial documentation | Standardize logging configuration |
| 2025-11-24 | Added `-vv` default | Ensure DEBUG level in all environments |
| 2025-11-24 | Added CI/CD section | Support GitHub Actions logging |
