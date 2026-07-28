#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Unified client wrapper script for sigul user (UID/GID 1000)
#
# Dispatches signing operations to entrypoint.sh, execs any explicit
# command given, and otherwise drops to an interactive shell.
# Certificate initialization is deliberately not performed here: a
# client init request is detected only so it can be refused with a
# pointer to init-client-certs.sh.

set -euo pipefail

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CLIENT-WRAPPER: $*" >&2
}

# Ensure we're running as the sigul user consistently
if [[ "$(id -u)" != "1000" ]]; then
    log "Warning: Running as UID $(id -u) instead of expected UID 1000 (sigul user)"
fi

# Check if this is a signing operation (legacy entrypoint.sh behavior)
if [[ -n "${SIGN_TYPE:-}" || -n "${SIGN_OBJECT:-}" ]]; then
    log "Detected signing operation - using entrypoint.sh"
    exec /usr/local/bin/entrypoint.sh "$@"
fi

# Check if this is sigul client initialization
if [[ "${1:-}" == "--role" && "${2:-}" == "client" ]] || [[ "${SIGUL_ROLE:-}" == "client" ]]; then
    log "Detected client initialization"
    log "Client initialization should be done via init-client-certs.sh"
    exit 1
fi

# If specific command provided, run it directly
if [[ $# -gt 0 && "${1:-}" != "--role" ]]; then
    log "Running command directly: $*"
    exec "$@"
fi

# Default: run bash for interactive use
log "Default mode - starting interactive shell"
log "Note: Client initialization should be done via init-client-certs.sh"
exec /bin/bash
