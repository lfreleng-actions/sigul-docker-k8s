#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
#
# Sync a local sigul source checkout into .build-context/sigul/ so a
# subsequent ``docker compose build`` will compile our patched Sigul
# instead of cloning master from Pagure.
#
# Why this script exists
# ----------------------
# The Dockerfiles ship with::
#
#     COPY .build-context/sigul /build-context/sigul/
#
# build-scripts/install-sigul.sh detects the presence of
# ``configure.ac`` inside that directory and prefers it over a fresh
# upstream clone.  In CI, .build-context/sigul/ holds only a
# ``.gitkeep`` so the upstream clone path is taken; locally we want
# our patched tree built instead.
#
# This helper makes that switch explicit, scriptable and easy to
# undo.  It does NOT modify any image-build behaviour: the same
# patches in patches/ are applied on top of whichever source tree
# install-sigul.sh ends up using, so the local and CI images converge
# bit-for-bit on the same Sigul behaviour once their inputs match.
#
# Usage
# -----
#   scripts/sync-local-sigul.sh [--source DIR] [--clean]
#
# Default --source is ../sigul relative to this repository, matching
# the layout we use during local development (a sibling sigul/ clone
# of pagure.io/sigul).
#
# Pass --clean to drop any previously-synced tree so the next docker
# build falls back to upstream master.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="${REPO_ROOT}/.build-context/sigul"
DEFAULT_SRC="${REPO_ROOT}/../sigul"
SRC="${DEFAULT_SRC}"
CLEAN=0

usage() {
    cat <<EOF
Usage: $0 [--source DIR] [--clean]

Sync a local Sigul source tree into .build-context/sigul/ so the next
docker compose build uses it instead of cloning from upstream.

Options:
    --source DIR   Path to a sigul/ checkout (default: ${DEFAULT_SRC})
    --clean        Remove any previously-synced tree and exit
    -h, --help     Show this help

Environment:
    SIGUL_LOCAL_SRC  Override --source (script flag wins if both are set)
EOF
}

if [ -n "${SIGUL_LOCAL_SRC:-}" ]; then
    SRC="${SIGUL_LOCAL_SRC}"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --source)
            if [ $# -lt 2 ]; then
                echo "Error: --source requires a directory argument" >&2
                usage >&2
                exit 2
            fi
            SRC="$2"
            shift 2
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$CLEAN" -eq 1 ]; then
    if [ -d "${DEST}" ]; then
        echo "Removing any previously-synced sigul source from ${DEST}"
        # Preserve the .gitkeep so the path is still legal in
        # Dockerfiles after the wipe.
        find "${DEST}" -mindepth 1 -not -name '.gitkeep' -delete
        echo "Done.  Next docker build will clone Sigul from upstream."
    else
        # Nothing to clean - --clean is idempotent and a no-op when
        # the destination doesn't exist yet.
        echo "Nothing to clean: ${DEST} does not exist."
    fi
    exit 0
fi

if [ ! -d "${SRC}" ]; then
    echo "Error: source directory not found: ${SRC}" >&2
    exit 1
fi

if [ ! -f "${SRC}/configure.ac" ]; then
    echo "Error: ${SRC} does not look like a Sigul checkout " \
         "(no configure.ac found)" >&2
    exit 1
fi

mkdir -p "${DEST}"

# Prefer rsync because it cleanly excludes VCS state and build
# artefacts; fall back to a plain copy on minimalist systems.
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
          --exclude='.git/' \
          --exclude='.venv/' \
          --exclude='__pycache__/' \
          --exclude='*.pyc' \
          --exclude='build/' \
          --exclude='dist/' \
          --exclude='*.egg-info/' \
          --exclude='.gitkeep' \
          "${SRC}/" "${DEST}/"
else
    echo "rsync not found - falling back to tar-pipe copy"
    # Save and restore .gitkeep across the wholesale wipe
    keepfile="$(mktemp)"
    if [ -f "${DEST}/.gitkeep" ]; then
        cp "${DEST}/.gitkeep" "${keepfile}"
    fi
    # Mimic 'rsync --delete' semantics: remove regular files AND
    # dotfiles/dotdirs (e.g. .github, .pytest_cache).  Plain
    # 'rm -rf ${DEST:?}/*' does not match dotted entries so they
    # would otherwise survive into the new tree.
    find "${DEST}" -mindepth 1 -not -name '.gitkeep' \
        -exec rm -rf {} +
    if [ -s "${keepfile}" ]; then
        cp "${keepfile}" "${DEST}/.gitkeep"
    fi
    rm -f "${keepfile}"
    (cd "${SRC}" && tar --exclude='.git' --exclude='__pycache__' \
                       --exclude='*.pyc' --exclude='./.gitkeep' \
                       -cf - .) | (cd "${DEST}" && tar -xf -)
fi

# Ensure .gitkeep still exists (in case the source tree didn't have
# one) so the path remains a tracked directory in git.  We do NOT
# truncate the file if it already exists; the existing file in this
# repo carries an SPDX header.
if [ ! -f "${DEST}/.gitkeep" ]; then
    touch "${DEST}/.gitkeep"
fi

echo "Synced $(du -sh "${DEST}" | cut -f1) of sigul source from ${SRC}"
echo "Next 'docker compose build' will use the local tree."
