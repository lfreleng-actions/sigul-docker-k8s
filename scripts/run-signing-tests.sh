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
#
# Future phases (PR-B, PR-C, PR-D) will add:
# Phase 2: Text and binary signing including a 64 MiB blob.
# Phase 3: RPM signing (sign-rpm, sign-rpms, --v3-signature,
#          --head-signing).
# Phase 4: User and key-access lifecycle (new-user,
#          grant-key-access, revoke-key-access, delete-user).
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
HOST_WORKDIR="$(mktemp -d /tmp/sigul-signing-tests.XXXXXX)"
trap 'rm -rf "$HOST_WORKDIR"' EXIT
chmod 755 "$HOST_WORKDIR"

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
