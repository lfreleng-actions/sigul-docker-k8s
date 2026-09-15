#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Credential generation for the Sigul stack.
#
# Every password the stack needs is generated per deployment. Nothing in
# this repository ships a default, and no caller should invent one: the
# admin password is hashed into the server's SQLite database by
# sigul_server_add_admin at first boot, so a value committed here would
# be a permanent credential for every stack ever started from it, on a
# public repository.
#
# The corollary is that these values are ephemeral to generate but NOT
# ephemeral in effect. The database outlives the container, and Sigul
# offers no re-issue path for a lost admin password short of adding a
# second admin from inside a running server. A caller that generates a
# password must therefore record it somewhere durable before the server
# starts - see test-artifacts/admin-password in
# deploy-sigul-infrastructure.sh, or the admin Secret in the Helm chart.
#
# Usage:
#   source scripts/lib/secrets.sh
#   password="$(generate_password 12)"
#   mask_secret "$password"

# Generate a password from the kernel CSPRNG.
#
# $1 - bytes of entropy to draw (default 18). base64 of N bytes yields
#      ceil(N/3)*4 characters, so 12 -> 16 chars and 18 -> 24.
#
# base64 rather than a character-class filter because the value travels
# through YAML, shell export and a NUL-terminated pipe into
# sigul_server_add_admin; the base64 alphabet survives all three without
# quoting surprises.
generate_password() {
    local bytes="${1:-18}"
    head -c "${bytes}" /dev/urandom | base64
}

# Hide a value from GitHub Actions logs.
#
# Call this immediately after generating a secret and before anything
# can echo it. The mask applies to output produced after the workflow
# command is emitted, so masking late does not retroactively redact a
# value already printed. Outside GitHub Actions this is a no-op, which
# keeps local runs quiet rather than printing stray directives.
mask_secret() {
    local value="$1"
    [ -n "${value}" ] || return 0
    [ -n "${GITHUB_ACTIONS:-}" ] || return 0
    printf '::add-mask::%s\n' "${value}"
}
