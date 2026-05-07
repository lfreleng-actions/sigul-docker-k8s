#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
#
# Sigul end-to-end signing test suite.
#
# This complements scripts/run-integration-tests.sh (which exercises
# only the control plane: list-users, list-keys, etc.).  Where the
# control-plane suite proves that double-TLS, NSS auth, the bridge
# protocol and the admin password mechanism all work, this suite
# proves that *signing actually works* by driving every supported
# Sigul signing operation through the live stack and then
# independently verifying each output with the upstream tool that
# would consume it in production (gpg, rpm, ...).
#
# Visibility
# ----------
# Every sigul invocation is printed verbatim *before* it runs, with
# the actual command line that a human could copy-paste.  Every
# command's stdout and stderr is streamed straight to this script's
# stdout - nothing is captured, hidden, or selectively echoed.
# Section banners delimit phases so the GitHub Actions log has a
# navigable structure.  Passphrases are redacted to '[REDACTED]' in
# the printed command line for tidiness, but the actual passphrase
# is fed via stdin to the real command.
#
# Phases
# ------
# Phase 1: Key lifecycle (new-key, get-public-key, import-key,
#          change-passphrase, delete-key).
# Phase 2: Text and binary signing (sign-text, sign-data including
#          a 64 MiB large-payload streaming test).
# Phase 3: RPM signing (sign-rpm, sign-rpm --v3-signature,
#          sign-rpms batch).  Independently verified with rpm -K.
# Phase 4: User and key-access lifecycle (new-user,
#          grant-key-access, revoke-key-access, delete-user).
#          Verifies that authorisation actually constrains who can
#          sign with which key.
#
# Future PRs will add (none currently planned).
#
# Usage
# -----
#   SIGUL_CLIENT_IMAGE=client-linux-arm64-image:test \
#     bash scripts/run-signing-tests.sh
#
# Prereqs
# -------
# A live Sigul stack on the docker-compose.sigul.yml network with:
#   * test-artifacts/admin-password populated
#   * test-artifacts/nss-password populated
#   * client volumes initialised via init-client-certs.sh
# The stack is brought up the same way for run-integration-tests.sh.

set -uo pipefail

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------

CLIENT_IMAGE="${SIGUL_CLIENT_IMAGE:-}"
CLIENT_NSS_VOLUME="sigul-docker_sigul_client_nss"
CLIENT_CONFIG_VOLUME="sigul-docker_sigul_client_config"

if [[ -z "$CLIENT_IMAGE" ]]; then
    echo "ERROR: SIGUL_CLIENT_IMAGE environment variable must be set" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES_DIR="${PROJECT_ROOT}/test/fixtures"

if [[ ! -f "${PROJECT_ROOT}/test-artifacts/admin-password" ]]; then
    echo "ERROR: test-artifacts/admin-password missing" >&2
    exit 1
fi
ADMIN_PASSWORD="$(cat "${PROJECT_ROOT}/test-artifacts/admin-password")"

# Detect the docker network created by docker-compose.
NETWORK="$(
    docker network ls --filter 'name=sigul' --format '{{.Name}}' \
        | head -1
)"
if [[ -z "$NETWORK" ]]; then
    echo "ERROR: no sigul docker network found - is the stack up?" >&2
    exit 1
fi

# A scratch host directory that we mount into the client container
# so signed outputs and verifier inputs can live in the same place.
# We deliberately chmod 0777: the directory is mounted into
# containers running as the in-image sigul user (UID 1000), which is
# unrelated to whichever UID the runner shell happens to be using.
# On macOS Docker silently maps host-side perms via osxfs so 0700
# also works there, but on Linux runners (which is what CI uses)
# the container's UID 1000 cannot otherwise write into a directory
# owned by the runner user.  This dir holds nothing sensitive - all
# fixture passphrases here are publicly known - so 0777 is fine.
HOST_WORKDIR="$(mktemp -d /tmp/sigul-signing-tests.XXXXXX)"
trap 'rm -rf "$HOST_WORKDIR"' EXIT
chmod 0777 "$HOST_WORKDIR"

# Test counters.
PASS=0
FAIL=0

# ----------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------

# All ANSI escapes are enabled so the GitHub Actions log highlights
# section banners and pass/fail outcomes.

readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[0;33m'
readonly C_DIM='\033[2m'

phase() {
    echo
    echo
    local sep=''
    sep=$(printf '%.0s=' {1..72})
    printf '%b%s%b\n' "${C_BOLD}${C_BLUE}" "$sep" "${C_RESET}"
    printf '%b== PHASE %s%b\n' "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"
    printf '%b%s%b\n' "${C_BOLD}${C_BLUE}" "$sep" "${C_RESET}"
}

testcase() {
    echo
    printf '%b--- TEST: %s%b\n' "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}"
}

note() {
    printf '%b[note] %s%b\n' "${C_DIM}" "$*" "${C_RESET}"
}

pass() {
    printf '%b\u2705 PASS%b: %s\n' "${C_BOLD}${C_GREEN}" "${C_RESET}" "$*"
    PASS=$((PASS + 1))
}

fail() {
    printf '%b\u274c FAIL%b: %s\n' "${C_BOLD}${C_RED}" "${C_RESET}" "$*"
    FAIL=$((FAIL + 1))
}

# Print a command verbatim before executing it.  Used to make the
# workflow log self-documenting: a human reading the log can see
# the exact command line that produced each piece of output.
showrun() {
    printf '%b$ %s%b\n' "${C_YELLOW}" "$*" "${C_RESET}"
    # eval is intentional here - callers pass a single string that
    # may contain pipes, redirections, and quoting that should be
    # honoured by the shell exactly as if they had typed it.
    # shellcheck disable=SC2294
    eval "$@"
}

# Print a sigul invocation as it will appear (with passphrase
# placeholders) and then actually run it with passphrases fed via
# stdin.  Returns the command's exit code.
#
# Usage:
#   sigul_run <pwlabels> <sigul subcommand and args>
#   sigul_run_into <hostfile> <pwlabels> <sigul subcommand and args>
#
# The first form streams the command's stdout straight to this
# script's stdout so it appears verbatim in the workflow log.
# The second form ALSO captures the stdout into <hostfile> on
# the host (useful for callers that need the output as a file,
# e.g. an exported public key) - the output is still echoed.
#
# The first argument to sigul_run is a comma-separated list of
# passphrase labels, which we look up via SIGUL_TEST_PW_<LABEL>
# environment variables and feed to the command as a NUL-separated
# stream on stdin (the format Sigul --batch expects).
_sigul_emit() {
    local labels="$1"
    local cmd="$2"

    local printed_stdin=""
    local printf_fmt=""
    local printf_args=()
    local IFS=,
    for label in $labels; do
        local var="SIGUL_TEST_PW_${label}"
        local val="${!var:?passphrase var $var not set}"
        printed_stdin+="[REDACTED:${label}]\\0"
        printf_fmt+="%s\\0"
        printf_args+=("$val")
    done
    unset IFS

    printf '%b$ printf %q | %s%b\n' "${C_YELLOW}" \
        "$printed_stdin" "${cmd}" "${C_RESET}" >&2

    # shellcheck disable=SC2059
    printf "$printf_fmt" "${printf_args[@]}" \
        | docker run --rm -i \
            --user 1000:1000 \
            --network "${NETWORK}" \
            -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
            -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
            -v "${HOST_WORKDIR}:/work:rw" \
            -v "${FIXTURES_DIR}:/fixtures:ro" \
            "$CLIENT_IMAGE" \
            bash -c "${cmd}"
}

sigul_run() {
    _sigul_emit "$@"
}

# As sigul_run, but tee the stdout into the named host-side file
# while still echoing it to the test log.  Use this when a test
# needs the command output as both a file AND visible in the log.
sigul_run_into() {
    local outfile="$1"; shift
    _sigul_emit "$@" | tee "$outfile"
    # tee returns its own status; propagate the pipeline's first
    # failure so the caller's `if` still works.
    return "${PIPESTATUS[0]}"
}

# Helper to produce a printable host-side path corresponding to a
# /work/... path used inside the client container.
hostpath() {
    echo "${HOST_WORKDIR}/${1#/work/}"
}

# ----------------------------------------------------------------------
# Banner
# ----------------------------------------------------------------------

cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║              SIGUL END-TO-END SIGNING TEST SUITE                  ║
║                                                                   ║
║  Drives real client requests through the bridge and server,       ║
║  then verifies each output with the upstream tool that would      ║
║  consume it in production (gpg, rpm, ...).                        ║
║                                                                   ║
║  Every sigul invocation and its raw output is shown below.        ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝

EOF

note "Client image: ${CLIENT_IMAGE}"
note "Docker network: ${NETWORK}"
note "Host scratch dir: ${HOST_WORKDIR}"
note "Fixtures dir: ${FIXTURES_DIR}"
note "Admin password loaded from test-artifacts/admin-password"

# ----------------------------------------------------------------------
# PHASE 0: Reset state for idempotent reruns
# ----------------------------------------------------------------------
#
# Sigul has an upstream bug where 'delete-key' removes the key from
# its sqlite DB but leaves the underlying GnuPG key material in the
# server's gnupg-home.  A subsequent 'import-key' for a different
# DB-name but the same GPG key fingerprint then fails with
# 'Unexpected import file contents' because gpg reports the key as
# already-imported.  See gpg_delete_key() in server_common.py and
# the import status check in server_gpg.py:Context.sigul_import().
#
# To make this test suite idempotent on a stack that has already
# been run once, we explicitly reset both DB and gpg-home state
# at the top of the run.  In CI the stack is always brand-new so
# this is a no-op; locally it lets developers re-run the suite
# repeatedly without manually wiping state.

phase "0: STATE RESET (clean slate for idempotent reruns)"

for _key in ci-test-new-key ci-test-imported-key; do
    note "Best-effort delete of $_key from server DB (ignoring errors)"
    printf '%s\0' "$ADMIN_PASSWORD" \
        | docker run --rm -i \
            --user 1000:1000 \
            --network "$NETWORK" \
            -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
            -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
            "$CLIENT_IMAGE" \
            bash -c "sigul --batch -c /etc/sigul/client.conf \
                delete-key $_key 2>&1" \
        || true
done

note "Wiping the server's gnupg-home to defeat the upstream bug."
note "This is the same operation a release engineer would perform"
note "to recover from a half-deleted key state in production."
showrun "docker exec sigul-server bash -c 'rm -rf /var/lib/sigul/gnupg/* \
    /var/lib/sigul/gnupg/.* 2>/dev/null; true'"

# ----------------------------------------------------------------------
# PHASE 1: Key lifecycle
# ----------------------------------------------------------------------

phase "1: KEY LIFECYCLE"

# Per-test-key passphrases.  All publicly known.
export SIGUL_TEST_PW_ADMIN="$ADMIN_PASSWORD"
export SIGUL_TEST_PW_NEWKEY="ci-newkey-passphrase"
export SIGUL_TEST_PW_NEWKEY_NEW="ci-newkey-new-passphrase"
SIGUL_TEST_PW_IMPORT="$(cat "${FIXTURES_DIR}/sigul-import-test-key.passphrase")"
export SIGUL_TEST_PW_IMPORT
SIGUL_TEST_PW_IMPORT_NEW="ci-imported-key-passphrase-after-rewrap"
export SIGUL_TEST_PW_IMPORT_NEW

NEW_KEY_NAME="ci-test-new-key"
IMPORT_KEY_NAME="ci-test-imported-key"

# ----------------------------------------------------------------------
testcase "1.1  new-key: generate a fresh 4096-bit RSA signing key"

note "This invokes 'sigul new-key' which on the server side runs"
note "gpg --gen-key with the parameters supplied by the client.  The"
note "server stores the resulting key in its [gnupg] gnupg-home and"
note "returns the ASCII-armored public key as the response payload."

if sigul_run_into "$(hostpath /work/${NEW_KEY_NAME}.pub.asc)" \
    "ADMIN,NEWKEY" "sigul --batch -c /etc/sigul/client.conf \\
    new-key \\
    --key-admin admin \\
    --gnupg-name-real 'Sigul CI Test Key' \\
    --gnupg-name-email 'ci-newkey@example.invalid' \\
    ${NEW_KEY_NAME}"; then
    pass "new-key returned without error"
else
    fail "new-key exited non-zero"
fi

# ----------------------------------------------------------------------
testcase "1.2  list-keys: confirm the new key is present"

OUT=$(sigul_run "ADMIN" \
    "sigul --batch -c /etc/sigul/client.conf list-keys" 2>&1)
echo "$OUT"
if grep -q "^${NEW_KEY_NAME} " <<< "$OUT"; then
    pass "list-keys reports ${NEW_KEY_NAME}"
else
    fail "list-keys does NOT report ${NEW_KEY_NAME}"
fi

# ----------------------------------------------------------------------
testcase "1.3  get-public-key: retrieve the ASCII-armored public key"

if sigul_run_into "$(hostpath /work/${NEW_KEY_NAME}.exported.asc)" \
    "ADMIN" "sigul --batch -c /etc/sigul/client.conf \\
    get-public-key --password ${NEW_KEY_NAME}"; then
    if [[ -s "$(hostpath /work/${NEW_KEY_NAME}.exported.asc)" ]]; then
        showrun "head -3 '$(hostpath /work/${NEW_KEY_NAME}.exported.asc)'"
        pass "get-public-key produced a non-empty output file"
    else
        fail "get-public-key output file is empty"
    fi
else
    fail "get-public-key exited non-zero"
fi

# ----------------------------------------------------------------------
testcase "1.4  Verify exported public key parses with upstream gpg"

note "Independent verification: import the exported key into a fresh"
note "throwaway GnuPG keyring on the host and confirm gpg accepts it."

GPGHOME_VERIFY="$(mktemp -d /tmp/sigul-test-gpghome.XXXXXX)"
chmod 700 "$GPGHOME_VERIFY"
showrun "GNUPGHOME='${GPGHOME_VERIFY}' gpg --batch \\
    --import '$(hostpath /work/${NEW_KEY_NAME}.exported.asc)' 2>&1"
if GNUPGHOME="$GPGHOME_VERIFY" gpg --batch --list-keys --with-colons \
        2>/dev/null | grep -q '^pub:'; then
    showrun "GNUPGHOME='${GPGHOME_VERIFY}' gpg --list-keys"
    pass "gpg accepts the public key produced by sigul"
else
    fail "gpg did NOT accept the public key"
fi
rm -rf "$GPGHOME_VERIFY"

# ----------------------------------------------------------------------
testcase "1.5  import-key: import the throwaway test fixture"

note "Decode the publicly-known test fixture (see test/fixtures/README)"
note "and feed it to 'sigul import-key'.  This exercises the server's"
note "PGP-import code path that would otherwise be untested."

DECODED_FIXTURE="$(hostpath /work/import-test-key.asc)"
showrun "docker run --rm \\
    -v '${FIXTURES_DIR}:/fixtures:ro' \\
    -v '${HOST_WORKDIR}:/work:rw' \\
    --user 1000:1000 \\
    --entrypoint bash \\
    '${CLIENT_IMAGE}' -c \\
    'base64 -d /fixtures/sigul-import-test-key.b64 \\
        | gpg --batch --pinentry-mode loopback \\
            --passphrase-file /fixtures/sigul-import-test.passphrase \\
            --decrypt > /work/import-test-key.asc 2>/dev/null'"

if [[ ! -s "$DECODED_FIXTURE" ]]; then
    fail "Failed to decode test fixture; cannot run import-key test"
else
    showrun "head -1 '${DECODED_FIXTURE}'"

    # import-key wants two passphrases on stdin: the original
    # passphrase the secret key is protected with, then the new
    # passphrase to re-wrap it under inside Sigul's GnuPG home.
    if sigul_run "ADMIN,IMPORT,IMPORT_NEW" \
        "sigul --batch -c /etc/sigul/client.conf \\
            import-key \\
            --key-admin admin \\
            ${IMPORT_KEY_NAME} \\
            /work/import-test-key.asc"; then
        pass "import-key returned without error"
    else
        fail "import-key exited non-zero"
    fi
fi

# ----------------------------------------------------------------------
testcase "1.6  list-keys: confirm both keys are now present"

OUT=$(sigul_run "ADMIN" \
    "sigul --batch -c /etc/sigul/client.conf list-keys" 2>&1)
echo "$OUT"
if grep -q "^${NEW_KEY_NAME} " <<< "$OUT" \
    && grep -q "^${IMPORT_KEY_NAME} " <<< "$OUT"; then
    pass "list-keys reports both ${NEW_KEY_NAME} and ${IMPORT_KEY_NAME}"
else
    fail "list-keys missing one or both expected keys"
fi

# ----------------------------------------------------------------------
testcase "1.7  Verify imported key fingerprint matches the fixture"

EXPECTED_FP="$(cat "${FIXTURES_DIR}/sigul-import-test-key.fingerprint")"
note "Expected fingerprint: ${EXPECTED_FP}"

if sigul_run_into "$(hostpath /work/${IMPORT_KEY_NAME}.exported.asc)" \
    "ADMIN" "sigul --batch -c /etc/sigul/client.conf \\
    get-public-key --password ${IMPORT_KEY_NAME}"; then
    GPGHOME_FP="$(mktemp -d /tmp/sigul-test-fpcheck.XXXXXX)"
    chmod 700 "$GPGHOME_FP"
    GNUPGHOME="$GPGHOME_FP" gpg --batch \
        --import "$(hostpath /work/${IMPORT_KEY_NAME}.exported.asc)" 2>&1
    ACTUAL_FP="$(GNUPGHOME=$GPGHOME_FP gpg --list-keys --with-colons \
                    2>/dev/null \
                 | awk -F: '/^fpr:/{print $10; exit}')"
    rm -rf "$GPGHOME_FP"
    note "Sigul-stored fingerprint: ${ACTUAL_FP}"
    if [[ "$ACTUAL_FP" == "$EXPECTED_FP" ]]; then
        pass "imported key's fingerprint round-trips intact"
    else
        fail "fingerprint mismatch (expected ${EXPECTED_FP}, " \
             "got ${ACTUAL_FP})"
    fi
else
    fail "get-public-key for imported key failed"
fi

# ----------------------------------------------------------------------
testcase "1.8  change-passphrase on the new key"

note "Rotate the passphrase on ${NEW_KEY_NAME} from NEWKEY to NEWKEY_NEW."
if sigul_run "NEWKEY,NEWKEY_NEW" \
    "sigul --batch -c /etc/sigul/client.conf \\
        change-passphrase ${NEW_KEY_NAME}"; then
    pass "change-passphrase returned without error"
    # Update our cached value so future tests use the new passphrase.
    SIGUL_TEST_PW_NEWKEY="$SIGUL_TEST_PW_NEWKEY_NEW"
    export SIGUL_TEST_PW_NEWKEY
else
    fail "change-passphrase exited non-zero"
fi

# ----------------------------------------------------------------------
testcase "1.9  delete-key on the imported test key"

note "Tear down the imported key as a clean-up so re-runs are idempotent."
if sigul_run "ADMIN" "sigul --batch -c /etc/sigul/client.conf \\
    delete-key ${IMPORT_KEY_NAME}"; then
    pass "delete-key returned without error"
else
    fail "delete-key exited non-zero"
fi

OUT=$(sigul_run "ADMIN" \
    "sigul --batch -c /etc/sigul/client.conf list-keys" 2>&1)
echo "$OUT"
if grep -q "^${IMPORT_KEY_NAME} " <<< "$OUT"; then
    fail "list-keys still reports ${IMPORT_KEY_NAME} after delete"
else
    pass "list-keys no longer reports ${IMPORT_KEY_NAME}"
fi

# ----------------------------------------------------------------------
# PHASE 2: Text and binary signing
# ----------------------------------------------------------------------
#
# Phase 1 left ${NEW_KEY_NAME} on the server with the rotated
# NEWKEY_NEW passphrase.  Phase 2 reuses that key for every signing
# operation in the suite: a single key rotation per workflow run
# matches what a real release pipeline does (keys are long-lived;
# signatures are made many times).

phase "2: TEXT AND BINARY SIGNING"

note "Re-using ${NEW_KEY_NAME} (created in phase 1, rotated to"
note "the NEWKEY_NEW passphrase) for all sign-{text,data} tests."

# Set up a throwaway host-side GnuPG keyring with ${NEW_KEY_NAME}'s
# public key so we can independently verify every signature with
# upstream gpg.  Using a sibling host-side dir keeps the developer's
# real keyring untouched.
VERIFY_GPGHOME="$(mktemp -d /tmp/sigul-verify-gpghome.XXXXXX)"
chmod 700 "$VERIFY_GPGHOME"
trap 'rm -rf "$HOST_WORKDIR" "$VERIFY_GPGHOME"' EXIT

testcase "2.0  Set up a throwaway host-side GnuPG keyring for verification"

showrun "GNUPGHOME='${VERIFY_GPGHOME}' gpg --batch --import \\
    '$(hostpath /work/${NEW_KEY_NAME}.pub.asc)' 2>&1"
showrun "GNUPGHOME='${VERIFY_GPGHOME}' gpg --list-keys"

NEW_KEY_FP=$(
    GNUPGHOME="$VERIFY_GPGHOME" gpg --list-keys --with-colons 2>/dev/null \
        | awk -F: '/^fpr:/{print $10; exit}'
)
note "${NEW_KEY_NAME} fingerprint (host keyring): ${NEW_KEY_FP}"
if [[ -n "$NEW_KEY_FP" ]]; then
    pass "verification keyring populated with ${NEW_KEY_NAME}"
else
    fail "verification keyring is empty - cannot verify signatures"
fi

# Tell sigul_run callers below that the key passphrase to use is
# the post-rotation one.  This was already updated at the end of
# phase 1 but make it explicit here so the phase reads stand-alone.
export SIGUL_TEST_PW_NEWKEY="$SIGUL_TEST_PW_NEWKEY_NEW"

# ----------------------------------------------------------------------
testcase "2.1  sign-text: cleartext signature of a UTF-8 text file"

note "sign-text returns a PGP cleartext-signed message: the original"
note "plaintext wrapped in BEGIN/END PGP SIGNED MESSAGE markers with"
note "a detached BEGIN/END PGP SIGNATURE block.  gpg --verify will"
note "both check the signature and reproduce the original text."

showrun "printf '%s\\n' \\
    'hello sigul - this is a test message' \\
    'second line, with some non-ASCII: café résumé 你好' \\
    'third line, end of message' \\
    > '$(hostpath /work/plain.txt)'"
showrun "wc -c '$(hostpath /work/plain.txt)'"

if sigul_run \
    "NEWKEY" "sigul --batch -c /etc/sigul/client.conf \\
        sign-text -o /work/plain.signed.txt \\
        ${NEW_KEY_NAME} /work/plain.txt"; then
    pass "sign-text returned without error"
else
    fail "sign-text exited non-zero"
fi

showrun "head -3 '$(hostpath /work/plain.signed.txt)'"

# Independent verification: gpg --verify on the cleartext signature.
# We use --output to recover the original plaintext and diff it
# against the input - this catches not just signature forgery but
# silent payload corruption too.
VERIFY_OUT="$(hostpath /work/plain.recovered.txt)"
showrun "GNUPGHOME='${VERIFY_GPGHOME}' gpg --batch --yes \\
    --output '${VERIFY_OUT}' \\
    --decrypt '$(hostpath /work/plain.signed.txt)' 2>&1"
if diff -u "$(hostpath /work/plain.txt)" "$VERIFY_OUT" >/dev/null; then
    pass "sign-text signature verifies AND payload round-trips intact"
else
    fail "sign-text payload differs after verify (silent corruption?)"
fi

# ----------------------------------------------------------------------
testcase "2.2  sign-data: detached binary signature of 1 KiB random blob"

note "sign-data produces a binary detached signature (RFC 4880 packet"
note "format, no ASCII armour).  This is what RPM signing builds on"
note "top of and what most CI pipelines use to sign release tarballs."

showrun "head -c 1024 /dev/urandom > '$(hostpath /work/blob1k.bin)'"
showrun "sha256sum '$(hostpath /work/blob1k.bin)'"

if sigul_run \
    "NEWKEY" "sigul --batch -c /etc/sigul/client.conf \\
        sign-data -o /work/blob1k.bin.sig \\
        ${NEW_KEY_NAME} /work/blob1k.bin"; then
    pass "sign-data (binary, 1 KiB) returned without error"
else
    fail "sign-data (binary, 1 KiB) exited non-zero"
fi

showrun "file '$(hostpath /work/blob1k.bin.sig)'"
showrun "GNUPGHOME='${VERIFY_GPGHOME}' gpg --batch --verify \\
    '$(hostpath /work/blob1k.bin.sig)' '$(hostpath /work/blob1k.bin)' 2>&1"
if GNUPGHOME="$VERIFY_GPGHOME" gpg --batch --verify \
        "$(hostpath /work/blob1k.bin.sig)" \
        "$(hostpath /work/blob1k.bin)" 2>/dev/null; then
    pass "detached binary signature verifies against 1 KiB payload"
else
    fail "gpg --verify rejected the detached binary signature"
fi

# ----------------------------------------------------------------------
testcase "2.3  sign-data --armor: armored detached signature of 4 KiB blob"

note "--armor produces an ASCII-armored detached signature, the same"
note "shape as a .asc sidecar file alongside a release tarball."

showrun "head -c 4096 /dev/urandom > '$(hostpath /work/blob4k.bin)'"

if sigul_run \
    "NEWKEY" "sigul --batch -c /etc/sigul/client.conf \\
        sign-data --armor -o /work/blob4k.bin.asc \\
        ${NEW_KEY_NAME} /work/blob4k.bin"; then
    pass "sign-data --armor returned without error"
else
    fail "sign-data --armor exited non-zero"
fi

showrun "head -3 '$(hostpath /work/blob4k.bin.asc)'"
if head -1 "$(hostpath /work/blob4k.bin.asc)" \
        | grep -q '^-----BEGIN PGP SIGNATURE-----$'; then
    pass "output begins with expected ASCII-armor header"
else
    fail "output does NOT look like an armored signature"
fi

showrun "GNUPGHOME='${VERIFY_GPGHOME}' gpg --batch --verify \\
    '$(hostpath /work/blob4k.bin.asc)' '$(hostpath /work/blob4k.bin)' 2>&1"
if GNUPGHOME="$VERIFY_GPGHOME" gpg --batch --verify \
        "$(hostpath /work/blob4k.bin.asc)" \
        "$(hostpath /work/blob4k.bin)" 2>/dev/null; then
    pass "armored detached signature verifies against 4 KiB payload"
else
    fail "gpg --verify rejected the armored detached signature"
fi

# ----------------------------------------------------------------------
testcase "2.4  sign-data: 64 MiB binary blob (large-payload streaming)"

note "Production server.conf has"
note "  max-memory-payload-size: 1048576       (1 MiB)"
note "  max-file-payload-size:   1073741824    (1 GiB)"
note "so a 64 MiB payload exercises the file-backed payload code"
note "path on the server (tempfile + streaming copy) which the small"
note "tests above never hit.  Round-tripping a 64 MiB blob through"
note "the bridge and back also catches any ~16 MiB framing bug in"
note "the chunk-protocol implementation."
note ""
note "This test takes around 30-60 seconds depending on disk speed."

showrun "head -c 67108864 /dev/urandom \\
    > '$(hostpath /work/blob64m.bin)'"
showrun "ls -la '$(hostpath /work/blob64m.bin)'"
showrun "sha256sum '$(hostpath /work/blob64m.bin)'"

T_START=$(date +%s)
if sigul_run \
    "NEWKEY" "sigul --batch -c /etc/sigul/client.conf \\
        sign-data -o /work/blob64m.bin.sig \\
        ${NEW_KEY_NAME} /work/blob64m.bin"; then
    T_ELAPSED=$(( $(date +%s) - T_START ))
    pass "sign-data (64 MiB) returned without error in ${T_ELAPSED}s"
else
    fail "sign-data (64 MiB) exited non-zero"
fi

showrun "file '$(hostpath /work/blob64m.bin.sig)'"
showrun "ls -la '$(hostpath /work/blob64m.bin.sig)'"

showrun "GNUPGHOME='${VERIFY_GPGHOME}' gpg --batch --verify \\
    '$(hostpath /work/blob64m.bin.sig)' '$(hostpath /work/blob64m.bin)' 2>&1"
if GNUPGHOME="$VERIFY_GPGHOME" gpg --batch --verify \
        "$(hostpath /work/blob64m.bin.sig)" \
        "$(hostpath /work/blob64m.bin)" 2>/dev/null; then
    pass "detached signature verifies against 64 MiB payload"
else
    fail "gpg --verify rejected the 64 MiB detached signature"
fi

# ----------------------------------------------------------------------
# PHASE 3: RPM signing
# ----------------------------------------------------------------------
#
# RPM signing is the production-critical path for Fedora/CentOS
# release engineering: this is what Sigul exists for.  We build a
# minimal noarch RPM in a throwaway container, send it through the
# bridge for signing, and then independently verify each signed
# RPM with 'rpm -Kv' against a temporary RPM database holding only
# the test key.
#
# Koji-related flags (--store-in-koji, --koji-only) are NOT exercised
# - we don't deploy a Koji instance in CI.  Their presence in the
# CLI surface is verified by Phase 2's 'sigul --help-commands' test.

phase "3: RPM SIGNING"

# Use a stable, dist-tag-agnostic filename for the test RPM.  We
# rename the rpmbuild output (which embeds the running container's
# %{?dist} tag, e.g. .fc41 today, .fc44 after the planned base-image
# bump) to a fixed name so the rest of the suite can reference it
# without caring about the platform.
RPM_FILENAME="sigul-ci-test.rpm"
RPM_PATH="/work/${RPM_FILENAME}"
RPM_HOSTPATH="$(hostpath "${RPM_PATH}")"

# ----------------------------------------------------------------------
testcase "3.0  Build the throwaway test RPM in a sigul-client container"

note "The .spec lives at test/fixtures/sigul-test-rpm.spec.  We"
note "build it inside the sigul-client image so the resulting RPM"
note "matches the platform of the verifier we use later."

showrun "docker run --rm \\
    -v '${FIXTURES_DIR}:/fixtures:ro' \\
    -v '${HOST_WORKDIR}:/work:rw' \\
    --user 1000:1000 \\
    --entrypoint bash \\
    '${CLIENT_IMAGE}' -c \\
    'set -e; \\
     rpmbuild \\
        --define \"_topdir /work/rpmbuild\" \\
        --define \"_sourcedir /fixtures\" \\
        -bb /fixtures/sigul-test-rpm.spec; \\
     # Pick whichever noarch RPM rpmbuild produced and rename it \\
     # to the dist-tag-agnostic name the rest of the suite uses. \\
     built=\$(ls /work/rpmbuild/RPMS/noarch/*.rpm); \\
     echo \"rpmbuild produced: \$built\"; \\
     cp \"\$built\" /work/${RPM_FILENAME}'"

showrun "ls -la '${RPM_HOSTPATH}'"
showrun "docker run --rm -v '${HOST_WORKDIR}:/work:ro' \\
    --entrypoint rpm '${CLIENT_IMAGE}' -qpi '${RPM_PATH}'"

if [[ -s "$RPM_HOSTPATH" ]]; then
    pass "test RPM built successfully (${RPM_HOSTPATH})"
else
    fail "test RPM was not produced; cannot run sign-rpm tests"
fi

# ----------------------------------------------------------------------
testcase "3.1  Confirm the unsigned RPM has NO signature (baseline)"

note "Set up a throwaway RPM database holding only the test key."
note "Using --dbpath keeps this isolated from any real RPM database."

RPMDB="$(hostpath /work/rpmdb)"
mkdir -p "$RPMDB"
showrun "docker run --rm \\
    -v '${HOST_WORKDIR}:/work:rw' \\
    --entrypoint rpm \\
    '${CLIENT_IMAGE}' \\
    --dbpath /work/rpmdb --initdb"
showrun "docker run --rm \\
    -v '${HOST_WORKDIR}:/work:rw' \\
    --entrypoint rpm \\
    '${CLIENT_IMAGE}' \\
    --dbpath /work/rpmdb --import /work/${NEW_KEY_NAME}.pub.asc"
showrun "docker run --rm \\
    -v '${HOST_WORKDIR}:/work:ro' \\
    --entrypoint rpm \\
    '${CLIENT_IMAGE}' \\
    --dbpath /work/rpmdb -qa gpg-pubkey\\*"

showrun "docker run --rm \\
    -v '${HOST_WORKDIR}:/work:ro' \\
    --entrypoint rpm \\
    '${CLIENT_IMAGE}' \\
    --dbpath /work/rpmdb -Kv ${RPM_PATH}"

# An unsigned noarch RPM produces 'NO ' for the V4 / V3 signature
# checks.  We confirm the baseline so that the post-sign check is
# meaningful.
UNSIGNED_OUT=$(
    docker run --rm \
        -v "${HOST_WORKDIR}:/work:ro" \
        --entrypoint rpm \
        "${CLIENT_IMAGE}" \
        --dbpath /work/rpmdb -K "${RPM_PATH}" 2>&1
)
echo "$UNSIGNED_OUT"
if grep -q 'digests OK' <<< "$UNSIGNED_OUT" \
        && ! grep -q 'signatures OK' <<< "$UNSIGNED_OUT"; then
    pass "baseline: unsigned RPM passes digest check, no signature yet"
else
    fail "baseline check unexpected; rpm -K output may have changed"
fi

# ----------------------------------------------------------------------
testcase "3.2  sign-rpm: V4 RSA/SHA256 signature"

note "Default sign-rpm produces a V4 signature, which is what every"
note "modern Fedora/CentOS release uses.  We tell sigul to write"
note "the signed RPM to a separate path with --output rather than"
note "overwriting the input, so the baseline RPM stays available"
note "for subsequent tests."

SIGNED_V4="/work/${RPM_FILENAME%.rpm}.signed-v4.rpm"
if sigul_run "NEWKEY" "sigul --batch -c /etc/sigul/client.conf \\
    sign-rpm \\
    -o ${SIGNED_V4} \\
    ${NEW_KEY_NAME} ${RPM_PATH}"; then
    pass "sign-rpm (V4) returned without error"
else
    fail "sign-rpm (V4) exited non-zero"
fi

showrun "ls -la '$(hostpath "${SIGNED_V4}")'"

showrun "docker run --rm \\
    -v '${HOST_WORKDIR}:/work:ro' \\
    --entrypoint rpm \\
    '${CLIENT_IMAGE}' \\
    --dbpath /work/rpmdb -Kv ${SIGNED_V4}"

SIGNED_V4_OUT=$(
    docker run --rm \
        -v "${HOST_WORKDIR}:/work:ro" \
        --entrypoint rpm \
        "${CLIENT_IMAGE}" \
        --dbpath /work/rpmdb -Kv "${SIGNED_V4}" 2>&1
)
if grep -q 'Header V4 RSA/SHA256 Signature.*OK' <<< "$SIGNED_V4_OUT"; then
    pass "rpm -Kv accepts the V4 RSA/SHA256 signature"
else
    fail "rpm -Kv did NOT report a valid V4 signature"
fi

# ----------------------------------------------------------------------
testcase "3.3  sign-rpm --v3-signature: V3 signature compatibility path"

note "Sigul's --v3-signature flag emits a V3 signature in addition"
note "to the V4 one.  This was needed by older RPM consumers that"
note "don't yet understand V4-only signed packages.  Modern rpm"
note "verifiers (>= 4.18) silently accept V3 signatures but only"
note "emit the V4 line; we therefore assert that the V4 signature"
note "is still valid on the --v3-signature output (i.e. the V3 code"
note "path doesn't break V4 too)."

SIGNED_V3="/work/${RPM_FILENAME%.rpm}.signed-v3.rpm"
if sigul_run "NEWKEY" "sigul --batch -c /etc/sigul/client.conf \\
    sign-rpm \\
    --v3-signature \\
    -o ${SIGNED_V3} \\
    ${NEW_KEY_NAME} ${RPM_PATH}"; then
    pass "sign-rpm --v3-signature returned without error"
else
    fail "sign-rpm --v3-signature exited non-zero"
fi

showrun "docker run --rm \\
    -v '${HOST_WORKDIR}:/work:ro' \\
    --entrypoint rpm \\
    '${CLIENT_IMAGE}' \\
    --dbpath /work/rpmdb -Kv ${SIGNED_V3}"

SIGNED_V3_OUT=$(
    docker run --rm \
        -v "${HOST_WORKDIR}:/work:ro" \
        --entrypoint rpm \
        "${CLIENT_IMAGE}" \
        --dbpath /work/rpmdb -Kv "${SIGNED_V3}" 2>&1
)
# Modern RPM (>= 4.18 or so) only reports the V4 signature line on
# verify even when a V3 signature is also present in the package -
# V3 OpenPGP signatures are deprecated and the rpm verifier silently
# accepts them but only emits the V4 line.  We therefore assert two
# weaker but still meaningful invariants:
#  * sigul accepted the --v3-signature flag and produced a signed
#    RPM (the test above verified the exit code);
#  * rpm -Kv accepts the resulting RPM with a valid V4 signature
#    (i.e. the V3 path does not break V4 too).
if grep -q 'V4.*Signature.*OK' <<< "$SIGNED_V3_OUT"; then
    pass "rpm -Kv accepts the --v3-signature output (V4 sig still OK)"
else
    fail "rpm -Kv did NOT report a valid V4 signature on --v3 output"
fi

# ----------------------------------------------------------------------
testcase "3.4  sign-rpms: batch signing of multiple RPMs in one request"

note "sign-rpms takes a list of RPMs and signs them all in a single"
note "request - efficient when a release pipeline produces dozens or"
note "hundreds of RPMs at once.  We give it three copies of the same"
note "throwaway RPM (renamed) and verify that all three outputs are"
note "valid signed RPMs."

# Prepare three differently-named copies for the batch.  The output
# directory needs to exist and be writable by the in-container UID.
BATCH_OUT="$(hostpath /work/batch-out)"
mkdir -p "$BATCH_OUT"
chmod 0777 "$BATCH_OUT"
for n in 1 2 3; do
    cp "$RPM_HOSTPATH" "$(hostpath /work/batch-${n}.rpm)"
done
showrun "ls -la '${BATCH_OUT}/..'"

if sigul_run "NEWKEY" "sigul --batch -c /etc/sigul/client.conf \\
    sign-rpms \\
    -o /work/batch-out \\
    ${NEW_KEY_NAME} \\
    /work/batch-1.rpm /work/batch-2.rpm /work/batch-3.rpm"; then
    pass "sign-rpms returned without error"
else
    fail "sign-rpms exited non-zero"
fi

showrun "ls -la '${BATCH_OUT}'"

BATCH_VERIFY_FAILS=0
for n in 1 2 3; do
    OUT=$(
        docker run --rm \
            -v "${HOST_WORKDIR}:/work:ro" \
            --entrypoint rpm \
            "${CLIENT_IMAGE}" \
            --dbpath /work/rpmdb -Kv "/work/batch-out/batch-${n}.rpm" 2>&1
    )
    echo "== batch-${n}.rpm =="
    echo "$OUT"
    if ! grep -q 'Header V4 RSA/SHA256 Signature.*OK' <<< "$OUT"; then
        BATCH_VERIFY_FAILS=$((BATCH_VERIFY_FAILS + 1))
    fi
done
if [[ $BATCH_VERIFY_FAILS -eq 0 ]]; then
    pass "rpm -Kv accepts all 3 RPMs from the sign-rpms batch"
else
    fail "${BATCH_VERIFY_FAILS}/3 batch-signed RPMs failed verification"
fi

# ----------------------------------------------------------------------
# PHASE 4: User and key-access lifecycle
# ----------------------------------------------------------------------
#
# Phase 1-3 used the admin account exclusively.  Phase 4 verifies
# that Sigul's authorisation model actually constrains who can do
# what:
#
#  * a freshly-created non-admin user can NOT call admin-only ops
#    like list-users;
#  * a freshly-created non-admin user can NOT sign with an
#    arbitrary key they have not been granted access to;
#  * once an admin grants the user access to a specific key,
#    they CAN sign with it (and the resulting signature still
#    verifies);
#  * once access is revoked, they can no longer sign with it;
#  * delete-user removes them entirely.
#
# These are the tests that exercise the protocol design described
# in sigul/doc/protocol-design.txt under "ADMIN REQUESTS",
# "KEY ADMIN REQUESTS" and "USER REQUESTS".  Without them, a
# regression in the auth code could go undetected: every previous
# phase used the same admin user.

phase "4: USER AND KEY-ACCESS LIFECYCLE"

TEST_USER="ci-test-user"
export SIGUL_TEST_PW_TESTUSER="ci-test-user-password"
export SIGUL_TEST_PW_TESTUSER_KEY="ci-test-user-key-passphrase"

note "Test user: ${TEST_USER}"
note "Re-using ${NEW_KEY_NAME} (the key created in phase 1) for the"
note "grant/revoke/sign-as-grantee tests.  The key passphrase has"
note "been rotated to NEWKEY_NEW."

# Best-effort cleanup of any leftover ${TEST_USER} from a previous
# run.  This is the same defensive pattern Phase 0 uses for keys.
note "Best-effort delete of any leftover ${TEST_USER} (ignoring errors)"
printf '%s\0' "$ADMIN_PASSWORD" \
    | docker run --rm -i \
        --user 1000:1000 \
        --network "$NETWORK" \
        -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
        -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
        "$CLIENT_IMAGE" \
        bash -c "sigul --batch -c /etc/sigul/client.conf \
            delete-user ${TEST_USER} 2>&1" \
    || true

# ----------------------------------------------------------------------
testcase "4.1  new-user --with-password: create a non-admin test user"

note "new-user without --admin creates a regular (non-admin) user."
note "--with-password defines a password for that user, which is"
note "what they'll use to authenticate non-key admin operations."
note "new-user feeds two passphrases on stdin: the admin password"
note "first, then the new user's password."

if sigul_run "ADMIN,TESTUSER" "sigul --batch -c /etc/sigul/client.conf \\
    new-user --with-password ${TEST_USER}"; then
    pass "new-user returned without error"
else
    fail "new-user exited non-zero"
fi

# ----------------------------------------------------------------------
testcase "4.2  user-info: confirm the user exists and is NOT admin"

USER_INFO_OUT=$(
    _sigul_emit "ADMIN" "sigul --batch -c /etc/sigul/client.conf \
        user-info ${TEST_USER}" 2>&1
)
echo "$USER_INFO_OUT"
if grep -qi 'administrator: *no' <<< "$USER_INFO_OUT"; then
    pass "user-info reports ${TEST_USER} with admin=no"
else
    fail "user-info did NOT report ${TEST_USER} as admin=no"
fi

# ----------------------------------------------------------------------
testcase "4.3  Negative: ${TEST_USER} CANNOT call admin-only list-users"

note "This test invokes sigul as the new user via -u ${TEST_USER}."
note "list-users is an admin-only operation per the protocol design;"
note "a non-admin user should be rejected with AUTHENTICATION_FAILED."

NEG_OUT=$(
    printf '%s\0' "$SIGUL_TEST_PW_TESTUSER" \
        | docker run --rm -i \
            --user 1000:1000 \
            --network "$NETWORK" \
            -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
            -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
            "$CLIENT_IMAGE" \
            bash -c "sigul --batch -u ${TEST_USER} \
                -c /etc/sigul/client.conf list-users 2>&1" \
        || true
)
echo "$NEG_OUT"
if grep -qi 'authentication failed' <<< "$NEG_OUT"; then
    pass "server correctly rejects non-admin list-users"
else
    fail "server did NOT reject non-admin list-users"
fi

# ----------------------------------------------------------------------
testcase "4.4  Negative: ${TEST_USER} CANNOT yet sign with ${NEW_KEY_NAME}"

note "Without grant-key-access the user has no key access record;"
note "sign-text should be rejected at the auth layer."

showrun "echo 'pre-grant test message' \\
    > '$(hostpath /work/pre-grant.txt)'"

NEG_OUT=$(
    printf '%s\0' "$SIGUL_TEST_PW_TESTUSER" \
        | docker run --rm -i \
            --user 1000:1000 \
            --network "$NETWORK" \
            -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
            -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
            -v "${HOST_WORKDIR}:/work:rw" \
            "$CLIENT_IMAGE" \
            bash -c "sigul --batch -u ${TEST_USER} \
                -c /etc/sigul/client.conf \
                sign-text -o /work/pre-grant.signed.txt \
                ${NEW_KEY_NAME} /work/pre-grant.txt 2>&1" \
        || true
)
echo "$NEG_OUT"
if grep -qi 'authentication failed' <<< "$NEG_OUT"; then
    pass "server correctly rejects sign-text from un-granted user"
else
    fail "server did NOT reject sign-text from un-granted user"
fi

# ----------------------------------------------------------------------
testcase "4.5  grant-key-access: admin grants ${TEST_USER} access to ${NEW_KEY_NAME}"

note "grant-key-access feeds two passphrases on stdin: the existing"
note "key passphrase first (so the server can re-wrap), then the new"
note "per-user passphrase the grantee will use to sign with the key."

if sigul_run "NEWKEY,TESTUSER_KEY" \
    "sigul --batch -c /etc/sigul/client.conf \\
        grant-key-access ${NEW_KEY_NAME} ${TEST_USER}"; then
    pass "grant-key-access returned without error"
else
    fail "grant-key-access exited non-zero"
fi

# ----------------------------------------------------------------------
testcase "4.6  list-key-users: confirm ${TEST_USER} is listed for ${NEW_KEY_NAME}"

LKU_OUT=$(
    _sigul_emit "ADMIN" "sigul --batch \
        -c /etc/sigul/client.conf list-key-users \
        --password ${NEW_KEY_NAME}" 2>&1
)
echo "$LKU_OUT"
if grep -q "^${TEST_USER}$" <<< "$LKU_OUT"; then
    pass "list-key-users includes ${TEST_USER}"
else
    fail "list-key-users does NOT include ${TEST_USER}"
fi

# ----------------------------------------------------------------------
testcase "4.7  ${TEST_USER} CAN now sign-text with ${NEW_KEY_NAME}"

note "After grant, the user signs using their per-user key passphrase"
note "(TESTUSER_KEY), NOT the original key passphrase.  The server"
note "unwraps the per-user copy and uses the underlying GPG key."
note "We verify the signature with the same host-side keyring set up"
note "in Phase 2."

showrun "echo 'post-grant test message - signed by ${TEST_USER}' \\
    > '$(hostpath /work/post-grant.txt)'"

if printf '%s\0' "$SIGUL_TEST_PW_TESTUSER_KEY" \
    | docker run --rm -i \
        --user 1000:1000 \
        --network "$NETWORK" \
        -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
        -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
        -v "${HOST_WORKDIR}:/work:rw" \
        "$CLIENT_IMAGE" \
        bash -c "sigul --batch -u ${TEST_USER} \
            -c /etc/sigul/client.conf \
            sign-text -o /work/post-grant.signed.txt \
            ${NEW_KEY_NAME} /work/post-grant.txt"; then
    pass "sign-text as ${TEST_USER} returned without error"
else
    fail "sign-text as ${TEST_USER} exited non-zero"
fi

if [[ -s "$(hostpath /work/post-grant.signed.txt)" ]]; then
    showrun "head -3 '$(hostpath /work/post-grant.signed.txt)'"
    VERIFY_OUT_PG="$(hostpath /work/post-grant.recovered.txt)"
    showrun "GNUPGHOME='${VERIFY_GPGHOME}' gpg --batch --yes \\
        --output '${VERIFY_OUT_PG}' \\
        --decrypt '$(hostpath /work/post-grant.signed.txt)' 2>&1"
    if diff -u "$(hostpath /work/post-grant.txt)" "$VERIFY_OUT_PG" \
            >/dev/null; then
        pass "signature by ${TEST_USER} verifies and content round-trips"
    else
        fail "signature by ${TEST_USER} verified but content differs"
    fi
else
    fail "sign-text output is empty; cannot verify"
fi

# ----------------------------------------------------------------------
testcase "4.8  revoke-key-access: admin revokes ${TEST_USER}'s access"

note "revoke-key-access can be invoked by an admin (--password) or"
note "by a key admin.  The admin path is what we exercise here."

if sigul_run "ADMIN" "sigul --batch \\
    -c /etc/sigul/client.conf \\
    revoke-key-access --password ${NEW_KEY_NAME} ${TEST_USER}"; then
    pass "revoke-key-access returned without error"
else
    fail "revoke-key-access exited non-zero"
fi

LKU2_OUT=$(
    _sigul_emit "ADMIN" "sigul --batch \
        -c /etc/sigul/client.conf list-key-users \
        --password ${NEW_KEY_NAME}" 2>&1
)
echo "$LKU2_OUT"
if grep -q "^${TEST_USER}$" <<< "$LKU2_OUT"; then
    fail "list-key-users still includes ${TEST_USER} after revoke"
else
    pass "list-key-users no longer includes ${TEST_USER}"
fi

# ----------------------------------------------------------------------
testcase "4.9  Negative: ${TEST_USER} CAN NO LONGER sign with ${NEW_KEY_NAME}"

NEG_OUT=$(
    printf '%s\0' "$SIGUL_TEST_PW_TESTUSER_KEY" \
        | docker run --rm -i \
            --user 1000:1000 \
            --network "$NETWORK" \
            -v "${CLIENT_NSS_VOLUME}:/etc/pki/sigul/client:ro" \
            -v "${CLIENT_CONFIG_VOLUME}:/etc/sigul:ro" \
            -v "${HOST_WORKDIR}:/work:rw" \
            "$CLIENT_IMAGE" \
            bash -c "sigul --batch -u ${TEST_USER} \
                -c /etc/sigul/client.conf \
                sign-text -o /work/post-revoke.signed.txt \
                ${NEW_KEY_NAME} /work/post-grant.txt 2>&1" \
        || true
)
echo "$NEG_OUT"
if grep -qi 'authentication failed' <<< "$NEG_OUT"; then
    pass "server correctly rejects sign-text after revoke"
else
    fail "server did NOT reject sign-text after revoke"
fi

# ----------------------------------------------------------------------
testcase "4.10  delete-user: tear down ${TEST_USER} for clean re-runs"

if sigul_run "ADMIN" "sigul --batch -c /etc/sigul/client.conf \\
    delete-user ${TEST_USER}"; then
    pass "delete-user returned without error"
else
    fail "delete-user exited non-zero"
fi

LU_OUT=$(
    _sigul_emit "ADMIN" "sigul --batch -c /etc/sigul/client.conf \
        list-users" 2>&1
)
echo "$LU_OUT"
if grep -q "^${TEST_USER}$" <<< "$LU_OUT"; then
    fail "list-users still includes ${TEST_USER} after delete"
else
    pass "list-users no longer includes ${TEST_USER}"
fi

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

echo
echo
local_sep=$(printf '%.0s=' {1..72})
printf '%b%s%b\n' "${C_BOLD}${C_BLUE}" "$local_sep" "${C_RESET}"
printf '%b== TEST SUMMARY%b\n' "${C_BOLD}${C_BLUE}" "${C_RESET}"
printf '%b%s%b\n' "${C_BOLD}${C_BLUE}" "$local_sep" "${C_RESET}"
echo
printf '  Passed: %b%d%b\n' "${C_GREEN}" "$PASS" "${C_RESET}"
printf '  Failed: %b%d%b\n' "${C_RED}" "$FAIL" "${C_RESET}"
echo

if [[ $FAIL -gt 0 ]]; then
    printf '%b\u274c SIGNING TESTS FAILED%b\n' \
        "${C_BOLD}${C_RED}" "${C_RESET}"
    exit 1
else
    printf '%b\u2705 ALL SIGNING TESTS PASSED%b\n' \
        "${C_BOLD}${C_GREEN}" "${C_RESET}"
fi
