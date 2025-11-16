<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Sigul Network Architecture

## Connection Flow (Correct)

```
┌─────────────────┐
│  Sigul Client   │
│                 │
└────────┬────────┘
         │ Connects to
         │ Port 44334
         ▼
┌─────────────────┐
│  Sigul Bridge   │◄─────────────┐
│                 │              │
│ Listens on:     │              │ Connects to
│  - 0.0.0.0:44333│              │ Port 44333
│  - 0.0.0.0:44334│              │
└─────────────────┘              │
                         ┌───────┴────────┐
                         │  Sigul Server  │
                         │                │
                         └────────────────┘
```

## Key Points

### Bridge Behavior

- **Bridge LISTENS** on two ports:
  - Port 44333: Server connection port
  - Port 44334: Client connection port
- **Bridge ALWAYS binds to 0.0.0.0** (all interfaces)
  - This is hardcoded in `/usr/share/sigul/bridge.py`
  - No configuration option to change bind address
  - Source: `sock.bind(nss.io.NetworkAddress(nss.io.PR_IpAddrAny, port))`

### Server Behavior

- **Server CONNECTS to bridge** (outbound connection)
- Server has NO listening ports
- Server configuration specifies:
  - `bridge-hostname: sigul-bridge.example.org`
  - `bridge-port: 44333`

### Client Behavior

- **Client CONNECTS to bridge** (outbound connection)
- Client has NO listening ports
- Client connects to bridge on port 44334

## Configuration Evidence

### Bridge Configuration (`bridge.conf`)

```ini
[bridge]
bridge-cert-nickname: sigul-bridge.example.org
client-listen-port: 44334    # Bridge LISTENS for clients
server-listen-port: 44333    # Bridge LISTENS for servers
```

### Server Configuration (`server.conf`)

```ini
[server]
bridge-hostname: sigul-bridge.example.org    # Server CONNECTS to bridge
bridge-port: 44333                           # Server CONNECTS to this port
server-cert-nickname: sigul-server.example.org
```

## Network Verification Commands

### Check Bridge Listening Ports

```bash
# Bridge should be LISTENING on both ports
docker exec sigul-bridge netstat -tlnp | grep -E '44333|44334'

# Expected output:
# tcp    0.0.0.0:44333    LISTEN    <pid>/python
# tcp    0.0.0.0:44334    LISTEN    <pid>/python
```

### Check Server Connection to Bridge

```bash
# Server should have ESTABLISHED connection to bridge
docker exec sigul-server netstat -tnp | grep 44333

# Expected output:
# tcp    <server-ip>:<random-port>    <bridge-ip>:44333    ESTABLISHED    <pid>/python
```

### Check Server Has No Listening Ports

```bash
# Server should NOT be listening on any Sigul ports
docker exec sigul-server netstat -tlnp | grep python

# Expected output: (empty or only local addresses)
```

## Docker Compose Configuration

### Correct Port Mapping

```yaml
services:
  sigul-bridge:
    ports:
      - "44333:44333"  # Server connection port (bridge listens)
      - "44334:44334"  # Client connection port (bridge listens)

  sigul-server:
    # NO port mappings - server doesn't listen, it connects
    depends_on:
      sigul-bridge:
        condition: service_healthy
```

## Connection Initialization Sequence

1. **Bridge starts first**
   - Initializes NSS database
   - Loads certificates
   - Binds to 0.0.0.0:44333 (server port)
   - Binds to 0.0.0.0:44334 (client port)
   - Enters listening state

2. **Server starts second** (waits for bridge health)
   - Initializes NSS database
   - Loads certificates
   - Resolves bridge hostname via Docker DNS
   - Initiates TCP connection to bridge:44333
   - Performs TLS handshake
   - Maintains persistent connection

3. **Client connects** (when needed)
   - Resolves bridge hostname
   - Initiates TCP connection to bridge:44334
   - Performs TLS handshake
   - Sends signing request
   - Closes connection after response

## Common Misconceptions

### ❌ INCORRECT: "Bridge connects to server"

- The bridge does NOT initiate connections
- The bridge is a passive listener/proxy

### ✅ CORRECT: "Server connects to bridge"

- Server is the active connector
- Server maintains persistent connection to bridge
- Server reconnects if connection is lost

### ❌ INCORRECT: "Server listens on port 44333"

- Server has NO listening ports
- Port 44333 is where the BRIDGE listens

### ✅ CORRECT: "Bridge listens on port 44333 for server connections"

- Bridge listens on 44333
- Server connects TO bridge on port 44333

## Security Implications

### Bridge Exposure

- Bridge listens on `0.0.0.0` (all interfaces)
- Cannot be changed via configuration
- Must use container networking or firewall rules for security
- In production, use network policies to restrict access

### Server Isolation

- Server makes outbound connections only
- No inbound port exposure needed
- More secure posture (no listening ports)
- Easier to firewall (allow outbound only)

## Production Deployment Pattern

### AWS/Cloud Deployment

```
Internet
    │
    ▼
[Load Balancer] :44334 (client traffic only)
    │
    ▼
[Sigul Bridge]
    │ Port 44333
    │ (internal network only)
    ▼
[Sigul Server] ─────► [Bridge]
(no public exposure)   (outbound connection)
```

### Docker Compose Deployment

```
Docker Network: sigul-network (172.20.0.0/16)
    │
    ├─► Bridge:  172.20.0.2 (listens on 44333, 44334)
    │            Exposed: host:44333, host:44334
    │
    └─► Server:  172.20.0.3 (connects to bridge:44333)
                 NOT exposed to host
```

## Troubleshooting

### Problem: "Server cannot connect to bridge"

**Check:**

1. Bridge is listening: `netstat -tlnp | grep 44333`
2. DNS resolution: `docker exec sigul-server getent hosts sigul-bridge.example.org`
3. Network connectivity: `docker exec sigul-server nc -zv sigul-bridge.example.org 44333`
4. Certificate CN matches hostname

### Problem: "Connection refused on port 44333"

**Likely causes:**

- Bridge is not running
- Bridge failed to bind to port 44333
- Firewall blocking connection
- Wrong hostname/IP being used

**NOT likely:**

- Server not listening (server doesn't listen!)

## References

- Source code: `/usr/share/sigul/bridge.py` - Bridge bind logic
- Source code: `/usr/share/sigul/server.py` - Server connection logic
- ALIGNMENT_PLAN.md - Phase 6: Network & DNS Configuration
- PHASE6_COMPLETE.md - Network topology diagram
- README.md - Network Architecture section
