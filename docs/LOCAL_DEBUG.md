<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Local Debug Recipe

A minimal, opinionated recipe for bringing the Sigul stack up locally,
running the integration test suite, and capturing AUTHDBG diagnostics.

This complements the broader `TESTING.md`; the goal here is the
shortest path from a clean checkout to a green `run-integration-tests.sh`
on a developer laptop, plus the toggle for auth debug logging.

## Prerequisites

* Docker Desktop or Docker Engine 24+
* A sibling checkout of `sigul/` next to `sigul-docker/` if you want to
  build a patched Sigul instead of pulling from upstream.  The default
  source path is `../sigul`; see `scripts/sync-local-sigul.sh --help`.

## One-shot deploy and test

```sh
# 1. Generate ephemeral credentials and feature flags.
cat > .env.local <<EOF
NSS_PASSWORD=testpw_$(date +%s)
SIGUL_ADMIN_PASSWORD=adminpw_$(date +%s)
SIGUL_ADMIN_USER=admin
SIGUL_DEBUG_AUTH=1
EOF

# 2. (Optional) sync your local Sigul checkout into the build context
#    so the Dockerfiles build a patched tree instead of cloning master.
scripts/sync-local-sigul.sh --source ../sigul

# 3. Build all three images.
docker compose -f docker-compose.sigul.yml build

# 4. Bring the stack up.
docker compose -f docker-compose.sigul.yml --env-file .env.local \
    up -d cert-init sigul-bridge sigul-server

# 5. Save the passwords where the test harness expects them.
mkdir -p test-artifacts
grep ^NSS_PASSWORD .env.local | cut -d= -f2 | tr -d '\n' \
    > test-artifacts/nss-password
grep ^SIGUL_ADMIN_PASSWORD .env.local | cut -d= -f2 \
    > test-artifacts/admin-password

# 6. Initialise the client volumes (mirrors the CI setup step).
NSS_PASSWORD=$(cat test-artifacts/nss-password)
docker run --rm \
    -v sigul-docker_sigul_client_nss:/target-nss \
    -v sigul-docker_sigul_client_config:/target-config \
    alpine:3.19 sh -c 'chown -R 1000:1000 /target-nss /target-config'

docker run -d --name sigul-client-init \
    --network sigul-docker_sigul-network \
    --user sigul \
    -v sigul-docker_sigul_bridge_nss:/etc/pki/sigul/bridge:ro \
    -v sigul-docker_sigul_client_nss:/etc/pki/sigul/client:rw \
    -v sigul-docker_sigul_client_config:/etc/sigul:rw \
    -e NSS_PASSWORD="$NSS_PASSWORD" \
    sigul-docker-sigul-client-test:latest tail -f /dev/null
sleep 2
docker exec sigul-client-init /usr/local/bin/init-client-certs.sh
docker exec --user root sigul-client-init bash -c "cat > /etc/sigul/client.conf <<EOFCONF
[client]
bridge-hostname: sigul-bridge.example.org
bridge-port: 44334
server-hostname: sigul-server.example.org
user-name: admin

[gnupg]
gnupg-bin: /usr/bin/gpg2
gnupg-key-type: RSA
gnupg-key-length: 4096

[nss]
client-cert-nickname: sigul-client-cert
nss-ca-cert-nickname: sigul-ca
nss-bridge-cert-nickname: sigul-bridge-cert
nss-dir: /etc/pki/sigul/client
nss-password: ${NSS_PASSWORD}
nss-min-tls: tls1.2
EOFCONF
chown sigul:sigul /etc/sigul/client.conf"
docker stop sigul-client-init && docker rm sigul-client-init

# 7. Run the integration tests.
SIGUL_CLIENT_IMAGE=sigul-docker-sigul-client-test:latest \
    bash scripts/run-integration-tests.sh --verbose
```

## Auth-debug logging

Setting `SIGUL_DEBUG_AUTH=1` in `.env.local` activates the gated
diagnostics added by `patches/02-verbose-auth-logging.patch`.  The
bridge and server then emit `AUTHDBG/*` lines at INFO level for every
auth checkpoint, with no impact when the flag is unset.

To inspect them after a test run:

```sh
docker exec sigul-bridge grep AUTHDBG /var/log/sigul_bridge.log | tail
docker exec sigul-server grep AUTHDBG /var/log/sigul_server.log | tail
```

Sample output for a successful `list-users` round-trip:

```text
AUTHDBG/bridge: Server-side TCP accept from <NetworkAddress ...>
AUTHDBG/bridge: Server peer cert CN='sigul-server.example.org'
AUTHDBG/bridge: Client-side TCP accept from <NetworkAddress ...>
AUTHDBG/server: read_request: outer fields keys=['op', 'user']
AUTHDBG/server: read_request: declared payload_size=0
AUTHDBG/server: request_handling_child: handler='RequestHandler' \
                peer_cn='sigul-client.example.org'
AUTHDBG/server: authenticate_admin: outer user='admin'
AUTHDBG/server: authenticate_admin: password field present=True len=18
AUTHDBG/server: authenticate_admin: db user lookup name='admin' found=True
AUTHDBG/server: authenticate_admin: stored sha512_password set, \
                crypt prefix='$6$c'
AUTHDBG/server: authenticate_admin: crypt compare result=True \
                (user existed=True)
AUTHDBG/server: authenticate_admin: OK for user='admin'
```

The same toggle is exposed in CI: trigger the
`Sigul Build/Test` workflow with `enable_auth_debug=true` and the
diagnostics are uploaded as part of the integration test artifacts.

## Tearing down

```sh
docker compose -f docker-compose.sigul.yml --env-file .env.local down -v
```

`-v` removes the volumes, which is essential because the NSS DB
password is baked into `cert9.db` / `key4.db`.  Reusing volumes from a
previous run with a different `NSS_PASSWORD` will cause cryptic
"Incorrect password/PIN entered" errors at startup.
