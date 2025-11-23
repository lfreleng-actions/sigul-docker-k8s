# Quick Start Guide: PKI Architecture v2.0

**Purpose:** Quick deployment and testing of the new PKI architecture  
**Time Required:** ~5 minutes  
**Prerequisites:** Docker, Docker Compose

---

## Overview

This guide helps you quickly deploy and verify the new Sigul PKI architecture where:
- Bridge pre-generates ALL certificates
- CA private key stays ONLY on bridge
- Server and client receive certificates without CA signing authority

---

## Quick Start

### 1. Clean Environment (Optional but Recommended)

Remove any existing volumes from previous deployments:

```bash
# Stop and remove old containers/volumes
docker compose -f docker-compose.sigul.yml down -v

# Verify volumes are removed
docker volume ls | grep sigul
```

### 2. Deploy Stack

```bash
# Deploy with new PKI architecture
docker compose -f docker-compose.sigul.yml up -d

# Watch logs for initialization
docker compose -f docker-compose.sigul.yml logs -f cert-init

# Wait for cert-init to complete (should take 10-20 seconds)
# Look for: "Certificate initialization complete"
```

### 3. Verify Deployment

```bash
# Check all containers are running
docker compose -f docker-compose.sigul.yml ps

# Verify bridge is healthy
docker compose -f docker-compose.sigul.yml ps sigul-bridge
# Status should show "healthy"
```

### 4. Verify PKI Architecture

```bash
# Run the PKI verification script
./scripts/verify-pki-architecture.sh
```

**Expected Output:**
```
=== Bridge PKI Verification ===
✓ Bridge has CA certificate
✓ Bridge has CA private key (correct - bridge is CA)
✓ Bridge has its own certificate
✓ Bridge has its own private key
✓ CA certificate exported for distribution
✓ Server certificate exported for distribution
✓ Client certificate exported for distribution

=== Server PKI Verification ===
✓ Server has CA certificate (for validation)
✓ Server does NOT have CA private key (correct)
✓ Server has its own certificate
✓ Server has its own private key

=== Verification Summary ===
Total tests: 14
Passed: 14
Failed: 0

✓ All PKI architecture tests passed!
```

---

## Manual Verification (Optional)

If you want to manually verify the PKI architecture:

### Check Bridge (Should have CA private key)

```bash
# List certificates in bridge
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge

# List private keys in bridge (should show CA key)
docker exec sigul-bridge certutil -K -d sql:/etc/pki/sigul/bridge
```

**Expected:** Shows `sigul-ca` in both lists

### Check Server (Should NOT have CA private key)

```bash
# List certificates in server
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul/server

# List private keys in server (should NOT show CA key)
docker exec sigul-server certutil -K -d sql:/etc/pki/sigul/server
```

**Expected:** 
- Certificates list shows `sigul-ca` (public cert)
- Private keys list does NOT show `sigul-ca`

### Check Export Directories

```bash
# Check CA export
docker exec sigul-bridge ls -la /etc/pki/sigul/ca-export/
# Should show: ca.crt

# Check server export
docker exec sigul-bridge ls -la /etc/pki/sigul/server-export/
# Should show: server-cert.p12, server-cert.crt, server-cert.p12.password

# Check client export
docker exec sigul-bridge ls -la /etc/pki/sigul/client-export/
# Should show: client-cert.p12, client-cert.crt, client-cert.p12.password
```

---

## Test Client (Optional)

To test the client component:

```bash
# Start client container
docker compose -f docker-compose.sigul.yml --profile testing up -d sigul-client-test

# Verify client initialization
docker logs sigul-client-test

# Check client certificates
docker exec sigul-client-test certutil -L -d sql:/etc/pki/sigul/client

# Check client private keys (should NOT show CA key)
docker exec sigul-client-test certutil -K -d sql:/etc/pki/sigul/client
```

---

## Troubleshooting

### cert-init Failed

**Symptom:** cert-init container exits with error

**Check logs:**
```bash
docker logs sigul-cert-init
```

**Common causes:**
- NSS_PASSWORD not set (should auto-generate)
- Permissions issue on volume mount
- Previous volumes not cleaned up

**Solution:**
```bash
# Force clean and regenerate
docker compose -f docker-compose.sigul.yml down -v
CERT_INIT_MODE=force docker compose -f docker-compose.sigul.yml up -d
```

### Server/Client Initialization Failed

**Symptom:** Server or client logs show certificate import errors

**Check logs:**
```bash
docker logs sigul-server
docker logs sigul-client-test
```

**Common causes:**
- cert-init didn't complete successfully
- Bridge NSS volume not mounted correctly
- Missing export files

**Solution:**
```bash
# Check if exports exist
docker exec sigul-bridge ls -la /etc/pki/sigul/ca-export/
docker exec sigul-bridge ls -la /etc/pki/sigul/server-export/

# If missing, regenerate certificates
docker compose -f docker-compose.sigul.yml down
docker volume rm sigul_bridge_nss
CERT_INIT_MODE=force docker compose -f docker-compose.sigul.yml up -d
```

### Security Check Failed

**Symptom:** Server or client reports "CA private key found"

**This is a critical security issue!**

**Check:**
```bash
# Should NOT show CA private key
docker exec sigul-server certutil -K -d sql:/etc/pki/sigul/server | grep sigul-ca
docker exec sigul-client-test certutil -K -d sql:/etc/pki/sigul/client | grep sigul-ca
```

**Solution:**
```bash
# This indicates incorrect implementation - contact development team
# For testing, regenerate with clean volumes:
docker compose -f docker-compose.sigul.yml down -v
docker compose -f docker-compose.sigul.yml up -d
./scripts/verify-pki-architecture.sh
```

---

## Configuration Customization

### Custom FQDNs

```bash
# Set custom hostnames for certificates
export BRIDGE_FQDN="bridge.mydomain.com"
export SERVER_FQDN="server.mydomain.com"
export CLIENT_FQDN="client.mydomain.com"

docker compose -f docker-compose.sigul.yml up -d
```

### Custom Certificate Validity

```bash
# Set certificate validity (in months)
export CA_VALIDITY_MONTHS=240        # 20 years
export CERT_VALIDITY_MONTHS=120      # 10 years

docker compose -f docker-compose.sigul.yml up -d
```

### Force Certificate Regeneration

```bash
# Force regeneration even if certificates exist
CERT_INIT_MODE=force docker compose -f docker-compose.sigul.yml up -d
```

### Enable Debug Mode

```bash
# Enable verbose debug output
DEBUG=true docker compose -f docker-compose.sigul.yml up -d

# View debug logs
docker logs sigul-cert-init
docker logs sigul-server
```

---

## Health Checks

### Quick Health Check

```bash
# Check container status
docker compose -f docker-compose.sigul.yml ps

# Check bridge health
docker inspect sigul-bridge --format='{{.State.Health.Status}}'
# Should show: healthy
```

### Detailed Health Check

```bash
# Check bridge is listening
nc -zv localhost 44333  # Server port
nc -zv localhost 44334  # Client port

# Check certificates are loaded
docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge
docker exec sigul-server certutil -L -d sql:/etc/pki/sigul/server
```

---

## Cleanup

### Stop Services (Keep Volumes)

```bash
docker compose -f docker-compose.sigul.yml down
```

### Complete Cleanup (Remove Volumes)

```bash
docker compose -f docker-compose.sigul.yml down -v
```

### Remove Only Certificate Volumes

```bash
docker compose -f docker-compose.sigul.yml down
docker volume rm sigul_bridge_nss sigul_server_nss sigul_client_nss
```

---

## Next Steps

After successful deployment:

1. **Review Logs:** Check for any warnings or errors
   ```bash
   docker logs sigul-bridge
   docker logs sigul-server
   ```

2. **Test Connectivity:** Verify TLS connections work
   ```bash
   # From client container
   docker exec sigul-client-test nc -zv sigul-bridge 44334
   ```

3. **Run Integration Tests:** Execute full test suite
   ```bash
   ./scripts/run-integration-tests.sh
   ```

4. **Review Documentation:** Read comprehensive docs
   - `PKI_ARCHITECTURE.md` - Detailed architecture
   - `PKI_REFACTOR_IMPLEMENTATION.md` - Implementation details

---

## Success Criteria

Your deployment is successful if:

- [ ] All containers start without errors
- [ ] Bridge reaches `healthy` status
- [ ] PKI verification script passes all tests
- [ ] Bridge has CA private key
- [ ] Server does NOT have CA private key
- [ ] Client does NOT have CA private key
- [ ] Export directories contain required files
- [ ] Configuration files generated correctly

---

## Getting Help

If you encounter issues:

1. Check logs: `docker logs <container-name>`
2. Run verification: `./scripts/verify-pki-architecture.sh`
3. Review documentation: `PKI_ARCHITECTURE.md`
4. Check Sigul documentation: https://github.com/ModeSevenIndustrialSolutions/sigul
5. Check GitHub issues: https://github.com/lfreleng-actions/sigul-sign-docker/issues

---

## Summary

This quick start guide walked you through:

✓ Deploying the new PKI architecture  
✓ Verifying proper certificate distribution  
✓ Confirming security controls are in place  
✓ Testing the deployment

The new architecture ensures:
- Bridge is the Certificate Authority
- CA private key never leaves bridge
- Server and client have only what they need
- Security best practices enforced

**Ready for production!** 🎉