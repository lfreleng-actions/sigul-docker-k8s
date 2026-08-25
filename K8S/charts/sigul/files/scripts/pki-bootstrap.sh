#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# PKI bootstrap for the sigul chart.
#
# Runs once per release (Argo CD sync-wave 0 / Helm pre-install hook)
# inside the bridge image (provides certutil, pk12util, python3).
# Generates the tenant's private PKI with the same certutil mechanics
# as scripts/cert-init.sh in this repository (same nicknames, sql: DB
# format, trust flags, auto serials - see docs/CERTIFICATE_INITIALIZATION.md)
# and publishes the results as Kubernetes Secrets via the API
# (publish-secrets.py) instead of a shared volume.
#
# Idempotency contract (PKI_MODE):
#   auto  - if the marker Secret records a completed bootstrap, exit 0
#           without changes; refuse to regenerate over surviving PKI
#           material whose marker was lost
#   force - regenerate and overwrite (DESTROYS the trust domain)
#   skip  - exit 0 unconditionally
#
# Runs at most once at a time per release: a Lease acquired below
# serialises concurrent runners (plain Helm can have two revisioned
# bootstrap Jobs alive at once).
#
# Required environment (set by the Job template):
#   PKI_MODE, EXTERNAL_FQDN, INTERNAL_FQDN, BRIDGE_SERVICE_NAME,
#   CA_VALIDITY_MONTHS, CERT_VALIDITY_MONTHS,
#   SECRET_CA_PUBLIC, SECRET_BRIDGE_P12, SECRET_SERVER_P12,
#   SECRET_CLIENT_P12, SECRET_PASSWORDS, SECRET_ADMIN, SECRET_MARKER,
#   LOCK_LEASE, LOCK_DURATION_SECONDS, POD_NAME,
#   BRIDGE_DEPLOYMENT, SERVER_STATEFULSET

set -euo pipefail

log() { printf '[pki-bootstrap] %s\n' "$*"; }
die() { printf '[pki-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

# Total deadline per invocation, so the shell is never stuck in a
# foreground helper long enough to lose the scrub below.
#
# k8s_api.py bounds each HTTP request at 30s, but a single subcommand
# issues at most two sequentially (apply/lock/unlock all do a GET then
# a PATCH), so the real worst case is ~60s, not 30. 70 leaves slack
# for interpreter start-up without truncating a legitimately slow
# call; the Job's terminationGracePeriodSeconds is sized above it.
# Exit 124 on timeout, which the || die callers already treat as
# failure and the Job retries.
PUBLISH=(timeout 70 python3 /scripts/publish-secrets.py)
WORK=/work
NSSDIR="${WORK}/nssdb"
OUT="${WORK}/out"

# The scratch NSS database holds the CA *private* key, and /work also
# accumulates the NSS and P12 passwords in plain files. All of it is
# memory-backed (emptyDir medium: Memory), but a failed pod is not
# deleted immediately - backoffLimit retries it, and
# ttlSecondsAfterFinished keeps the Job around for an hour - so that
# tmpfs, and the CA key in it, outlives the process that created it.
#
# Scrubbing only on the success path would therefore leave the key
# behind on exactly the runs nobody planned for. Register it as an
# EXIT trap instead, before any key material exists, so it covers
# die(), a set -e abort, and ordinary termination.
#
# It cannot cover SIGKILL - an OOM kill, or the kubelet's hard stop
# once the termination grace period expires. No in-process mechanism
# can: the tmpfs then survives with the pod object, bounded by the
# Job's ttlSecondsAfterFinished. That residual window is why the
# emptyDir is memory-backed rather than disk-backed - the scratch
# stays in tmpfs instead of landing in the container filesystem.
#
# tmpfs is not an absolute guarantee: its pages can be paged out to
# node swap. A deployment that requires the CA key never to touch
# disk needs swap disabled on the nodes (long the kubelet's own
# requirement, and still the default) or a noswap tmpfs mount.
scrub_scratch() {
    # ${WORK:?} so an unset WORK can never turn this into rm -rf /*.
    # Dotfiles are matched explicitly (.nss-password, .noise,
    # .p12-password); /work itself is the mount point and stays.
    rm -rf -- "${WORK:?}"/* "${WORK:?}"/.[!.]* 2>/dev/null || true
}
trap scrub_scratch EXIT

# Signals whose default disposition is to kill the shell outright,
# which can bypass the EXIT trap. Turning each into a normal exit
# guarantees the trap runs; 128+signo is the conventional status.
# SIGTERM matters most - it is what the kubelet sends first, and what
# an activeDeadlineSeconds timeout delivers before the SIGKILL.
#
# Bash defers a trapped signal until the foreground command returns,
# and does not forward it to that child, so the scrub happens after
# the in-flight certutil/pk12util/publish-secrets call finishes
# rather than immediately - and the trap then makes a further bounded
# call of its own to release the lock. Both are capped (certutil and
# pk12util are local and fast; publish-secrets carries the timeout
# above), and the Job's terminationGracePeriodSeconds budgets for the
# pair, so the trap runs to completion. A command hanging past the
# grace period is still SIGKILLed with the scratch in place; see the
# SIGKILL note above.
trap 'exit 143' TERM
trap 'exit 130' INT

: "${PKI_MODE:=auto}"
: "${CA_VALIDITY_MONTHS:=120}"
: "${CERT_VALIDITY_MONTHS:=24}"

[ -n "${EXTERNAL_FQDN:-}" ] || die "EXTERNAL_FQDN not set"
[ -n "${INTERNAL_FQDN:-}" ] || die "INTERNAL_FQDN not set"

genpw() { head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24; }

case "${PKI_MODE}" in
    skip)
        log "PKI_MODE=skip - nothing to do"
        exit 0
        ;;
    auto|force) ;;
    *)
        die "Unknown PKI_MODE '${PKI_MODE}' (want auto|force|skip)"
        ;;
esac

# ---------------------------------------------------------------------------
# Mutual exclusion.
#
# The Job name is revisioned, so plain Helm can leave two bootstrap
# Jobs running at once (a second `helm upgrade` before the first
# finished). Both would generate independently and interleave their
# writes to the CA, P12 and password Secrets, leaving a mixed trust
# domain that the loser then marks complete. Per-Secret resourceVersion
# checks cannot prevent that - each writer legitimately reads the
# latest version before patching - so exclusion has to happen once,
# up front, at a single compare-and-set point.
#
# The loser exits non-zero; the Job's backoff retries it after the
# holder has finished, at which point it observes the completed marker
# and exits cleanly.
# ---------------------------------------------------------------------------
LOCK_IDENTITY="${POD_NAME:-pki-bootstrap-$$}"
release_lock() {
    [ -n "${LOCK_LEASE:-}" ] || return 0
    "${PUBLISH[@]}" unlock "${LOCK_LEASE}" --identity "${LOCK_IDENTITY}" || true
}

if [ -n "${LOCK_LEASE:-}" ]; then
    "${PUBLISH[@]}" lock "${LOCK_LEASE}" \
        --identity "${LOCK_IDENTITY}" \
        --duration "${LOCK_DURATION_SECONDS:-1800}" \
        || die "Could not acquire the bootstrap lock for this release
(Lease '${LOCK_LEASE}'). Another run most likely holds it - see the
error above. Refusing to run concurrently, because interleaved writes
would produce a mixed trust domain. This run is retried automatically."
    # Replaces the scrub-only trap registered above: bash keeps one
    # handler per signal, so both duties have to live in the one trap.
    trap 'scrub_scratch; release_lock' EXIT
fi

# ---------------------------------------------------------------------------
# Bootstrap state.
#
# The marker Secret records progress, not merely completion:
#   complete    - a previous run published a full trust domain
#   in-progress - a previous run died mid-publish, so whatever landed
#                 was never usable and regenerating is safe
#   none        - the marker is empty: nothing has been published, OR
#                 the marker itself was lost (distinguished below by
#                 looking at the PKI Secrets)
# ---------------------------------------------------------------------------
PKI_SECRETS=(
    "${SECRET_CA_PUBLIC}"
    "${SECRET_BRIDGE_P12}"
    "${SECRET_SERVER_P12}"
    "${SECRET_CLIENT_P12}"
    "${SECRET_PASSWORDS}"
)

# The key contract each Secret owes its consumers. Checking only for
# a non-empty Secret is not enough: a partial restore can leave the
# object populated but missing a key, and the workloads would then
# fail on a missing secretKeyRef long after this Job reported
# success. Keys mirror the secretKeyRef/volume items in the workload
# templates and the publish calls at the end of this script.
secret_key_args() {
    case "$1" in
        "${SECRET_CA_PUBLIC}")
            printf '%s\n' --key ca.crt --key bridge.crt ;;
        "${SECRET_BRIDGE_P12}")
            printf '%s\n' --key bridge.p12 ;;
        "${SECRET_SERVER_P12}")
            printf '%s\n' --key server.p12 ;;
        "${SECRET_CLIENT_P12}")
            printf '%s\n' --key client.p12 ;;
        "${SECRET_PASSWORDS}")
            printf '%s\n' --key bridge-nss-password \
                --key server-nss-password \
                --key client-nss-password \
                --key p12-password ;;
    esac
}

pki_secret_ok() {
    local keys=()
    mapfile -t keys < <(secret_key_args "$1")
    "${PUBLISH[@]}" exists "$1" "${keys[@]}"
}

# A rotation replaces a trust domain that components may already hold,
# but both workloads rebuild their NSS databases from Secrets only at
# pod start (initContainer into emptyDir), so every component must be
# restarted or the old PKI stays live (a partial restart creates a
# split trust domain).
#
# The obligation is recorded on the marker and cleared ONLY here, once
# the rollout has actually been triggered. On the manual path it stays
# set, so the outstanding work survives this pod, is visible to an
# operator, and is picked up again by the next run.
#
# Automated restarts are opt-in (pki.forceRestartWorkloads grants the
# required workload-patch RBAC); the default is a manual, operator-
# driven rollout using the operator's own identity.
perform_rotation_restart() {
    if [ -z "${BRIDGE_DEPLOYMENT:-}" ]; then
        log "rotation: MANUAL ACTION REQUIRED - restart every component"
        log "so nothing keeps the old trust domain, e.g.:"
        log "  kubectl -n <namespace> rollout restart deployment -l app.kubernetes.io/instance=<release>"
        log "  kubectl -n <namespace> rollout restart statefulset -l app.kubernetes.io/instance=<release>"
        log "then clear the outstanding obligation:"
        log "  kubectl -n <namespace> patch secret ${SECRET_MARKER} --type merge -p '{\"stringData\":{\"rotation-required\":\"false\"}}'"
        log "(automation available via pki.forceRestartWorkloads=true)"
        return 0
    fi

    log "rotation: triggering coordinated bridge/server restart"
    "${PUBLISH[@]}" restart deployment "${BRIDGE_DEPLOYMENT}"
    "${PUBLISH[@]}" restart statefulset "${SERVER_STATEFULSET}"
    if [ -n "${ADMIN_TOOLBOX_DEPLOYMENT:-}" ]; then
        # Not tolerated: the toolbox caches the client NSS database in
        # an emptyDir too, so skipping it leaves a component on the
        # old trust domain - and the obligation is cleared below. A
        # missing Deployment is already a logged no-op in the restart
        # subcommand, so a failure here is a real one.
        "${PUBLISH[@]}" restart deployment "${ADMIN_TOOLBOX_DEPLOYMENT}"
    fi
    # Only now is the obligation discharged. Reaching this line means
    # every rollout was accepted by the API server; a failure above
    # aborts the script (set -e) with the marker still flagged, so the
    # Job retry repeats the rollout.
    "${PUBLISH[@]}" apply "${SECRET_MARKER}" --literal "rotation-required=false"
}

MARKER_STATE=none
if "${PUBLISH[@]}" exists "${SECRET_MARKER}"; then
    # A populated marker without a 'state' key was written by hand;
    # treat it as a completed bootstrap. 'get' only ever prints
    # vetted literals (complete|in-progress|unrecognized), never raw
    # Secret content, so the value is safe to log below.
    MARKER_STATE="$("${PUBLISH[@]}" get "${SECRET_MARKER}" state || echo complete)"
    case "${MARKER_STATE}" in
        complete|in-progress) ;;
        *)
            # Fail closed rather than guess: an unrecognized state
            # must never fall through to "looks like a new install".
            die "Marker Secret '${SECRET_MARKER}' does not hold a
recognized state (want complete|in-progress). Refusing to act on an
ambiguous bootstrap state - inspect the Secret and repair it."
            ;;
    esac
fi

PKI_COMPLETE=0
PKI_NONEMPTY=0
PKI_INCOMPLETE=()
for s in "${PKI_SECRETS[@]}"; do
    # Two distinct questions, deliberately not conflated:
    #   nonempty - "is there material here at all?", which is what
    #              decides whether regenerating would destroy
    #              something. A Secret missing one key still holds a
    #              CA and P12 bundles that live pods may be using.
    #   complete - "does it satisfy its consumers' key contract?",
    #              which is what a completed marker must guarantee.
    if "${PUBLISH[@]}" exists "${s}"; then
        PKI_NONEMPTY=$((PKI_NONEMPTY + 1))
    fi
    if pki_secret_ok "${s}"; then
        PKI_COMPLETE=$((PKI_COMPLETE + 1))
    else
        PKI_INCOMPLETE+=("${s}")
    fi
done

log "Bootstrap state: marker=${MARKER_STATE}, PKI Secrets ${PKI_COMPLETE}/${#PKI_SECRETS[@]} complete, ${PKI_NONEMPTY}/${#PKI_SECRETS[@]} non-empty (mode=${PKI_MODE})"

# ---------------------------------------------------------------------------
# Admin credential: deliberately decoupled from the PKI lifecycle. It
# is hashed into the server's persistent database at first boot, so it
# must never be regenerated once the system is bootstrapped - a fresh
# password could not authenticate against the retained hash.
#
# Consistency check first: a completed marker with an empty admin
# Secret means the credential was lost AFTER bootstrap. Generating a
# new one would permanently lock administrators out, so fail with
# recovery guidance instead. Only a genuinely new installation
# generates the credential (further down, once the guards below have
# confirmed there is nothing to preserve).
# ---------------------------------------------------------------------------
# Any marker state other than 'none' means a previous run got as far
# as claiming the marker, and the admin Secret is created BEFORE that
# claim - so an empty one here always means the credential was lost,
# never that it was not yet created. Regenerating would produce a
# password the persistent database (which keeps the original hash)
# can never accept, so fail closed for complete AND in-progress.
if [ "${MARKER_STATE}" != "none" ] \
        && ! "${PUBLISH[@]}" exists "${SECRET_ADMIN}" --key admin-password; then
    die "PKI bootstrap has run before (marker ${MARKER_STATE}) but the
admin credential Secret '${SECRET_ADMIN}' is empty or missing its
'admin-password' key. The server database still holds the original
password hash - generating a new password would lock administrators
out permanently. Recover by restoring the Secret from backup, or
reset the credential out-of-band (e.g. sigul_server_add_admin
against the existing database), then re-run."
fi

if [ "${PKI_MODE}" = "auto" ] && [ "${MARKER_STATE}" = "complete" ]; then
    # The marker alone is not proof the material survived: verify
    # every PKI Secret is still populated (an accidentally deleted
    # Secret recreated empty by a sync would otherwise strand newly
    # scheduled workloads).
    [ "${PKI_COMPLETE}" -eq "${#PKI_SECRETS[@]}" ] || die "Marker records a
completed bootstrap but these Secrets are empty or missing required
keys: ${PKI_INCOMPLETE[*]} - the PKI material was lost or partially
restored after bootstrap. Restore the Secrets from backup, or
regenerate the entire trust domain with PKI_MODE=force (breaks
existing client bundles)."
    log "Marker Secret '${SECRET_MARKER}' complete and all PKI Secrets verified - already bootstrapped (mode=auto)"
    # An obligation left over from an earlier run (a failed automated
    # rollout, or a manual one the operator has not confirmed) is
    # still outstanding: components may be running the superseded
    # trust domain. Discharge it here rather than exiting quietly.
    if [ "$("${PUBLISH[@]}" get "${SECRET_MARKER}" rotation-required || echo false)" = "true" ]; then
        log "WARNING: a previous run left a restart obligation outstanding."
        perform_rotation_restart
    fi
    exit 0
fi

# The mirror image of the check above: the marker is empty but PKI
# material exists. Treating that as a new installation would silently
# replace a live trust domain - the running pods rebuild their NSS
# databases only at start, so they would keep the old PKI while the
# Secrets held the new one, and every issued client bundle would
# break. Only an explicit PKI_MODE=force may overwrite existing
# material. 'in-progress' is exempt: that material was never complete.
#
# Deliberately keyed on the NON-EMPTY count, not the complete one: a
# Secret set that fails its key contract is still material that live
# pods may be running on, and must not be silently overwritten.
if [ "${PKI_MODE}" != "force" ] && [ "${MARKER_STATE}" = "none" ] \
        && [ "${PKI_NONEMPTY}" -gt 0 ]; then
    die "${PKI_NONEMPTY} of ${#PKI_SECRETS[@]} PKI Secrets hold material
but the bootstrap marker '${SECRET_MARKER}' is empty. Regenerating
now would replace a live trust domain, so this run refuses to
continue. If the marker was lost accidentally the material is
intact: confirm the PKI Secrets are consistent, then re-seal the
marker with
  kubectl -n <namespace> patch secret ${SECRET_MARKER} --type merge \\
      -p '{\"stringData\":{\"state\":\"complete\"}}'
To rebuild the trust domain deliberately, re-run with PKI_MODE=force
(pki.mode=force) and restart every component."
fi

# The end-of-run restart decision. A rotation replaces a trust domain
# that components may already hold, so it must end with a coordinated
# restart. Distinct from the marker's rotation-required key, which
# records the same obligation for whoever RECOVERS this run: this
# variable answers "must I restart when I finish?", the marker answers
# "must my successor restart?".
#
# True when this run is an explicit rotation, or when it is recovering
# an interrupted run that had already replaced or published material.
RESTART_AFTER_RUN=false
[ "${PKI_MODE}" != "force" ] || RESTART_AFTER_RUN=true

if [ "${MARKER_STATE}" = "in-progress" ]; then
    if [ "$("${PUBLISH[@]}" get "${SECRET_MARKER}" rotation-required || echo false)" = "true" ]; then
        RESTART_AFTER_RUN=true
    fi
    log "WARNING: a previous run did not complete (marker state=in-progress)."
    log "Its output was never a usable trust domain, so this run regenerates."
    if [ "${RESTART_AFTER_RUN}" = "true" ]; then
        log "The interrupted run had already replaced or published material,"
        log "so the coordinated restart still applies."
    fi
fi

if ! "${PUBLISH[@]}" exists "${SECRET_ADMIN}" --key admin-password; then
    ADMIN_PASSWORD="$(genpw)"
    "${PUBLISH[@]}" apply "${SECRET_ADMIN}" --if-absent \
        --literal "admin-password=${ADMIN_PASSWORD}"
    unset ADMIN_PASSWORD
    # --if-absent declines to write whenever /data is non-empty, which
    # a malformed Secret can be without holding the key - so confirm
    # the write rather than assume it. Continuing would mark the PKI
    # complete with no usable administrator, and the next run would
    # report the credential as lost.
    "${PUBLISH[@]}" exists "${SECRET_ADMIN}" --key admin-password \
        || die "Admin credential Secret '${SECRET_ADMIN}' holds data but
no 'admin-password' key, and was left untouched rather than
overwritten (its other contents are unknown to this Job). Inspect
it: restore the correct credential, or clear the Secret's data if
this is a new installation, then re-run."
fi

[ "${PKI_MODE}" != "force" ] || \
    log "PKI_MODE=force - regenerating PKI (existing trust domain is destroyed)"

# Claim the marker before publishing anything. If this pod dies
# part-way through, the next run sees 'in-progress', knows the
# material it finds was never complete, and regenerates instead of
# refusing to touch it. rotation-required carries the restart
# obligation across that recovery; force claims it immediately
# because the marker no longer guards the still-live old domain.
"${PUBLISH[@]}" apply "${SECRET_MARKER}" \
    --literal "state=in-progress" \
    --literal "started-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --literal "rotation-required=${RESTART_AFTER_RUN}" \
    --literal "mode=${PKI_MODE}"

# ---------------------------------------------------------------------------
# Password generation (per-component NSS passwords: an improvement over
# the compose stack's single shared password - EVALUATION.md 4.2)
# ---------------------------------------------------------------------------
BRIDGE_NSS_PASSWORD="$(genpw)"
SERVER_NSS_PASSWORD="$(genpw)"
CLIENT_NSS_PASSWORD="$(genpw)"
P12_PASSWORD="$(genpw)"

mkdir -p "${NSSDIR}" "${OUT}"
chmod 700 "${NSSDIR}"

PWFILE="${WORK}/.nss-password"
NOISE="${WORK}/.noise"
printf '%s' "${BRIDGE_NSS_PASSWORD}" > "${PWFILE}"
chmod 600 "${PWFILE}"
head -c 1024 /dev/urandom > "${NOISE}"
chmod 600 "${NOISE}"

P12PWFILE="${WORK}/.p12-password"
printf '%s' "${P12_PASSWORD}" > "${P12PWFILE}"
chmod 600 "${P12PWFILE}"

# ---------------------------------------------------------------------------
# NSS database + CA
# Explicit serials matching scripts/cert-init.sh mechanics (Fedora's
# certutil handles -m correctly; auto-serials collide when multiple
# certs are issued within the same instant). The serial base is
# time-derived so each bootstrap run issues globally distinct
# serials: reusing fixed serials across force-mode regenerations
# makes NSS reject the new CA with SEC_ERROR_REUSED_ISSUER_AND_SERIAL
# on any component still holding the previous certificate.
# ---------------------------------------------------------------------------
SERIAL_BASE="$(date +%s)"
log "Creating scratch NSS database (serial base ${SERIAL_BASE})"
certutil -N -d "sql:${NSSDIR}" -f "${PWFILE}"

log "Generating CA (sigul-ca, RSA 2048, ${CA_VALIDITY_MONTHS} months)"
certutil -S -d "sql:${NSSDIR}" -f "${PWFILE}" -z "${NOISE}" \
    -n sigul-ca -s "CN=Sigul CA ${INTERNAL_FQDN}" \
    -x -t "CT,C,C" -g 2048 -Z SHA256 -v "${CA_VALIDITY_MONTHS}" \
    -m "${SERIAL_BASE}" \
    --keyUsage certSigning,crlSigning -2 <<'EOF'
y
-1
n
EOF

# ---------------------------------------------------------------------------
# Leaf certificates. The bridge cert carries every name a peer may
# dial: the external FQDN (CI clients), the in-cluster service FQDN
# (server + toolbox), and the short service name.
# ---------------------------------------------------------------------------
issue_leaf() {
    # $1 nickname, $2 CN, $3 SAN list (comma-separated), $4 serial
    log "Issuing ${1} (CN=${2}; SAN=${3}; serial=${4})"
    certutil -S -d "sql:${NSSDIR}" -f "${PWFILE}" -z "${NOISE}" \
        -n "${1}" -s "CN=${2}" -c sigul-ca \
        -t "u,u,u" -g 2048 -Z SHA256 -v "${CERT_VALIDITY_MONTHS}" \
        -m "${4}" \
        --keyUsage digitalSignature,keyEncipherment \
        --extKeyUsage serverAuth,clientAuth \
        -8 "${3}"
}

issue_leaf sigul-bridge-cert "${EXTERNAL_FQDN}" \
    "${EXTERNAL_FQDN},${INTERNAL_FQDN},${BRIDGE_SERVICE_NAME}" "$((SERIAL_BASE + 1))"
issue_leaf sigul-server-cert "sigul-server.${INTERNAL_FQDN}" \
    "sigul-server.${INTERNAL_FQDN}" "$((SERIAL_BASE + 2))"
issue_leaf sigul-client-cert "sigul-client.${EXTERNAL_FQDN}" \
    "sigul-client.${EXTERNAL_FQDN}" "$((SERIAL_BASE + 3))"

# ---------------------------------------------------------------------------
# Exports: public certs as PEM, leaf keypairs as PKCS#12.
# The CA private key is exported to NO artifact - it exists only in
# this Job's scratch NSS DB and dies with the pod (leaf re-issue means
# re-running with PKI_MODE=force, or a future dedicated re-issue mode;
# see EVALUATION.md 4.2 Option B discussion).
# ---------------------------------------------------------------------------
log "Exporting public certificates"
certutil -L -d "sql:${NSSDIR}" -n sigul-ca -a > "${OUT}/ca.crt"
certutil -L -d "sql:${NSSDIR}" -n sigul-bridge-cert -a > "${OUT}/bridge.crt"

log "Exporting PKCS#12 bundles"
for role in bridge server client; do
    pk12util -o "${OUT}/${role}.p12" -n "sigul-${role}-cert" \
        -d "sql:${NSSDIR}" -k "${PWFILE}" -w "${P12PWFILE}"
    chmod 600 "${OUT}/${role}.p12"
done

# ---------------------------------------------------------------------------
# Publish as Kubernetes Secrets
#
# From here the material becomes consumable: under plain Helm the
# workloads exist alongside this Job (it is an Argo hook, not a Helm
# one), so a pod may start on what is published below before this run
# completes. Record the obligation for a RECOVERY run before the first
# write - this run's own decision (RESTART_AFTER_RUN) is unchanged,
# since a first install has no consumers of superseded material.
# ---------------------------------------------------------------------------
"${PUBLISH[@]}" apply "${SECRET_MARKER}" --literal "rotation-required=true"

log "Publishing Secrets"
"${PUBLISH[@]}" apply "${SECRET_CA_PUBLIC}" \
    --file "ca.crt=${OUT}/ca.crt" \
    --file "bridge.crt=${OUT}/bridge.crt"

"${PUBLISH[@]}" apply "${SECRET_BRIDGE_P12}" --file "bridge.p12=${OUT}/bridge.p12"
"${PUBLISH[@]}" apply "${SECRET_SERVER_P12}" --file "server.p12=${OUT}/server.p12"
"${PUBLISH[@]}" apply "${SECRET_CLIENT_P12}" --file "client.p12=${OUT}/client.p12"

"${PUBLISH[@]}" apply "${SECRET_PASSWORDS}" \
    --literal "bridge-nss-password=${BRIDGE_NSS_PASSWORD}" \
    --literal "server-nss-password=${SERVER_NSS_PASSWORD}" \
    --literal "client-nss-password=${CLIENT_NSS_PASSWORD}" \
    --literal "p12-password=${P12_PASSWORD}"

# The marker is completed with the restart obligation still SET when
# this run owes one: clearing it here would advertise "nothing to do"
# while the old NSS databases are still running, and a retry after a
# failed rollout would skip the restart permanently. It is cleared
# only once the rollout has actually been triggered (or, on the manual
# path, by the operator).
"${PUBLISH[@]}" apply "${SECRET_MARKER}" \
    --literal "state=complete" \
    --literal "rotation-required=${RESTART_AFTER_RUN}" \
    --literal "bootstrapped-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --literal "mode=${PKI_MODE}" \
    --literal "external-fqdn=${EXTERNAL_FQDN}" \
    --literal "ca-validity-months=${CA_VALIDITY_MONTHS}" \
    --literal "cert-validity-months=${CERT_VALIDITY_MONTHS}"

# Scrub scratch material now rather than waiting for the EXIT trap,
# so the CA private key stops existing as early as possible - the
# coordinated-restart logic below can run for a while.
scrub_scratch

# A rotation replaced a trust domain that components may already hold,
# but both workloads rebuild their NSS databases from Secrets only at
# pod start (initContainer into emptyDir), so every component must be
# restarted or the old PKI stays live (a partial restart creates a
# split trust domain). Keyed on RESTART_AFTER_RUN rather than
# PKI_MODE: an interrupted rotation recovered under auto owes the same
# restart.
# Automated restarts are opt-in (pki.forceRestartWorkloads grants the
# required workload-patch RBAC); the default is a manual, operator-
# driven rollout using the operator's own identity.
if [ "${RESTART_AFTER_RUN}" = "true" ]; then
    perform_rotation_restart
fi

log "PKI bootstrap complete"
