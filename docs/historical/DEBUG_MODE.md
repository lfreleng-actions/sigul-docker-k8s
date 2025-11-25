<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# DEBUG_MODE - Container Debugging Feature

## Overview

The Sigul bridge and server containers support a `DEBUG_MODE` environment variable that changes how the entrypoint script manages the sigul process.

## Modes

### Normal Mode (Production)
```bash
docker compose up
```

**Behavior:**
- Entrypoint uses `exec` to **replace itself** with the sigul process
- Sigul process becomes **PID 1** (proper signal handling)
- Entrypoint script exits after starting sigul
- Clean process tree, no monitoring overhead

**Use when:**
- Running in production
- You want proper signal handling (SIGTERM, SIGINT)
- You don't need to monitor the process after startup

### Debug Mode (Development)
```bash
DEBUG_MODE=1 docker compose up
```

**Behavior:**
- Entrypoint **forks** sigul process as a child
- Entrypoint remains active as PID 1
- Real-time log tailing to console
- Process exit monitoring with exit codes
- Final log summary on exit

**Use when:**
- Debugging startup issues
- Investigating why the process exits
- Need to see log output in real-time
- Want to capture process behavior after startup

## Usage Examples

### Enable DEBUG_MODE for specific service
```bash
# Bridge only
DEBUG_MODE=1 docker compose up bridge

# Server only
DEBUG_MODE=1 docker compose up server

# Both
DEBUG_MODE=1 docker compose up bridge server
```

### Add to docker-compose.yml temporarily
```yaml
services:
  bridge:
    environment:
      DEBUG_MODE: "1"  # Enable debug mode
```

### Add to .env file
```bash
echo "DEBUG_MODE=1" >> .env
docker compose up
```

## What DEBUG_MODE Shows

When enabled, you'll see:

1. **Warning on startup:**
   ```
   ⚠️  [HH:MM:SS] BRIDGE: DEBUG_MODE=1 detected
   ⚠️  [HH:MM:SS] BRIDGE: Entrypoint will fork sigul process and monitor it
   ⚠️  [HH:MM:SS] BRIDGE: This is useful for debugging but NOT recommended for production
   ```

2. **Process information:**
   ```
   🔵 [HH:MM:SS] BRIDGE: Bridge process started with PID: 123
   🔵 [HH:MM:SS] BRIDGE: Monitoring bridge process...
   🔵 [HH:MM:SS] BRIDGE: Log file: /var/log/sigul_bridge.log
   ```

3. **Real-time log streaming:**
   ```
   2025-01-15 10:30:45 INFO: 🚀 [BRIDGE] Sigul Bridge starting
   2025-01-15 10:30:45 INFO: 🔧 [LOGGING] Logging subsystem initialized
   2025-01-15 10:30:45 INFO: ✅ [BRIDGE] Configuration loaded successfully
   ```

4. **Exit information:**
   ```
   🔵 [HH:MM:SS] BRIDGE: Bridge process exited normally with code: 0
   ==========================================
   🔵 [HH:MM:SS] BRIDGE: Final log entries:
     2025-01-15 10:35:22 INFO: Last log message...
   ```

## Technical Details

### Signal Handling

DEBUG_MODE sets up signal forwarding:

```bash
# When you press Ctrl+C or send SIGTERM:
trap "kill -TERM $sigul_pid" TERM
trap "kill -INT $sigul_pid" INT
```

The entrypoint forwards signals to the sigul child process, ensuring graceful shutdown.

### Process Tree

**Normal Mode:**
```
Container
└── sigul_bridge (PID 1)
```

**Debug Mode:**
```
Container
├── entrypoint.sh (PID 1)
│   ├── sigul_bridge (child)
│   └── tail -f (log monitor)
```

### Exit Code Handling

The entrypoint captures and returns the sigul process exit code:

```bash
wait $sigul_pid
exit_code=$?
exit $exit_code
```

This ensures `docker compose` sees the correct exit status.

## Troubleshooting with DEBUG_MODE

### Problem: Container exits immediately
```bash
DEBUG_MODE=1 docker compose up bridge
```
**Look for:** Exit code and final log entries showing the cause

### Problem: Process starts but doesn't log
```bash
DEBUG_MODE=1 docker compose up bridge
```
**Look for:** Whether the log file exists and is being written

### Problem: Process crashes on connection
```bash
DEBUG_MODE=1 docker compose up
# Trigger connection in another terminal
docker compose exec client sigul list-users
```
**Look for:** Real-time log output showing the crash

## Limitations

- **Not for production:** DEBUG_MODE adds overhead and complexity
- **Signal handling:** Signals go to entrypoint first, then forwarded (small delay)
- **Process tree:** Sigul is not PID 1 (matters for some init-like behavior)

## Related Files

- `scripts/entrypoint-bridge.sh` - Bridge entrypoint with DEBUG_MODE support
- `scripts/entrypoint-server.sh` - Server entrypoint with DEBUG_MODE support
- `DEBUGGING_QUICK_REFERENCE.md` - General debugging guide

## Quick Commands

```bash
# Normal startup
docker compose up

# Debug bridge
DEBUG_MODE=1 docker compose up bridge

# Debug server
DEBUG_MODE=1 docker compose up server

# Debug everything
DEBUG_MODE=1 docker compose up

# Watch logs in real-time (normal mode)
docker compose logs -f bridge

# Exec into container
docker compose exec bridge bash
```
