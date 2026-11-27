#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Report when each Sigul signing key expires.
#
# Lists every key on the service through the Sigul client as the
# admin (list-keys, then get-public-key for each key) and reads each
# public key's expiry with gpg in a throwaway home. Prints one line
# per signing-capable (sub)key, the expired and the due first, and
# exits non-zero when any has expired or expires within --warn-days.
# It reads public keys only; the server's key volume is never needed.
#
# Usage, from the admin toolbox:
#   bash /scripts/key-expiry.sh [--warn-days <n>]
#
# --help lists every option.

set -Eeuo pipefail
trap 'exit 2' ERR
umask 077

PROG="key-expiry.sh"

usage() {
    cat <<EOF
Usage: ${PROG} [options]

Lists the expiry of every signing-capable (sub)key on the Sigul
service, one line each, expired and due ones first:

  <STATUS> key=<name> primary=<fingerprint> signing=<fingerprint> \\
      expires=<YYYY-MM-DDThh:mm:ssZ|never> days=<n|never>

STATUS is EXPIRED (days is zero or negative), DUE (expires within
--warn-days) or OK. A subkey's expiry is the earlier of its own and
its primary key's, since it cannot sign once the primary expires. A
key with no signing-capable (sub)key prints one NOSIGN line, with
signing=none.

Options:
  -c, --config <file>   Sigul client configuration
                        (default: /etc/sigul/client.conf)
  --warn-days <n>       report a (sub)key as DUE when it expires
                        within <n> days (default: 30)
  --now <seconds>       judge expiry as of this Unix time rather
                        than the current time
  -h, --help            show this help

Credentials: the Sigul admin password comes from SIGUL_ADMIN_PASSWORD,
which the admin toolbox sets. When that is unset or empty, it is
prompted for on a terminal, or else read from stdin up to the first
NUL or newline. It is passed to sigul on stdin, never on a command
line, and never printed.

Exit status:
  0  no signing (sub)key has expired or expires within --warn-days
  1  at least one has (the EXPIRED and DUE lines)
  2  the report could not be produced
EOF
}

die() { printf '%s: ERROR: %s\n' "${PROG}" "$*" >&2; exit 2; }

CONFIG=/etc/sigul/client.conf
WARN_DAYS=30
NOW=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -c|--config|--warn-days|--now)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            case "$1" in
                -c|--config) CONFIG="$2" ;;
                --warn-days) WARN_DAYS="$2" ;;
                --now) NOW="$2" ;;
            esac
            shift 2
            ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ "${WARN_DAYS}" =~ ^[0-9]{1,5}$ ]] \
    || die "--warn-days '${WARN_DAYS}' is not a whole number of days"
WARN_DAYS=$((10#${WARN_DAYS}))
NOW="${NOW:-$(date -u +%s)}"
[[ "${NOW}" =~ ^[0-9]{1,12}$ ]] || die "--now '${NOW}' is not a Unix time"
NOW=$((10#${NOW}))
[ -r "${CONFIG}" ] || die "cannot read the Sigul configuration ${CONFIG}"
for tool in sigul gpg gpgconf awk sort date; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} not found in PATH"
done

### Admin password ###################################################

PASSWORD="${SIGUL_ADMIN_PASSWORD:-}"
if [ -z "${PASSWORD}" ]; then
    if [ -t 0 ]; then
        IFS= read -rs -p "Sigul admin password: " PASSWORD || true
        echo >&2
    else
        # One character at a time, so a NUL or a newline ends the read
        # even when the caller keeps stdin open after it.
        while IFS= read -r -n 1 -d '' char; do
            [ -n "${char}" ] && [ "${char}" != $'\n' ] || break
            PASSWORD+="${char}"
        done
        unset char
    fi
fi
unset SIGUL_ADMIN_PASSWORD
[ -n "${PASSWORD}" ] || die "no Sigul admin password: set SIGUL_ADMIN_PASSWORD"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/key-expiry.XXXXXX")"
cleanup() {
    local home
    for home in "${WORK}"/gnupg.*; do
        [ -d "${home}" ] || continue
        gpgconf --homedir "${home}" --kill all >/dev/null 2>&1 || true
    done
    rm -rf "${WORK}"
}
trap cleanup EXIT

# sigul_admin ARGS...: sigul in batch mode, the admin password on
# stdin as a NUL-terminated value. printf is a builtin, so the
# password reaches no process's argv.
sigul_admin() {
    printf '%s\0' "${PASSWORD}" | sigul --batch -c "${CONFIG}" "$@"
}

# last_error FILE: the file's last non-empty line, for a message.
last_error() {
    awk 'NF { line = $0 } END { print line }' "$1"
}

### Keys #############################################################

sigul_admin list-keys > "${WORK}/keys" 2> "${WORK}/keys.err" \
    || die "sigul list-keys failed: $(last_error "${WORK}/keys.err")"
mapfile -t KEYS < <(awk 'NF { print $1 }' "${WORK}/keys")

# One row per signing-capable (sub)key, from gpg's colon listing:
#   S <primary fingerprint> <fingerprint> <expiry epoch, empty for never>
# and one per primary key:
#   K <primary fingerprint>
# Field 12 of a pub or sub record holds that key's own capabilities in
# lower case; field 7 its expiry. The fingerprint record that follows
# names it. A subkey cannot sign once its primary expires, so a
# subkey's expiry is the earlier of its own and its primary's.
# shellcheck disable=SC2016  # an awk program, expanded by awk
COLONS_AWK='
BEGIN { FS = ":"; OFS = "\t" }
$1 == "pub" || $1 == "sub" { kind = $1; expiry = $7; caps = $12; want = 1; next }
$1 == "fpr" && want {  # codespell:ignore fpr
    want = 0
    if (kind == "pub") { primary = $10; primary_expiry = expiry; print "K", primary }
    else if (primary_expiry != "" && (expiry == "" || primary_expiry + 0 < expiry + 0))
        expiry = primary_expiry
    if (caps ~ /s/) print "S", primary, $10, expiry
}
'

ROWS="${WORK}/rows"
: > "${ROWS}"
index=0
for key in ${KEYS[@]+"${KEYS[@]}"}; do
    index=$((index + 1))
    asc="${WORK}/key.${index}.asc"
    sigul_admin get-public-key --password "${key}" > "${asc}" 2> "${WORK}/key.err" \
        || die "sigul get-public-key ${key} failed: $(last_error "${WORK}/key.err")"
    home="$(mktemp -d "${WORK}/gnupg.XXXXXX")"
    gpg --homedir "${home}" --batch --quiet --with-colons \
        --import-options show-only --import "${asc}" \
        > "${WORK}/colons" 2> "${WORK}/gpg.err" \
        || die "gpg cannot read ${key}'s public key: $(last_error "${WORK}/gpg.err")"
    gpgconf --homedir "${home}" --kill all >/dev/null 2>&1 || true
    awk "${COLONS_AWK}" "${WORK}/colons" > "${WORK}/key.rows"
    grep -q '^K' "${WORK}/key.rows" || die "${key}'s public key holds no primary key"
    signing=0
    first_primary=""
    while IFS=$'\t' read -r kind primary fingerprint expiry; do
        case "${kind}" in
            K) first_primary="${first_primary:-${primary}}" ;;
            S)
                signing=$((signing + 1))
                printf '%s\t%s\t%s\t%s\n' "${key}" "${primary}" "${fingerprint}" "${expiry}" >> "${ROWS}"
                ;;
        esac
    done < "${WORK}/key.rows"
    if [ "${signing}" -eq 0 ]; then
        printf '%s\t%s\t-\t-\n' "${key}" "${first_primary}" >> "${ROWS}"
    fi
done

### Report ###########################################################

# Each row becomes "<group> <sort expiry> <line>": the expired and the
# due (group 0) before the rest (group 1) and keys that cannot sign
# (group 2), each by expiry, never last.
warn_seconds=$((WARN_DAYS * 86400))
flagged=0
total=0
: > "${WORK}/report"
while IFS=$'\t' read -r key primary fingerprint expiry; do
    if [ "${fingerprint}" = "-" ]; then
        printf '2\t99999999999999\tNOSIGN key=%s primary=%s signing=none expires=never days=never\n' \
            "${key}" "${primary}" >> "${WORK}/report"
        continue
    fi
    total=$((total + 1))
    if [ -z "${expiry}" ]; then
        printf '1\t99999999999999\tOK key=%s primary=%s signing=%s expires=never days=never\n' \
            "${key}" "${primary}" "${fingerprint}" >> "${WORK}/report"
        continue
    fi
    [[ "${expiry}" =~ ^[0-9]+$ ]] || die "${key}: gpg reports expiry '${expiry}' for ${fingerprint}"
    delta=$((10#${expiry} - NOW))
    if [ "${delta}" -ge 0 ]; then
        days=$((delta / 86400))
    else
        days=$((-((-delta + 86399) / 86400)))
    fi
    if [ "${delta}" -le 0 ]; then
        status=EXPIRED group=0
    elif [ "${delta}" -le "${warn_seconds}" ]; then
        status=DUE group=0
    else
        status=OK group=1
    fi
    [ "${group}" -ne 0 ] || flagged=$((flagged + 1))
    printf '%s\t%s\t%s key=%s primary=%s signing=%s expires=%s days=%s\n' \
        "${group}" "${expiry}" "${status}" "${key}" "${primary}" "${fingerprint}" \
        "$(date -u -d "@${expiry}" +%Y-%m-%dT%H:%M:%SZ)" "${days}" >> "${WORK}/report"
done < "${ROWS}"

LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3 "${WORK}/report" | cut -f3-

printf '%s: %d key(s), %d signing (sub)key(s), %d expired or due within %d day(s)\n' \
    "${PROG}" "${#KEYS[@]}" "${total}" "${flagged}" "${WARN_DAYS}" >&2
[ "${flagged}" -eq 0 ] || exit 1
