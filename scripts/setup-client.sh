#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Provision the client volumes for the running compose stack.
#
#   SIGUL_CLIENT_IMAGE=client-<platform>-image:test ./scripts/setup-client.sh
#
# Creates the client NSS database (importing the CA and bridge
# certificates the cert-init container exported) and writes
# client.conf, into the two named volumes that every test suite mounts
# read-only: sigul-docker_sigul_client_nss and
# sigul-docker_sigul_client_config.
#
# Idempotent: existing client volumes are removed and rebuilt, so a
# stale certificate from a previous stack cannot survive a redeploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

CLIENT_IMAGE="${SIGUL_CLIENT_IMAGE:-}"
if [[ -z "$CLIENT_IMAGE" ]]; then
    echo "ERROR: SIGUL_CLIENT_IMAGE environment variable must be set" >&2
    exit 1
fi

if [[ ! -f test-artifacts/nss-password ]]; then
    echo "ERROR: test-artifacts/nss-password missing - deploy the stack first" >&2
    exit 1
fi
NSS_PASSWORD="$(cat test-artifacts/nss-password)"

NETWORK_NAME="$(docker network ls --filter 'name=sigul' --format '{{.Name}}' | head -1)"
if [[ -z "$NETWORK_NAME" ]]; then
    echo "ERROR: no sigul docker network found - is the stack up?" >&2
    exit 1
fi

BRIDGE_NSS_VOLUME="$(docker volume ls --format '{{.Name}}' \
    | grep -E 'bridge.*nss|sigul.*bridge.*nss' | head -1)"
if [[ -z "$BRIDGE_NSS_VOLUME" ]]; then
    echo "ERROR: bridge NSS volume not found" >&2
    exit 1
fi

CLIENT_NSS_VOLUME="sigul-docker_sigul_client_nss"
CLIENT_CONFIG_VOLUME="sigul-docker_sigul_client_config"
INIT_CONTAINER="sigul-client-init"

echo "network=${NETWORK_NAME} bridge-nss=${BRIDGE_NSS_VOLUME}"

docker rm -f "$INIT_CONTAINER" >/dev/null 2>&1 || true
# Rebuild from empty. A volume that exists but cannot be removed is
# still attached to something; carrying on would hand that container's
# old certificate database to every suite, so stop instead.
for volume in "$CLIENT_NSS_VOLUME" "$CLIENT_CONFIG_VOLUME"; do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
        if ! docker volume rm "$volume" >/dev/null 2>&1; then
            echo "ERROR: cannot remove volume $volume - still in use?" >&2
            docker ps -a --filter "volume=$volume" --format '  {{.Names}} ({{.Status}})' >&2
            exit 1
        fi
    fi
    docker volume create "$volume" >/dev/null
done

# UID 1000 is the in-image sigul user.
docker run --rm \
    -v "${CLIENT_NSS_VOLUME}:/target-nss" \
    -v "${CLIENT_CONFIG_VOLUME}:/target-config" \
    alpine:3.19 sh -c 'chown -R 1000:1000 /target-nss /target-config'

docker run -d --name "$INIT_CONTAINER" \
    --network "$NETWORK_NAME" \
    --user sigul \
    -v "${BRIDGE_NSS_VOLUME}:/etc/pki/sigul/bridge:ro" \
    -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:rw" \
    -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:rw" \
    -e NSS_PASSWORD="$NSS_PASSWORD" \
    "$CLIENT_IMAGE" tail -f /dev/null >/dev/null
trap 'docker rm -f "$INIT_CONTAINER" >/dev/null 2>&1 || true' EXIT

sleep 3
docker exec "$INIT_CONTAINER" /usr/local/bin/init-client-certs.sh 2>&1 | tail -1

# user-name - without it sigul falls back to getpass.getuser(), which
# inside the container is the sigul user, not the admin the server
# database knows, and every request fails AUTHENTICATION_FAILED. Track
# the same variable the server was deployed with.
ADMIN_USER="${SIGUL_ADMIN_USER:-admin}"
docker exec --user root "$INIT_CONTAINER" bash -c "cat > /etc/sigul/client.conf <<EOF
[client]
bridge-hostname: sigul-bridge.example.org
bridge-port: 44334
server-hostname: sigul-server.example.org
user-name: ${ADMIN_USER}

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
EOF
chown sigul:sigul /etc/sigul/client.conf"

echo "client provisioned"
