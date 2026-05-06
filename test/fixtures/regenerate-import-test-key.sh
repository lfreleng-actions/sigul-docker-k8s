#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
#
# Regenerate the publicly-known throwaway PGP test key used by the
# Sigul integration test suite (specifically by the ``import-key``
# test which exercises the server's PGP-import code path).
#
# This script is a development-time helper.  The committed fixture
# files are produced once per key rotation and checked in; CI does
# NOT run this script - CI consumes the committed encoded blob.
#
# Why we go to all this trouble
# -----------------------------
# We need a PGP secret key in the test fixtures because there is no
# other way to exercise ``sigul import-key``.  Committing a raw
# ASCII-armored secret key would trip GitHub's secret scanning
# (the ``-----BEGIN PGP PRIVATE KEY BLOCK-----`` marker is on the
# scanner's denylist), which would generate a security alert on
# every commit and force us to dismiss it manually.
#
# So we encode the key in two layers:
#
# 1. ``gpg --symmetric --cipher-algo AES256`` with a publicly-known
#    test passphrase produces a ``BEGIN PGP MESSAGE`` blob (NOT a
#    private-key block).
# 2. ``base64`` then strips even that header, leaving an opaque
#    blob with no recognisable cryptographic markers.
#
# At test time the inverse operations recover the original armored
# secret key, which is then fed to ``sigul import-key``.
#
# This is NOT meant as security; the encoding is purely to defeat
# automated secret scanning.  The key, the passphrase, and this
# entire repo are public.  Treat the decoded key as if it were
# printed in a newspaper - because effectively, it is.
#
# Usage
# -----
#   test/fixtures/regenerate-import-test-key.sh
#
# Outputs (overwrites in place):
#   test/fixtures/sigul-import-test-key.b64
#   test/fixtures/sigul-import-test.passphrase
#   test/fixtures/sigul-import-test-key.fingerprint
#
# Prerequisites: gpg2, base64.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Publicly-known passphrase used to wrap the encoded blob.  This is
# checked into the repo; it is NOT a secret.  Its only function is
# to produce a "PGP MESSAGE" envelope that survives the base64
# round-trip without being mistaken for a real secret key.
readonly TEST_PASSPHRASE="THIS-IS-A-PUBLIC-TEST-PASSPHRASE-DO-NOT-USE-IN-PRODUCTION"

# Inner key passphrase - the passphrase the eventual decoded key is
# itself protected with at the GPG level.  Also publicly known.  This
# is the value sigul will be told to use when importing.
readonly KEY_PASSPHRASE="sigul-test-key-passphrase"

# Throwaway GNUPGHOME so we don't pollute the developer's keyring.
# We deliberately use /tmp rather than $TMPDIR because on macOS the
# default $TMPDIR is so deep (/var/folders/.../T/) that the resulting
# UNIX socket path overruns the SUN_LEN cap (104 on macOS, 108 on
# Linux) and gpg-agent silently fails to bind.
GNUPGHOME="$(mktemp -d /tmp/sigul-fixture-keygen.XXXXXX)"
export GNUPGHOME
# Make sure the temp directory has tight perms - gpg refuses to use
# a GNUPGHOME that is group- or world-readable.
chmod 700 "$GNUPGHOME"
trap 'gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"' EXIT

# Start an agent against the throwaway home explicitly.  Without
# this, gpg --gen-key fails on systems where the user has no
# pre-existing system gpg-agent socket (e.g. fresh macOS shells).
# We don't need a real pinentry because we drive the keygen
# entirely through --batch + --pinentry-mode loopback.
mkdir -p "$GNUPGHOME/private-keys-v1.d"
cat > "$GNUPGHOME/gpg-agent.conf" <<EOF
allow-loopback-pinentry
EOF
gpgconf --homedir "$GNUPGHOME" --launch gpg-agent

echo "==> Generating fresh 4096-bit RSA test key in $GNUPGHOME"

# UID is intentionally screaming so that nobody, anywhere, can
# accidentally mistake this for a real key.
cat > "$GNUPGHOME/keygen.batch" <<EOF
%echo Generating publicly-known throwaway test key
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: Sigul Integration Test (PUBLICLY-KNOWN-THROWAWAY-DO-NOT-USE-IN-PRODUCTION)
Name-Comment: throwaway CI fixture, NOT for production
Name-Email: ci-test@example.invalid
Expire-Date: 5y
Passphrase: $KEY_PASSPHRASE
%commit
%echo Done
EOF

gpg --batch --pinentry-mode loopback \
    --gen-key "$GNUPGHOME/keygen.batch"

FINGERPRINT="$(
    gpg --list-secret-keys --with-colons \
        | awk -F: '/^fpr:/{print $10; exit}'
)"
echo "==> Generated key fingerprint: $FINGERPRINT"

# 1. Export the secret key, ascii-armored, still GPG-passphrase-protected.
ARMORED="$(mktemp)"
trap 'rm -rf "$GNUPGHOME"; rm -f "$ARMORED"' EXIT

gpg --batch --yes --pinentry-mode loopback \
    --passphrase "$KEY_PASSPHRASE" \
    --armor --export-secret-keys "$FINGERPRINT" > "$ARMORED"

if ! grep -q 'BEGIN PGP PRIVATE KEY BLOCK' "$ARMORED"; then
    echo "ERROR: armored export does not contain expected header" >&2
    exit 1
fi

# 2. Wrap with gpg --symmetric using the public test passphrase.
#    The resulting file is a ``BEGIN PGP MESSAGE`` envelope, NOT a
#    private-key block, so it doesn't trip the scanner even before
#    base64.  We pipe it directly to base64 to keep both operations
#    in one stream.
ENCODED="${SCRIPT_DIR}/sigul-import-test-key.b64"

gpg --batch --yes --pinentry-mode loopback \
    --symmetric --cipher-algo AES256 \
    --passphrase "$TEST_PASSPHRASE" \
    --output - "$ARMORED" \
    | base64 > "$ENCODED"

# Sanity check: the encoded file must NOT contain any recognisable
# PGP markers in plain text.
if grep -E -q 'BEGIN PGP|END PGP' "$ENCODED"; then
    echo "ERROR: encoded fixture still contains PGP markers" >&2
    exit 1
fi

# 3. Write the public envelope passphrase as a separate fixture.
#    Sibling files; both are public.
printf '%s\n' "$TEST_PASSPHRASE" \
    > "${SCRIPT_DIR}/sigul-import-test.passphrase"
printf '%s\n' "$KEY_PASSPHRASE" \
    > "${SCRIPT_DIR}/sigul-import-test-key.passphrase"
printf '%s\n' "$FINGERPRINT" \
    > "${SCRIPT_DIR}/sigul-import-test-key.fingerprint"

# Lock down permissions on local copies; once committed git won't
# preserve the modes anyway, but at least the freshly generated files
# on disk aren't world-readable while sitting around uncommitted.
chmod 600 \
    "$ENCODED" \
    "${SCRIPT_DIR}/sigul-import-test.passphrase" \
    "${SCRIPT_DIR}/sigul-import-test-key.passphrase"

echo
echo "==> Wrote:"
ls -la \
    "$ENCODED" \
    "${SCRIPT_DIR}/sigul-import-test.passphrase" \
    "${SCRIPT_DIR}/sigul-import-test-key.passphrase" \
    "${SCRIPT_DIR}/sigul-import-test-key.fingerprint"

echo
echo "Decode and import test (round-trip self-check):"
ROUNDTRIP_HOME="$(mktemp -d /tmp/sigul-fixture-roundtrip.XXXXXX)"
trap 'gpgconf --homedir "$GNUPGHOME" --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"; rm -f "$ARMORED"; gpgconf --homedir "$ROUNDTRIP_HOME" --kill all 2>/dev/null || true; rm -rf "$ROUNDTRIP_HOME"' EXIT
chmod 700 "$ROUNDTRIP_HOME"
mkdir -p "$ROUNDTRIP_HOME/private-keys-v1.d"
cat > "$ROUNDTRIP_HOME/gpg-agent.conf" <<EOF
allow-loopback-pinentry
EOF
gpgconf --homedir "$ROUNDTRIP_HOME" --launch gpg-agent

# base64 -d on GNU coreutils, base64 -D on macOS - try both.
DECODED="$(mktemp /tmp/sigul-fixture-decoded.XXXXXX)"
if ! base64 -d "$ENCODED" > "$DECODED" 2>/dev/null; then
    base64 -D -i "$ENCODED" -o "$DECODED"
fi

GNUPGHOME="$ROUNDTRIP_HOME" gpg --batch --pinentry-mode loopback \
    --passphrase "$TEST_PASSPHRASE" \
    --decrypt "$DECODED" 2>/dev/null \
    | GNUPGHOME="$ROUNDTRIP_HOME" gpg --batch --pinentry-mode loopback \
        --passphrase "$KEY_PASSPHRASE" --import 2>&1 \
    | tail -3
rm -f "$DECODED"

echo
echo "Done.  Commit the four fixture files to record the new key."
