#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Per-pod NSS initialization for the sigul chart (initContainer).
#
# Rebuilds the component's NSS database from Secret-mounted PKI
# material at every pod start, then renders the sigul config file.
# This replaces the compose stack's shared-volume distribution
# (init-server-certs.sh / init-client-certs.sh) with the same
# certutil/pk12util mechanics (EVALUATION.md 4.2).
#
# Environment (set by the pod template):
#   SIGUL_ROLE          bridge | server | client
#   NSS_PASSWORD        this component's NSS DB password
#   P12_PASSWORD        password for the Secret-mounted .p12 bundle
#   BRIDGE_HOSTNAME     (server/client) bridge DNS name to dial
#   BRIDGE_PORT         (server) bridge server-facing port
#   CLIENT_PORT         (bridge/client) client-facing port
#   SERVER_PORT         (bridge) server-facing port
#
# Mounts:
#   /pki-input          Secrets: ca.crt, bridge.crt, <role>.p12
#   /conf-templates     ConfigMap: <role>.conf.template
#   /nss-out            emptyDir shared with the main container
#                       (mounted there as /etc/pki/sigul/<role>)
#   /config-out         emptyDir shared with the main container
#                       (mounted there as /etc/sigul)

set -euo pipefail

log() { printf '[nss-init:%s] %s\n' "${SIGUL_ROLE:-?}" "$*"; }
die() { printf '[nss-init:%s] ERROR: %s\n' "${SIGUL_ROLE:-?}" "$*" >&2; exit 1; }

[ -n "${SIGUL_ROLE:-}" ] || die "SIGUL_ROLE not set"
[ -n "${NSS_PASSWORD:-}" ] || die "NSS_PASSWORD not set"
[ -n "${P12_PASSWORD:-}" ] || die "P12_PASSWORD not set"
[ -f /pki-input/ca.crt ] || die "/pki-input/ca.crt missing (Secret not mounted?)"
[ -f "/pki-input/${SIGUL_ROLE}.p12" ] || die "/pki-input/${SIGUL_ROLE}.p12 missing"

NSSDIR=/nss-out
PWFILE=/tmp/.nss-password
P12PW=/tmp/.p12-password
printf '%s' "${NSS_PASSWORD}" > "${PWFILE}"; chmod 600 "${PWFILE}"
printf '%s' "${P12_PASSWORD}" > "${P12PW}"; chmod 600 "${P12PW}"

log "Creating NSS database"
rm -f "${NSSDIR}"/cert9.db "${NSSDIR}"/key4.db "${NSSDIR}"/pkcs11.txt
certutil -N -d "sql:${NSSDIR}" -f "${PWFILE}"

log "Importing CA certificate (sigul-ca)"
certutil -A -d "sql:${NSSDIR}" -f "${PWFILE}" \
    -n sigul-ca -t "CT,C,C" -a -i /pki-input/ca.crt

if [ "${SIGUL_ROLE}" != "bridge" ] && [ -f /pki-input/bridge.crt ]; then
    log "Importing bridge public certificate"
    certutil -A -d "sql:${NSSDIR}" -f "${PWFILE}" \
        -n sigul-bridge-cert -t "P,P,P" -a -i /pki-input/bridge.crt
fi

log "Importing ${SIGUL_ROLE} keypair (PKCS#12)"
pk12util -i "/pki-input/${SIGUL_ROLE}.p12" \
    -d "sql:${NSSDIR}" -k "${PWFILE}" -w "${P12PW}"

# Verify: own cert present, CA private key ABSENT (defense in depth -
# the bootstrap Job never exports it, but assert anyway, matching
# init-server-certs.sh behavior).
certutil -L -d "sql:${NSSDIR}" -n "sigul-${SIGUL_ROLE}-cert" >/dev/null \
    || die "sigul-${SIGUL_ROLE}-cert not present after import"
if certutil -K -d "sql:${NSSDIR}" -f "${PWFILE}" 2>/dev/null \
        | grep -q "sigul-ca"; then
    die "CA private key found in ${SIGUL_ROLE} NSS DB - refusing to start"
fi

# ---------------------------------------------------------------------------
# Render config (sed, not envsubst - gettext is not in the images).
# Written to a shared emptyDir, mode 0400: contains the NSS password.
# ---------------------------------------------------------------------------
TEMPLATE="/conf-templates/${SIGUL_ROLE}.conf.template"
CONFIG="/config-out/${SIGUL_ROLE}.conf"
if [ -f "${TEMPLATE}" ]; then
    log "Rendering ${CONFIG}"
    sed \
        -e "s|\${NSS_PASSWORD}|${NSS_PASSWORD}|g" \
        -e "s|\${BRIDGE_CERT_NICKNAME}|sigul-bridge-cert|g" \
        -e "s|\${SERVER_CERT_NICKNAME}|sigul-server-cert|g" \
        -e "s|\${CLIENT_CERT_NICKNAME}|sigul-client-cert|g" \
        -e "s|\${BRIDGE_HOSTNAME}|${BRIDGE_HOSTNAME:-}|g" \
        -e "s|\${SERVER_HOSTNAME}|${SERVER_HOSTNAME:-}|g" \
        -e "s|\${SIGUL_USER_NAME}|${SIGUL_USER_NAME:-admin}|g" \
        -e "s|\${LENIENT_USERNAME_CHECK}|${LENIENT_USERNAME_CHECK:-yes}|g" \
        -e "s|\${BRIDGE_PORT}|${BRIDGE_PORT:-44333}|g" \
        -e "s|\${CLIENT_PORT}|${CLIENT_PORT:-44334}|g" \
        -e "s|\${SERVER_PORT}|${SERVER_PORT:-44333}|g" \
        "${TEMPLATE}" > "${CONFIG}"
    chmod 400 "${CONFIG}"
fi

rm -f "${PWFILE}" "${P12PW}"
log "NSS initialization complete"
