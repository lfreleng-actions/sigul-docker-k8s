#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Run a soak profile against a freshly deployed compose stack.
#
#   ./soak/run-soak.sh [smoke|pr|nightly] [--keep]
#
# Requires the three images tagged as the deploy script expects
# (server-/bridge-/client-<platform>-image:test) or SIGUL_*_IMAGE set.
# Deploys the stack, provisions the client, builds the runner image on
# top of the client image, runs the profile, and tears everything down
# unless --keep is given. Results land in soak/results/.
#
# Exit status is the soak verdict.

set -euo pipefail

PROFILE=""
KEEP=false
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        smoke|pr|nightly) PROFILE="$arg" ;;
        *) echo "usage: $0 [smoke|pr|nightly] [--keep]" >&2; exit 2 ;;
    esac
done
PROFILE="${PROFILE:-smoke}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

BASE=docker-compose.sigul.yml
OVERLAY=soak/compose.soak.yml

detect_platform() {
    case "$(uname -m)" in
        x86_64|amd64) echo linux-amd64 ;;
        aarch64|arm64) echo linux-arm64 ;;
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
    esac
}
PLATFORM="${SIGUL_RUNNER_PLATFORM:-$(detect_platform)}"
export SIGUL_SERVER_IMAGE="${SIGUL_SERVER_IMAGE:-server-${PLATFORM}-image:test}"
export SIGUL_BRIDGE_IMAGE="${SIGUL_BRIDGE_IMAGE:-bridge-${PLATFORM}-image:test}"
export SIGUL_CLIENT_IMAGE="${SIGUL_CLIENT_IMAGE:-client-${PLATFORM}-image:test}"
export SOAK_PROFILE="$PROFILE"

log() { printf '[soak] %s\n' "$*"; }

compose() {
    # The base file needs these set for every subcommand; the deploy
    # script writes them to test-artifacts on first deploy.
    NSS_PASSWORD="${NSS_PASSWORD:-$(cat test-artifacts/nss-password 2>/dev/null || echo x)}" \
    SIGUL_ADMIN_PASSWORD="${SIGUL_ADMIN_PASSWORD:-$(cat test-artifacts/admin-password 2>/dev/null || echo x)}" \
        docker compose -f "$BASE" -f "$OVERLAY" "$@"
}

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    if $KEEP; then
        log "--keep: stack left running; tear down with:"
        log "  docker compose -f $BASE -f $OVERLAY down -v --remove-orphans"
        return
    fi
    log "tearing down"
    compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "profile=$PROFILE platform=$PLATFORM"
log "images: $SIGUL_SERVER_IMAGE / $SIGUL_BRIDGE_IMAGE / $SIGUL_CLIENT_IMAGE"

# 1. Deploy the stack under test, exactly as CI does. Tear down any
#    previous soak stack first: the deploy script only knows the base
#    file, and a leftover toxiproxy keeps the network alive, which
#    breaks the redeploy in confusing ways.
log "removing any previous stack"
compose down -v --remove-orphans >/dev/null 2>&1 || true
log "deploying stack"
./scripts/deploy-sigul-infrastructure.sh --local-debug --force-clean-volumes \
    2>&1 | grep -E 'ERROR|Deployment Completed|Deployment Failed' | tail -3

# 2. Provision the client volumes (certificates + client.conf).
log "provisioning client"
./scripts/setup-client.sh | tail -1

# 3. Bring up toxiproxy and recreate the server so it routes through it.
log "starting toxiproxy and re-pointing the server"
compose up -d --no-deps toxiproxy >/dev/null
compose up -d --no-deps --force-recreate sigul-server >/dev/null
# The recreated server needs a moment to reconnect via the proxy.
sleep 10

# 4. Build the runner on top of the client image and run the profile.
#    Keep the previous run's results alongside rather than overwriting
#    them; an A/B comparison needs both.
mkdir -p soak/results
if [[ -f soak/results/results.json ]]; then
    previous="soak/results-$(date -u +%Y%m%dT%H%M%SZ)"
    mv soak/results "$previous"
    mkdir -p soak/results
    log "previous results moved to $previous"
fi
log "building runner"
compose build --quiet soak-runner
log "running profile $PROFILE"
set +e
compose run --rm --no-deps soak-runner "$PROFILE"
STATUS=$?
set -e

log "results in soak/results/ (report.md, results.json, *.png)"
exit "$STATUS"
