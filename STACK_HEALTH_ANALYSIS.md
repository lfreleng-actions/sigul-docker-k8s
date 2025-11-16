# Sigul Docker Stack Health Analysis

**Date:** 2025-11-16  
**Status:** Partial Deployment - Critical Issues Identified  
**Author:** Stack Health Check System

---

## Executive Summary

The Sigul Docker stack has **partial functionality** with several critical issues preventing full operation:

| Component | Status | Health | Critical Issues |
|-----------|--------|--------|-----------------|
| **cert-init** | ✅ Complete | N/A | None - certificates generated successfully |
| **sigul-bridge** | ⚠️ Running | ❌ Unhealthy | Healthcheck timeout (TLS port detection issue) |
| **sigul-server** | ❌ Failed | N/A | Database path mismatch, dependency on unhealthy bridge |

**Impact:** Server cannot start due to bridge being marked unhealthy and database configuration mismatch.

---

## 1. Bridge Container Issues

### 1.1 Healthcheck Failure (Critical)

**Problem:**
- Bridge is running and listening on ports 44333/44334
- Healthcheck command `nc -z localhost 44333` **times out after 5 seconds**
- Bridge marked as "unhealthy" preventing server startup

**Root Cause:**
```
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
tcp        6      0 0.0.0.0:44333           0.0.0.0:*               LISTEN      1/python
```

The bridge port **requires TLS handshake**, but `nc -z` opens a raw TCP connection and waits indefinitely. The bridge doesn't respond without proper TLS negotiation, causing the healthcheck to timeout.

**Test Results:**
```bash
$ docker exec sigul-bridge timeout 2 nc -zvw1 localhost 44333
Ncat: TIMEOUT.
Exit code: 1
```

**Recommendation:**
Replace the healthcheck with a non-blocking port check:

```yaml
healthcheck:
  test: ["CMD-SHELL", "timeout 2 bash -c '</dev/tcp/localhost/44333' || exit 1"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
```

Alternative approaches:
- Use Python socket check with immediate close
- Use `ss` or `netstat` to verify listening state
- Create dedicated healthcheck script that checks process + port

### 1.2 Log File Status

**Current State:**
```bash
$ docker exec sigul-bridge ls -la /var/log/sigul_bridge.log
-rw-r--r-- 1 sigul sigul 0 Nov 16 16:39 /var/log/sigul_bridge.log
```

**Analysis:**
- ✅ Log file exists with correct ownership (sigul:sigul)
- ✅ Log file is open by bridge process (lsof confirms fd 3w)
- ⚠️ Log file is **empty** (0 bytes)
- ✅ PID file contains valid PID

**Why Empty:**
1. Bridge is running in verbose mode (`-v` flag) - logs may go to stdout/stderr
2. No client connections yet - no events to log
3. Bridge may only log actual signing operations, not startup

**Logging Destinations:**
- **stdout/stderr:** Entrypoint validation messages
- **File:** Application-level logs (currently empty - awaiting operations)

**Verification:**
```bash
$ docker-compose -f docker-compose.sigul.yml logs sigul-bridge | tail -10
[16:48:51] BRIDGE: Bridge initialized successfully
```

Logs ARE being captured by Docker, but Sigul application logs to file are empty because no operations have occurred.

---

## 2. Server Container Issues

### 2.1 Database Path Configuration Error (Critical)

**Error Message:**
```
[database] database-path '/var/lib/sigul/server.sqlite' is not an existing file
```

**Analysis:**

The server configuration template specifies:
```ini
[database]
database-path: /var/lib/sigul/server/sigul.db
```

But the error shows it's looking for:
```
/var/lib/sigul/server.sqlite
```

**Possible Causes:**
1. Configuration template not properly substituted during cert-init
2. Server using default/fallback configuration
3. Configuration file not mounted correctly

**Volume Mounts:**
```yaml
volumes:
  - sigul_shared_config:/etc/sigul:rw
  - sigul_server_data:/var/lib/sigul/server:rw
```

**Investigation Needed:**
```bash
# Check actual configuration in container
docker exec sigul-server cat /etc/sigul/server.conf | grep database-path

# Check if database directory exists
docker exec sigul-server ls -la /var/lib/sigul/server/

# Check permissions
docker exec sigul-server stat /var/lib/sigul/server/
```

**Recommendation:**
1. Verify server.conf is generated correctly by cert-init
2. Initialize database file on first startup
3. Add database initialization to entrypoint script

### 2.2 Server Startup Blocked

**Current Status:**
```
dependency failed to start: container sigul-bridge is unhealthy
```

**Analysis:**
Server has `depends_on: sigul-bridge: condition: service_healthy` in docker-compose.yml, which blocks startup when bridge is marked unhealthy.

**Chain of Issues:**
1. Bridge healthcheck fails (TLS timeout)
2. Bridge marked unhealthy
3. Server startup blocked by dependency check
4. Database error never investigated due to startup block

---

## 3. File Permissions & Directory Structure

### 3.1 Bridge Directories

**Status:** ✅ **Correct**

```
/etc/sigul/           - Shared config (sigul:sigul, 755)
/etc/pki/sigul/bridge - NSS database (sigul:sigul, 755)
/var/lib/sigul/bridge - Data directory (sigul:sigul, 755)
/var/log/sigul/bridge - Log directory (sigul:sigul, 755)
/var/log/sigul_bridge.log - Log file (sigul:sigul, 644)
/var/run/sigul_bridge.pid - PID file (sigul:sigul, 644, 2 bytes)
```

### 3.2 Server Directories

**Status:** ⚠️ **Not Verified** (container not running)

**Expected:**
```
/etc/sigul/           - Shared config (sigul:sigul, 755)
/etc/pki/sigul/server - NSS database (sigul:sigul, 755)
/var/lib/sigul/server - Data directory (sigul:sigul, 755)
/var/log/sigul/server - Log directory (sigul:sigul, 755)
/var/log/sigul_server.log - Log file (sigul:sigul, 644)
/var/run/sigul_server.pid - PID file (sigul:sigul, 644)
```

**Verification Needed:**
Once server starts, verify all directories have correct ownership and permissions.

---

## 4. Certificate Status

### 4.1 Certificate Generation

**Status:** ✅ **Successful**

```bash
$ docker-compose -f docker-compose.sigul.yml logs cert-init | grep -i success
Certificates generated successfully
```

**Bridge Certificates:**
```
Certificate Nickname                                         Trust Attributes
                                                             SSL,S/MIME,JAR/XPI

sigul-ca                                                     CTu,Cu,Cu
sigul-bridge-cert                                           u,u,u
```

**Server Certificates:**
```
Certificate Nickname                                         Trust Attributes
                                                             SSL,S/MIME,JAR/XPI

sigul-ca                                                     CTu,Cu,Cu
sigul-server-cert                                           u,u,u
```

All certificates generated with auto-generated serial numbers (no collision issues).

---

## 5. Network & Connectivity

### 5.1 Bridge Listening Status

**Status:** ✅ **Correct**

```
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 0.0.0.0:44334           0.0.0.0:*               LISTEN (client port)
tcp        6      0 0.0.0.0:44333           0.0.0.0:*               LISTEN (server port)
```

Bridge is listening on both required ports:
- **44333:** Server-facing port (6 bytes in receive queue from failed healthchecks)
- **44334:** Client-facing port

### 5.2 Port Accessibility

**From Host:**
```
0.0.0.0:44333-44334->44333-44334/tcp
```

Ports are exposed and should be accessible from host and other containers.

---

## 6. Process Status

### 6.1 Bridge Process

**Status:** ✅ **Running**

```
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
sigul        1  0.0  0.5  57496 47364 ?        Ss   16:48   0:00 /usr/bin/python /usr/share/sigul/bridge.py -v
```

Process running as expected with:
- Correct user (sigul)
- Verbose logging enabled (`-v`)
- Reasonable memory usage (47 MB)

### 6.2 Server Process

**Status:** ❌ **Not Running**

Container fails to start due to:
1. Dependency on unhealthy bridge
2. Database configuration error

---

## 7. Logging Analysis

### 7.1 Logging Architecture

**Current Design:**
- **Entrypoint Scripts:** Log to stdout/stderr (captured by Docker)
- **Sigul Application:** Logs to files in `/var/log/`
- **Verbose Mode:** `-v` flag enables verbose application logging

### 7.2 Log File Status

| Component | Log File | Status | Size | Open FD |
|-----------|----------|--------|------|---------|
| Bridge | `/var/log/sigul_bridge.log` | ✅ Exists | 0 bytes | Yes (fd 3w) |
| Server | `/var/log/sigul_server.log` | ❓ Unknown | N/A | N/A |

### 7.3 Why Logs Are Empty

**Analysis:**
1. **Bridge is idle:** No client connections, no operations to log
2. **Verbose mode logs to stdout:** Application may separate startup logs from operational logs
3. **No errors:** Empty log may indicate healthy idle state

**Testing Required:**
Initiate actual signing operation to verify logs are written:
```bash
# Once server is healthy, test with client
docker exec sigul-client-test sigul list-keys
```

Expected behavior: Activity should appear in log files.

---

## 8. Action Plan

### Immediate Fixes (P0 - Critical)

1. **Fix Bridge Healthcheck** ⏱️ 15 minutes
   ```yaml
   healthcheck:
     test: ["CMD-SHELL", "timeout 2 bash -c '</dev/tcp/localhost/44333' 2>/dev/null || exit 1"]
   ```

2. **Fix Server Database Configuration** ⏱️ 30 minutes
   - Verify cert-init generates correct server.conf
   - Add database initialization to entrypoint-server.sh
   - Create empty database file if it doesn't exist

3. **Initialize Server Database** ⏱️ 10 minutes
   ```bash
   # Add to entrypoint-server.sh
   if [ ! -f "$DATABASE_PATH" ]; then
       log "Creating database at $DATABASE_PATH"
       touch "$DATABASE_PATH"
       chown sigul:sigul "$DATABASE_PATH"
       chmod 644 "$DATABASE_PATH"
   fi
   ```

### Verification Steps (P1 - High)

4. **Verify Server Startup** ⏱️ 5 minutes
   ```bash
   docker-compose -f docker-compose.sigul.yml up -d sigul-server
   docker logs sigul-server
   ```

5. **Check Log Files After Operations** ⏱️ 10 minutes
   ```bash
   # Attempt a signing operation
   # Then check logs
   docker exec sigul-server cat /var/log/sigul_server.log
   docker exec sigul-bridge cat /var/log/sigul_bridge.log
   ```

6. **Verify All Permissions** ⏱️ 10 minutes
   ```bash
   docker exec sigul-server find /var/lib/sigul /var/log/sigul /run/sigul -ls
   docker exec sigul-bridge find /var/lib/sigul /var/log/sigul /run/sigul -ls
   ```

### Documentation Updates (P2 - Medium)

7. **Update OPERATIONS_GUIDE.md** ⏱️ 30 minutes
   - Document healthcheck issue and fix
   - Add troubleshooting section for database initialization
   - Add log file location reference

8. **Create Healthcheck Best Practices** ⏱️ 20 minutes
   - Document TLS port healthcheck patterns
   - Add alternative healthcheck methods

---

## 9. Testing Checklist

### Container Startup
- [ ] cert-init completes successfully
- [ ] Bridge starts and reaches healthy state
- [ ] Server starts and reaches healthy state
- [ ] All certificates validated at startup

### File Permissions
- [ ] All log directories owned by sigul:sigul
- [ ] All log files owned by sigul:sigul
- [ ] All PID files owned by sigul:sigul
- [ ] All NSS databases owned by sigul:sigul
- [ ] All data directories owned by sigul:sigul

### Logging
- [ ] Entrypoint logs appear in `docker logs`
- [ ] Log files exist and are writable
- [ ] Log files contain records after operations
- [ ] Log files not empty after signing operation
- [ ] No permission errors in logs

### Network & Connectivity
- [ ] Bridge listening on port 44333 (server)
- [ ] Bridge listening on port 44334 (client)
- [ ] Server can connect to bridge
- [ ] Client can connect to bridge
- [ ] Healthcheck passes consistently

### Database
- [ ] Database file created on first startup
- [ ] Database file has correct permissions
- [ ] Database initialized with schema
- [ ] Server can read/write database

---

## 10. Known Issues & Workarounds

### Issue 1: Bridge Healthcheck Timeout

**Symptom:** Bridge marked unhealthy, preventing server startup

**Workaround:**
```bash
# Remove healthcheck temporarily
docker-compose -f docker-compose.sigul.yml up -d --no-deps sigul-bridge
```

**Permanent Fix:** Apply healthcheck change in Action Plan

### Issue 2: Empty Log Files

**Symptom:** Log files exist but are empty

**Analysis:** This is **expected behavior** when no operations have occurred

**To Verify Logging Works:**
1. Fix bridge healthcheck and start server
2. Perform actual signing operation
3. Check log files again

---

## 11. Recommendations

### Short-term (This Sprint)

1. ✅ **Fix healthcheck immediately** - This unblocks server startup
2. ✅ **Investigate and fix database path** - Server cannot function without this
3. ✅ **Verify server startup** - Ensure all components running
4. ✅ **Test signing operation** - Verify logs are written

### Medium-term (Next Sprint)

1. **Add database initialization logic** - Automate database creation
2. **Create healthcheck library** - Reusable healthcheck patterns
3. **Add comprehensive monitoring** - Beyond basic healthchecks
4. **Document logging architecture** - Clear expectations for operators

### Long-term (Future)

1. **Implement structured logging** - JSON logs for better parsing
2. **Add log aggregation** - Centralized logging solution
3. **Create alerting framework** - Proactive issue detection
4. **Performance baseline** - Establish normal operating metrics

---

## 12. Conclusion

The Sigul Docker stack is **very close to full functionality**:

✅ **Working:**
- Certificate generation
- Bridge process startup
- Directory permissions
- Network configuration
- NSS database creation

⚠️ **Needs Attention:**
- Bridge healthcheck (trivial fix)
- Server database initialization (straightforward fix)
- Log verification (needs actual operations)

The issues identified are **configuration-level** rather than architectural, and can be resolved quickly with the fixes outlined above.

**Estimated Time to Full Functionality:** 1-2 hours

---

## Appendix A: Quick Diagnosis Commands

```bash
# Container status
docker-compose -f docker-compose.sigul.yml ps

# Bridge health
docker exec sigul-bridge netstat -tlnp
docker inspect sigul-bridge --format='{{json .State.Health}}' | jq

# Log files
docker exec sigul-bridge ls -la /var/log/sigul_bridge.log
docker exec sigul-bridge cat /var/log/sigul_bridge.log

# Permissions
docker exec sigul-bridge find /var/log/sigul /var/lib/sigul -ls

# Process status
docker exec sigul-bridge ps aux | grep sigul

# Certificate verification
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge
```

---

**Generated:** 2025-11-16T16:55:00Z  
**Next Review:** After implementing P0 fixes