#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# regenerate-subkey-import-test-key.sh - developer-time helper that
# regenerates the SUBKEY-ONLY import fixture:
#
#   sigul-import-subkey-test-key.b64
#   sigul-import-subkey-test-key.passphrase
#   sigul-import-subkey-test-key.primary.fingerprint
#   sigul-import-subkey-test-key.subkey.fingerprint
#
# The key is exported with 'gpg --export-secret-subkeys', so its primary
# secret is a gnu-dummy stub and only the signing subkey's secret is
# present: the shape in which a project hands over a signing key while
# keeping its primary key offline (#96). The envelope passphrase is the
# one sigul-import-test.passphrase already holds.
#
# Not run in CI. Everything it writes is PUBLICLY KNOWN THROWAWAY test
# data; see README.md in this directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENVELOPE_PASSPHRASE_FILE="${SCRIPT_DIR}/sigul-import-test.passphrase"
readonly KEY_PASSPHRASE="sigul-subkey-test-key-passphrase"
readonly NAME="Sigul Subkey Import Test (PUBLICLY-KNOWN-THROWAWAY-DO-NOT-USE-IN-PRODUCTION)"
readonly EMAIL="ci-subkey-test@example.invalid"

if [[ ! -s "$ENVELOPE_PASSPHRASE_FILE" ]]; then
    echo "ERROR: ${ENVELOPE_PASSPHRASE_FILE} missing" >&2
    exit 1
fi

# /tmp, not $TMPDIR: macOS temporary paths are long enough to break the
# gpg-agent socket path limit.
GNUPGHOME="$(mktemp -d /tmp/sigul-subkey-keygen.XXXXXX)"
export GNUPGHOME
chmod 700 "$GNUPGHOME"
ARMORED="$(mktemp /tmp/sigul-subkey-export.XXXXXX)"
trap 'gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"; rm -f "$ARMORED"' EXIT
echo "allow-loopback-pinentry" > "$GNUPGHOME/gpg-agent.conf"

gpg_batch() {
    gpg --batch --pinentry-mode loopback --passphrase "$KEY_PASSPHRASE" "$@"
}

echo "==> Generating primary key (RSA 4096, sign+certify, no expiry)"
gpg_batch --quick-gen-key "${NAME} <${EMAIL}>" rsa4096 sign,cert never
PRIMARY="$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"

echo "==> Adding signing subkey (RSA 4096, sign only, expires in 10y)"
gpg_batch --quick-add-key "$PRIMARY" rsa4096 sign 10y
SUBKEY="$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{n++; if (n == 2) {print $10; exit}}')"

echo "==> Exporting the subkey secret only (primary becomes a stub)"
gpg_batch --armor --export-secret-subkeys "${SUBKEY}!" > "$ARMORED"

# The fixture is only useful in exactly this shape; refuse anything else.
packets="$(gpg --batch --list-packets "$ARMORED" 2>/dev/null)"
if ! grep -q 'gnu-dummy' <<< "$packets"; then
    echo "ERROR: export has no gnu-dummy primary stub" >&2
    exit 1
fi
if grep -E -q 'version [5-9]' <<< "$packets"; then
    echo "ERROR: export contains non-v4 key packets" >&2
    exit 1
fi
if [[ "$(grep -c ':secret sub key packet:' <<< "$packets")" != "1" ]]; then
    echo "ERROR: export does not hold exactly one secret subkey" >&2
    exit 1
fi

ENCODED="${SCRIPT_DIR}/sigul-import-subkey-test-key.b64"
gpg --batch --yes --pinentry-mode loopback \
    --symmetric --cipher-algo AES256 \
    --passphrase-file "$ENVELOPE_PASSPHRASE_FILE" \
    --output - "$ARMORED" \
    | base64 > "$ENCODED"
if grep -E -q 'BEGIN PGP|END PGP' "$ENCODED"; then
    echo "ERROR: encoded fixture still contains PGP markers" >&2
    exit 1
fi

printf '%s\n' "$KEY_PASSPHRASE" \
    > "${SCRIPT_DIR}/sigul-import-subkey-test-key.passphrase"
printf '%s\n' "$PRIMARY" \
    > "${SCRIPT_DIR}/sigul-import-subkey-test-key.primary.fingerprint"
printf '%s\n' "$SUBKEY" \
    > "${SCRIPT_DIR}/sigul-import-subkey-test-key.subkey.fingerprint"

echo
echo "==> Primary ${PRIMARY}"
echo "==> Subkey  ${SUBKEY}"
echo "==> Wrote:"
ls -la "$ENCODED" \
    "${SCRIPT_DIR}/sigul-import-subkey-test-key.passphrase" \
    "${SCRIPT_DIR}/sigul-import-subkey-test-key.primary.fingerprint" \
    "${SCRIPT_DIR}/sigul-import-subkey-test-key.subkey.fingerprint"
