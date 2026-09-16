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

# Create the directories the daemon's data layout needs.
#
# Both paths are read from the chart-rendered config below, not from
# the image. The PVC is mounted at /var/lib/sigul/server - the image's
# WORKDIR, deliberately - so database-path sits at the mount root and
# needs no directory created; gnupg-home is one level below it and
# does.
#
# gnupg-home is not freely chosen, though: the image entrypoint
# prepares its own GnuPG directory from a hard-coded path before the
# daemon starts, so the value here has to match it. See
# files/conf/server.conf.template.
#
# The DB_DIR branch below is therefore normally a no-op. It stays
# because it costs nothing and covers a mount placed elsewhere, and
# because sqlite reports only "unable to open database file" when the
# directory is missing, which is a poor clue to work from.
DB_DIR="$(dirname "${DB}")"
if [ ! -d "${DB_DIR}" ]; then
    log "Creating ${DB_DIR}"
    mkdir -p "${DB_DIR}" || die "could not create ${DB_DIR}"
fi

# Refuse to run against the pre-2.2.4 on-disk layout.
#
# Until this chart mounted the PVC at the data directory it mounted one
# level higher, so the database and GnuPG home sat in a server/
# subdirectory OF THE VOLUME. After the move the same configured paths
# resolve at the volume root, so an upgraded release looks straight
# past them: it would find no database, generate a new one, and strand
# a live trust domain and its signing keys one directory below without
# ever saying so. Stop instead, and say where the data is.
LEGACY_DIR="${DB_DIR}/server"
if [ ! -s "${DB}" ] && \
   { [ -s "${LEGACY_DIR}/$(basename "${DB}")" ] || [ -d "${LEGACY_DIR}/gnupg" ]; }; then
    printf '[db-init] ERROR: %s\n' \
        "data from an older chart layout found under ${LEGACY_DIR}" >&2
    printf '[db-init] %s\n' \
        "This release mounts the volume at ${DB_DIR}, so the database" \
        "and GnuPG home now belong directly in it. Continuing would" \
        "create an empty database alongside the existing one and leave" \
        "the signing keys unreachable." \
        "" \
        "Back the volume up, then move the contents up one level." \
        "Run this as a single command, as the sigul user, from a pod" \
        "mounting this volume:" \
        "" \
        "  { [ ! -e ${DB_DIR}/gnupg ] || rmdir ${DB_DIR}/gnupg; } \\" \
        "    && mv ${LEGACY_DIR}/* ${DB_DIR}/ \\" \
        "    && rmdir ${LEGACY_DIR}" \
        "" \
        "It is chained deliberately. A GnuPG home already present at" \
        "the destination is removed only when empty; rmdir refuses a" \
        "populated one, and the && then stops the move entirely. Run" \
        "the mv on its own against a populated destination and it" \
        "relocates the database while rejecting the GnuPG directory," \
        "separating a trust domain from its signing keys." >&2
    exit 1
fi

# The GnuPG home shares that parent and cannot simply inherit from it.
# The mount root carries the group-writable setgid mode fsGroup
# expects, and sigul refuses to start against a home directory that is
# "openable by another user", so create it 0700 explicitly rather than
# letting the umask and the inherited group decide.
GNUPG_DIR="$(grep '^gnupg-home:' "${CONFIG}" | cut -d: -f2 | tr -d ' ')"
if [ -n "${GNUPG_DIR}" ] && [ ! -d "${GNUPG_DIR}" ]; then
    log "Creating ${GNUPG_DIR}"
    mkdir -p "${GNUPG_DIR}" || die "could not create ${GNUPG_DIR}"
    chmod 700 "${GNUPG_DIR}" || die "could not set mode 0700 on ${GNUPG_DIR}"
fi

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
