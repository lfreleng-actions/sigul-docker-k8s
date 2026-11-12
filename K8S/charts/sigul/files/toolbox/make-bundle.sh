#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Build a Sigul CI client bundle from the chart's published Secrets.
#
# Reads the client's certificate, the CA and bridge certificates and
# the P12 password, builds the client's NSS database the way
# files/scripts/nss-init.sh does, renders client.conf from
# files/conf/client.conf.template, and packs the database as a
# GPG-encrypted tar.xz: the layout lfreleng-actions/sigul-sign-action
# and global-jjb's sigul-pki managed file consume. Everything holding
# the client's private key stays under --out, under umask 077.
#
# Usage:
#   bash make-bundle.sh --release <release> --namespace <ns> \
#       --client <name> --bridge <fqdn> --out <dir> [options]
#
# Run it from a workstation with kubectl access to the namespace, or
# from the admin toolbox (bash /scripts/make-bundle.sh) with
# --secrets-dir, since the toolbox has no kubectl. --help lists every
# option.

set -euo pipefail
umask 077

PROG="make-bundle.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: ${PROG} --release <release> --namespace <ns> --client <name>
       --bridge <fqdn> --out <dir> [options]

Required:
  --release <release>       chart fullname prefixing the Secrets
                            (<release>-ca-public, <release>-passwords)
  --namespace <ns>          namespace holding the release
  --client <name>           Sigul user the bundle authenticates as
  --bridge <fqdn>           bridge-hostname the client dials
  --out <dir>               output directory, created if absent

Options:
  --server-hostname <name>  server-hostname; must equal the server
                            certificate CN (default:
                            sigul-server.<release>-bridge.<ns>.svc.cluster.local)
  --bridge-port <port>      bridge client port (default: 44334)
  --nss-dir <path>          absolute nss-dir on the consumer; the
                            archive's top directory is its last
                            component (default: /home/jenkins/sigul)
  --key-passphrase-file <f> file whose first line is the passphrase
                            encrypting the bundle (default: prompt)
  --format files|action     files: client.conf and sigul-pki.asc;
                            action: also sigul-credentials.b64
                            (default: files)
  --context <name>          kubectl context (default: current)
  --secrets-dir <dir>       read client.p12, ca.crt, bridge.crt and
                            p12-password from <dir> instead of the
                            cluster; the certificate's CN must equal
                            --client unless --shared-cert
  --shared-cert             with --secrets-dir: client.p12 is the
                            shared certificate (CN sigul-client.*,
                            serverAuth and clientAuth), which lenient
                            checking lets claim --client
  -h, --help                show this help
EOF
}

die() { printf '%s: ERROR: %s\n' "${PROG}" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "${PROG}" "$*" >&2; }

RELEASE=""
NAMESPACE=""
CLIENT=""
BRIDGE=""
SERVER_HOSTNAME=""
BRIDGE_PORT=44334
NSS_DIR=/home/jenkins/sigul
PASSPHRASE_FILE=""
OUT=""
FORMAT=files
CONTEXT=""
SECRETS_DIR=""
SHARED_CERT=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --shared-cert) SHARED_CERT=true; shift ;;
        --release|--namespace|--client|--bridge|--server-hostname|\
        --bridge-port|--nss-dir|--key-passphrase-file|--out|--format|\
        --context|--secrets-dir)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            case "$1" in
                --release) RELEASE="$2" ;;
                --namespace) NAMESPACE="$2" ;;
                --client) CLIENT="$2" ;;
                --bridge) BRIDGE="$2" ;;
                --server-hostname) SERVER_HOSTNAME="$2" ;;
                --bridge-port) BRIDGE_PORT="$2" ;;
                --nss-dir) NSS_DIR="$2" ;;
                --key-passphrase-file) PASSPHRASE_FILE="$2" ;;
                --out) OUT="$2" ;;
                --format) FORMAT="$2" ;;
                --context) CONTEXT="$2" ;;
                --secrets-dir) SECRETS_DIR="$2" ;;
            esac
            shift 2
            ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

### Inputs ###########################################################

for required in RELEASE NAMESPACE CLIENT BRIDGE OUT; do
    [ -n "${!required}" ] || {
        usage >&2
        die "--$(tr '[:upper:]' '[:lower:]' <<< "${required}") is required"
    }
done

# Values that end up in sed replacements and client.conf: refuse
# anything that could break the rendering or the file format. --client
# takes server.adminUser's grammar, which the shared certificate
# serves; only a pki.clients name (DNS-1123, see per_client_re) can
# have a Secret of its own.
hostname_re='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
per_client_re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'
[[ "${CLIENT}" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]{0,63}$ ]] \
    || die "--client '${CLIENT}' is not a Sigul user name"
[[ "${BRIDGE}" =~ ${hostname_re} ]] || die "--bridge '${BRIDGE}' is not a hostname"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-sigul-server.${RELEASE}-bridge.${NAMESPACE}.svc.cluster.local}"
[[ "${SERVER_HOSTNAME}" =~ ${hostname_re} ]] \
    || die "--server-hostname '${SERVER_HOSTNAME}' is not a hostname"
if ! [[ "${BRIDGE_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] || [ "${BRIDGE_PORT}" -gt 65535 ]; then
    die "--bridge-port '${BRIDGE_PORT}' is not a port"
fi
[[ "${NSS_DIR}" =~ ^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$ ]] \
    || die "--nss-dir '${NSS_DIR}' must be an absolute path of [A-Za-z0-9._/-]"
NSS_BASE="${NSS_DIR##*/}"
case "${NSS_BASE}" in .|..) die "--nss-dir '${NSS_DIR}' must name a directory" ;; esac
case "${FORMAT}" in files|action) ;; *) die "--format must be files or action" ;; esac
if ${SHARED_CERT} && [ -z "${SECRETS_DIR}" ]; then
    die "--shared-cert needs --secrets-dir; from the cluster the Secret names the certificate"
fi

TEMPLATE=""
for candidate in "${SCRIPT_DIR}/../conf/client.conf.template" \
        /conf-templates/client.conf.template; do
    if [ -f "${candidate}" ]; then TEMPLATE="${candidate}"; break; fi
done
[ -n "${TEMPLATE}" ] || die "client.conf.template not found beside the chart or in /conf-templates"

tools=(certutil pk12util gpg tar xz base64 cmp)
[ -n "${SECRETS_DIR}" ] || tools+=(kubectl)
[ "${FORMAT}" = files ] || tools+=(jq)
for tool in "${tools[@]}"; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} not found in PATH"
done

OUTPUTS=(client.conf sigul-pki.asc)
[ "${FORMAT}" = files ] || OUTPUTS+=(sigul-credentials.b64)
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
for output in "${OUTPUTS[@]}"; do
    [ ! -e "${OUT}/${output}" ] || die "${OUT}/${output} already exists; refusing to overwrite"
done

WORK="$(mktemp -d "${OUT}/.make-bundle.XXXXXX")"
GNUPG_HOME="$(mktemp -d "${TMPDIR:-/tmp}/make-bundle-gnupg.XXXXXX")"
cleanup() {
    gpgconf --homedir "${GNUPG_HOME}" --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf "${WORK}" "${GNUPG_HOME}"
}
trap cleanup EXIT

### Key passphrase ###################################################

# Only the first line counts: gpg --passphrase-file and the consumers
# read no further.
PASSFILE="${WORK}/passphrase"
if [ -n "${PASSPHRASE_FILE}" ]; then
    [ -r "${PASSPHRASE_FILE}" ] || die "cannot read --key-passphrase-file ${PASSPHRASE_FILE}"
    passphrase=""
    IFS= read -r passphrase < "${PASSPHRASE_FILE}" || true
elif [ -t 0 ]; then
    IFS= read -rs -p "Key passphrase: " passphrase; echo >&2
    IFS= read -rs -p "Key passphrase (again): " again; echo >&2
    [ "${passphrase}" = "${again}" ] || die "the passphrases differ"
    unset again
else
    die "no --key-passphrase-file and no terminal to prompt on"
fi
# A file saved with CRLF endings would otherwise carry a carriage
# return into the encryption key and the action's JSON password.
passphrase="${passphrase%$'\r'}"
[[ "${passphrase}" != *$'\r'* ]] || die "the key passphrase holds a carriage return"
[ -n "${passphrase}" ] || die "the key passphrase is empty"
printf '%s\n' "${passphrase}" > "${PASSFILE}"
unset passphrase

### Secrets ##########################################################

kube() {
    local args=(-n "${NAMESPACE}")
    [ -z "${CONTEXT}" ] || args=(--context "${CONTEXT}" "${args[@]}")
    kubectl "${args[@]}" "$@"
}

# fetch SECRET KEY DEST: one Secret key, decoded, refusing an empty
# value (a Secret the chart pre-created that the PKI bootstrap Job has
# not populated yet).
fetch() {
    local secret="$1" key="$2" dest="$3" encoded
    if [ -n "${SECRETS_DIR}" ]; then
        [ -s "${SECRETS_DIR}/${key}" ] || die "${SECRETS_DIR}/${key} is missing or empty"
        cat "${SECRETS_DIR}/${key}" > "${dest}"
        return
    fi
    encoded="$(kube get secret "${secret}" -o "jsonpath={.data.${key//./\\.}}")" \
        || die "cannot read Secret ${secret}"
    [ -n "${encoded}" ] \
        || die "Secret ${secret} has no ${key}: has the PKI bootstrap Job populated it?"
    printf '%s' "${encoded}" | base64 -d > "${dest}" \
        || die "Secret ${secret} key ${key} is not valid base64"
}

# With pki.clients the client has a Secret of its own and strict
# username checking binds it to its CN; otherwise every client shares
# one certificate and the server's lenient check lets it claim any
# user. From files, --shared-cert says which one client.p12 is.
STRICT=true
CLIENT_SECRET="${RELEASE}-client-${CLIENT}-p12"
if [ -n "${SECRETS_DIR}" ]; then
    ! ${SHARED_CERT} || STRICT=false
else
    found=""
    if [ "${#CLIENT}" -le 63 ] && [[ "${CLIENT}" =~ ${per_client_re} ]]; then
        found="$(kube get secret "${CLIENT_SECRET}" --ignore-not-found -o name)" \
            || die "cannot query Secret ${CLIENT_SECRET}"
    fi
    if [ -z "${found}" ]; then
        CLIENT_SECRET="${RELEASE}-client-p12"
        STRICT=false
        log "no ${RELEASE}-client-${CLIENT}-p12; using the shared ${CLIENT_SECRET}"
    fi
fi
log "reading ${CLIENT_SECRET}, ${RELEASE}-ca-public and ${RELEASE}-passwords"
fetch "${CLIENT_SECRET}" client.p12 "${WORK}/client.p12"
fetch "${RELEASE}-ca-public" ca.crt "${WORK}/ca.crt"
fetch "${RELEASE}-ca-public" bridge.crt "${WORK}/bridge.crt"
fetch "${RELEASE}-passwords" p12-password "${WORK}/p12.pw"

### NSS database (as files/scripts/nss-init.sh) #######################

NSS_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '=+/\n')"
printf '%s' "${NSS_PASSWORD}" > "${WORK}/nss.pw"
STAGE="${WORK}/stage"
NSS="${STAGE}/${NSS_BASE}"
mkdir -p "${NSS}"

log "building the NSS database"
certutil -N -d "sql:${NSS}" -f "${WORK}/nss.pw" \
    || die "certutil -N failed"
certutil -A -d "sql:${NSS}" -f "${WORK}/nss.pw" \
    -n sigul-ca -t "CT,C,C" -a -i "${WORK}/ca.crt" \
    || die "importing the CA certificate failed"
certutil -A -d "sql:${NSS}" -f "${WORK}/nss.pw" \
    -n sigul-bridge-cert -t "P,P,P" -a -i "${WORK}/bridge.crt" \
    || die "importing the bridge certificate failed"
pk12util -i "${WORK}/client.p12" -d "sql:${NSS}" \
    -k "${WORK}/nss.pw" -w "${WORK}/p12.pw" >/dev/null \
    || die "importing the client PKCS#12 failed"
rm -f "${WORK}/client.p12" "${WORK}/p12.pw"

### Checks on the database ###########################################

# certutil -L prints "<nickname> <trust>"; nicknames may hold spaces.
listing="$(certutil -L -d "sql:${NSS}")" || die "check: certutil -L failed"
trust_of() {
    awk -v nick="$1" 'NF >= 2 {
        t = $NF; n = $0; sub(/[ \t]+[^ \t]+[ \t]*$/, "", n)
        if (n == nick) print t
    }' <<< "${listing}"
}
for pair in sigul-ca=CT,C,C sigul-bridge-cert=P,P,P sigul-client-cert=u,u,u; do
    nick="${pair%%=*}"
    want="${pair#*=}"
    got="$(trust_of "${nick}")"
    [ "${got}" = "${want}" ] \
        || die "check: ${nick} has trust '${got:-<absent>}', expected ${want}"
done
if certutil -K -d "sql:${NSS}" -f "${WORK}/nss.pw" 2>/dev/null | grep -q sigul-ca; then
    die "check: the CA private key is in the client NSS database"
fi

client_cert="$(certutil -L -d "sql:${NSS}" -n sigul-client-cert)" \
    || die "check: certutil -L -n sigul-client-cert failed"
subject="$(sed -n 's/^[[:space:]]*Subject: "\(.*\)"[[:space:]]*$/\1/p' \
    <<< "${client_cert}" | head -1)"
CN="$(sed -n 's/^\(.*,\)\{0,1\}CN=\([^,]*\).*$/\2/p' <<< "${subject}")"
[ -n "${CN}" ] || die "check: no CN in the client certificate subject '${subject}'"
# pki-bootstrap.sh issues the shared certificate as
# sigul-client.<externalFQDN> with serverAuth and clientAuth, and each
# pki.clients certificate with clientAuth alone. A client may be named
# sigul-client.<anything>, so the CN prefix alone cannot tell them
# apart; the serverAuth extended key usage can.
shared_issued=false
if [[ "${CN}" == sigul-client.* ]] && awk '
        /Name: Extended Key Usage/ { eku = 1; next }
        eku && /^[[:space:]]*$/ { eku = 0 }
        eku && /TLS Web Server Authentication/ { found = 1 }
        END { exit !found }' <<< "${client_cert}"; then
    shared_issued=true
fi
if ${STRICT}; then
    if [ "${CN}" != "${CLIENT}" ]; then
        hint=""
        if [ -n "${SECRETS_DIR}" ] && ${shared_issued}; then
            hint="; pass --shared-cert if it is the shared certificate"
        fi
        die "check: the client certificate CN is '${CN}', not --client '${CLIENT}'${hint}"
    fi
elif ${SHARED_CERT} && ! ${shared_issued}; then
    # Any other certificate is a per-client one, which strict checking
    # binds to its own user.
    die "check: the client certificate (CN '${CN}') is not the shared certificate, a sigul-client.* CN with serverAuth"
else
    log "shared certificate (CN=${CN}): user-name ${CLIENT} relies on lenient username checking"
fi

### client.conf ######################################################

log "rendering client.conf"
# The substitutions go through a 0600 script file, not -e, so the NSS
# password never shows in sed's argv and the process list.
cat > "${WORK}/render.sed" <<EOF
/./,\$!d
s|\${NSS_PASSWORD}|${NSS_PASSWORD}|g
s|\${BRIDGE_HOSTNAME}|${BRIDGE}|g
s|\${CLIENT_PORT}|${BRIDGE_PORT}|g
s|\${SERVER_HOSTNAME}|${SERVER_HOSTNAME}|g
s|\${CLIENT_CERT_NICKNAME}|sigul-client-cert|g
s|\${SIGUL_USER_NAME}|${CLIENT}|g
s|^nss-dir:.*|nss-dir: ${NSS_DIR}|
EOF
grep -v '^#' "${TEMPLATE}" | sed -f "${WORK}/render.sed" > "${WORK}/client.conf"
if grep -qF "\${" "${WORK}/client.conf"; then
    die "client.conf.template has a variable this script does not set"
fi

### Bundle ###########################################################

log "packing and encrypting ${NSS_BASE}/"
tar -C "${STAGE}" -cJf "${WORK}/bundle.tar.xz" -- "${NSS_BASE}" \
    || die "tar failed"
gpg_batch() {
    gpg --homedir "${GNUPG_HOME}" --batch --quiet --yes --no-symkey-cache \
        --pinentry-mode loopback --passphrase-file "${PASSFILE}" "$@"
}
gpg_batch --symmetric --cipher-algo AES256 --armor \
    -o "${WORK}/sigul-pki.asc" "${WORK}/bundle.tar.xz" \
    || die "gpg --symmetric failed"

# Round trip: what a consumer decrypts must be the database just built.
mkdir "${WORK}/verify"
gpg_batch -d -o "${WORK}/verify.tar.xz" "${WORK}/sigul-pki.asc" 2>/dev/null \
    || die "check: the bundle does not decrypt with the key passphrase"
tar -C "${WORK}/verify" -xJf "${WORK}/verify.tar.xz" \
    || die "check: the decrypted bundle does not unpack"
[ "$(cd "${STAGE}" && find . | LC_ALL=C sort)" = "$(cd "${WORK}/verify" && find . | LC_ALL=C sort)" ] \
    || die "check: the unpacked bundle lists different files"
while IFS= read -r -d '' file; do
    cmp -s "${STAGE}/${file}" "${WORK}/verify/${file}" \
        || die "check: ${file} differs after the round trip"
done < <(cd "${STAGE}" && find . -type f -print0)

if [ "${FORMAT}" = action ]; then
    # The SIGUL_CREDENTIALS document sigul-sign-action's live-signing
    # workflow takes: compact JSON, then base64 as one line.
    base64 < "${WORK}/client.conf" | tr -d '\n' > "${WORK}/config.b64"
    base64 < "${WORK}/sigul-pki.asc" | tr -d '\n' > "${WORK}/pki.b64"
    jq -cn \
        --rawfile config "${WORK}/config.b64" \
        --rawfile password "${PASSFILE}" \
        --rawfile pki "${WORK}/pki.b64" \
        '{version: 1, config: $config,
          password: ($password | split("\n")[0]), pki: $pki}' \
        | tr -d '\n' | base64 | tr -d '\n' > "${WORK}/sigul-credentials.b64" \
        || die "assembling sigul-credentials.b64 failed"
    printf '\n' >> "${WORK}/sigul-credentials.b64"
fi

# Publish with ln, which creates each name exclusively and atomically
# (WORK sits under OUT, so on the same filesystem): a concurrent run or
# a file created since the check above makes this run fail and take
# back what it published, never overwrite or mix outputs. Every run
# publishes client.conf first, so one run alone can win.
published=()
for output in "${OUTPUTS[@]}"; do
    if ! ln "${WORK}/${output}" "${OUT}/${output}" 2>/dev/null; then
        for done_output in ${published[@]+"${published[@]}"}; do
            rm -f "${OUT}/${done_output}"
        done
        die "cannot create ${OUT}/${output}: it exists (another run?) or ${OUT} is not writable"
    fi
    published+=("${output}")
done

cat >&2 <<EOF

${PROG}: bundle for '${CLIENT}' written to ${OUT}:
  client.conf            sigul-conf (holds the NSS password)
  sigul-pki.asc          sigul-pki, encrypted with the key passphrase
EOF
if [ "${FORMAT}" = action ]; then
    cat >&2 <<EOF
  sigul-credentials.b64  SIGUL_CREDENTIALS for sigul-sign-action
                         (holds the key passphrase in clear)
EOF
fi
cat >&2 <<EOF

The consumer unpacks sigul-pki.asc in $(dirname "${NSS_DIR}") so the
database lands in ${NSS_DIR}, which client.conf names.
These files carry the client's private key and its passwords: store
each in the consumer's secret store, then delete ${OUT}.
EOF
printf 'NSS password (also in client.conf): %s\n' "${NSS_PASSWORD}"
