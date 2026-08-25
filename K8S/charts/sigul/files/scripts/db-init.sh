#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# First-boot database and administrator bootstrap.
#
# The image entrypoint performs this too, but treats a failed
# sigul_server_add_admin as a warning and starts the daemon anyway
# (scripts/entrypoint-server.sh). The schema exists by then, so every
# later start takes its "database already initialized" branch and the
# administrator is never created again: a healthy-looking deployment
# that nobody can authenticate against.
#
# Running it here instead makes failure fatal and retriable - the
# kubelet restarts a failed init container, and the daemon never
# starts without an administrator. It also keeps the admin credential
# out of the long-running daemon container: by the time the entrypoint
# runs, the database exists and it skips this work entirely.
#
# Idempotent: an existing schema is left alone, and the administrator
# is only created when absent, so this also repairs a deployment whose
# admin creation previously failed.
#
# Environment (set by the pod template):
#   SIGUL_ADMIN_USER, SIGUL_ADMIN_PASSWORD

set -euo pipefail

CONFIG=/etc/sigul/server.conf

log() { printf '[db-init] %s\n' "$*"; }
die() { printf '[db-init] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "${CONFIG}" ] || die "${CONFIG} missing (did nss-init run?)"
[ -n "${SIGUL_ADMIN_USER:-}" ] || die "SIGUL_ADMIN_USER not set"
[ -n "${SIGUL_ADMIN_PASSWORD:-}" ] || die "SIGUL_ADMIN_PASSWORD not set"

DB="$(grep '^database-path:' "${CONFIG}" | cut -d: -f2 | tr -d ' ')"
[ -n "${DB}" ] || die "database-path not found in ${CONFIG}"

# The administrator name is interpolated into a SQL string literal
# below. The chart validates it at render time (sigul.server.adminUser
# in _helpers.tpl), but this script must hold on its own: it also runs
# against whatever a hand-written pod spec supplies, and sqlite3's CLI
# offers no parameter binding to fall back on. Doubling embedded
# single quotes is the complete escape for a single-quoted literal, so
# the value can only ever be read as data.
SQL_ADMIN_USER="${SIGUL_ADMIN_USER//\'/\'\'}"

# Count administrators matching the configured name. SQLite stores the
# boolean as 1/0. Returns 0 when the table does not exist yet.
admin_count() {
    sqlite3 "${DB}" \
        "SELECT COUNT(*) FROM users WHERE name = '${SQL_ADMIN_USER}' AND admin = 1;" \
        2>/dev/null || echo 0
}

if [ ! -s "${DB}" ]; then
    log "Creating database schema at ${DB}"
    sigul_server_create_db -c "${CONFIG}" || die "sigul_server_create_db failed"

    tables="$(sqlite3 "${DB}" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)"
    [ "${tables}" -gt 0 ] || die "schema creation produced no tables"
    log "Schema created (${tables} tables)"
else
    log "Database already present at ${DB}"
fi

if [ "$(admin_count)" != "1" ]; then
    log "Creating administrator '${SIGUL_ADMIN_USER}'"
    printf '%s\0' "${SIGUL_ADMIN_PASSWORD}" |
        sigul_server_add_admin --batch -c "${CONFIG}" -n "${SIGUL_ADMIN_USER}" ||
        die "sigul_server_add_admin failed"
else
    log "Administrator '${SIGUL_ADMIN_USER}' already present"
fi

# Verify rather than trust: this is the check the image entrypoint
# lacks, and the reason the daemon must not start without it.
[ "$(admin_count)" = "1" ] ||
    die "administrator '${SIGUL_ADMIN_USER}' absent after creation attempt"

log "Database ready; administrator '${SIGUL_ADMIN_USER}' verified"
