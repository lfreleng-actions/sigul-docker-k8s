#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

set -euo pipefail

# Configuration constants
readonly SIGUL_PASS_FILE="/etc/sigul/sigul-pass"
readonly MOCK_MODE="${SIGUL_MOCK_MODE:-false}"

# Utility functions
error() {
    echo "ERROR: $1" >&2
    exit 1
}

log() {
    echo "$1" >&2
}

# Validation functions
validate_required_params() {
    [[ -n "${SIGN_TYPE:-}" ]] || error "SIGN_TYPE is required"
    [[ -n "${SIGN_OBJECT:-}" ]] || error "SIGN_OBJECT is required"

    case "${SIGN_TYPE}" in
        "sign-data"|"sign-git-tag") ;;
        *) error "Invalid SIGN_TYPE: ${SIGN_TYPE}. Must be 'sign-data' or 'sign-git-tag'" ;;
    esac
}

validate_real_mode_params() {
    [[ -n "${SIGUL_CONF:-}" ]] || error "SIGUL_CONF is required for real signing"
    [[ -n "${SIGUL_PASS:-}" ]] || error "SIGUL_PASS is required for real signing"
    [[ -n "${SIGUL_PKI:-}" ]] || error "SIGUL_PKI is required for real signing"
    [[ -n "${SIGUL_KEY_NAME:-}" ]] || error "SIGUL_KEY_NAME is required for real signing"
}

# Mock implementation functions
output_mock_signature() {
    local filename="$1"
    local sign_type="$2"
    local key_name="${SIGUL_KEY_NAME:-mock-test-key}"

    cat << EOF
SIGUL_MOCK_SIGNATURE_START
FILE: $filename
TYPE: $sign_type
KEY: $key_name
-----BEGIN PGP SIGNATURE-----
Version: GnuPG v2

iQIcBAABCAAGBQJhMockAAoJEMockTestKey1234567890abcdefghijklmnop
qrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890+/+/////====
=MOCK
-----END PGP SIGNATURE-----
SIGUL_MOCK_SIGNATURE_END
EOF
}

mock_sign_data() {
    log "MOCK MODE: Processing sign-data request"

    while IFS= read -r line && [[ -n "$line" ]]; do
        case "$line" in
            *\**)
                # Handle wildcard patterns
                for file in $line; do
                    [[ -f "$file" ]] || continue
                    log "MOCK: Signing file $file"
                    output_mock_signature "$file" "sign-data"
                done
                ;;
            *)
                if [[ -f "$line" ]]; then
                    log "MOCK: Signing file $line"
                    output_mock_signature "$line" "sign-data"
                else
                    error "File not found: $line"
                fi
                ;;
        esac
    done <<< "${SIGN_OBJECT}"
}

mock_sign_git_tag() {
    log "MOCK MODE: Processing sign-git-tag request for ${SIGN_OBJECT}"
    output_mock_signature "${SIGN_OBJECT}" "sign-git-tag"
    log "MOCK: Git tag ${SIGN_OBJECT} signed successfully"
}

# Real implementation functions
setup_real_environment() {
    log "Setting up real signing environment"

    # Create sigul config directory if needed
    # First try unified structure, then fall back to legacy paths
    local sigul_dir="/var/sigul/config"
    if [[ ! -d "$sigul_dir" || ! -w "$sigul_dir" ]]; then
        sigul_dir="/etc/sigul"
        if [[ ! -d "$sigul_dir" || ! -w "$sigul_dir" ]]; then
            sigul_dir="$HOME/.sigul-config"
            mkdir -p "$sigul_dir"
        fi
        SIGUL_PASS_FILE="$sigul_dir/sigul-pass"
    else
        SIGUL_PASS_FILE="$sigul_dir/sigul-pass"
    fi

    # Write configuration files
    {
        echo "$SIGUL_CONF"
    } > "$sigul_dir/client.conf" || error "Failed to write sigul config"

    {
        echo "$SIGUL_PASS"
    } > "$SIGUL_PASS_FILE" || error "Failed to write sigul password"

    # Setup PKI
    setup_pki

    # Append null terminator to password file
    printf '\0' >> "$SIGUL_PASS_FILE" || error "Failed to append null to password file"
}

setup_pki() {
    # Use unified structure if available, otherwise fall back to HOME
    local work_dir="/var/sigul"
    if [[ ! -d "$work_dir" || ! -w "$work_dir" ]]; then
        work_dir="$HOME"
    fi
    cd "$work_dir" || error "Cannot change to working directory: $work_dir"

    local passfile pkifile
    passfile=$(mktemp -t passfile.XXXXXXXX) || error "Failed to create temp passfile"
    pkifile=$(mktemp -t pkifile.XXXXXXXX) || error "Failed to create temp pkifile"

    # Cleanup function
    cleanup_temp() {
        shred -u "$passfile" "$pkifile" 2>/dev/null || rm -f "$passfile" "$pkifile"
    }
    trap cleanup_temp EXIT

    chmod 600 "$passfile" "$pkifile" || error "Failed to set temp file permissions"

    # Write sensitive data
    echo "$SIGUL_PASS" > "$passfile" || error "Failed to write passphrase"

    if echo "$SIGUL_PKI" | base64 -d > "$pkifile" 2>/dev/null; then
        log "PKI data decoded from base64"
    else
        echo "$SIGUL_PKI" > "$pkifile" || error "Failed to write PKI data"
    fi

    # Decrypt and extract PKI
    gpg --batch --passphrase-fd 3 -o sigul.tar.xz -d "$pkifile" 3< "$passfile" || error "GPG decryption failed"
    tar Jxf sigul.tar.xz || error "Failed to extract PKI archive"

    [[ -d ".sigul" ]] || error "PKI extraction failed - .sigul directory not found"

    rm -f sigul.tar.xz
}

real_sign_data() {
    log "Processing real sign-data request"

    # Check unified structure first, then legacy paths
    local config_file="/var/sigul/config/client.conf"
    if [[ ! -f "$config_file" ]]; then
        config_file="/etc/sigul/client.conf"
        [[ -f "$HOME/.sigul-config/client.conf" ]] && config_file="$HOME/.sigul-config/client.conf"
    fi

    while IFS= read -r line && [[ -n "$line" ]]; do
        case "$line" in
            *\**)
                for file in $line; do
                    [[ -f "$file" ]] || continue
                    log "Signing file $file"
                    sigul --batch -c "$config_file" sign-data -o "$file.asc" "$SIGUL_KEY_NAME" "$file" < "$SIGUL_PASS_FILE" || error "Signing failed for $file"
                    chmod 644 "$file.asc" || error "Failed to set permissions on $file.asc"
                done
                ;;
            *)
                [[ -f "$line" ]] || error "File not found: $line"
                log "Signing file $line"
                sigul --batch -c "$config_file" sign-data -o "$line.asc" "$SIGUL_KEY_NAME" "$line" < "$SIGUL_PASS_FILE" || error "Signing failed for $line"
                chmod 644 "$line.asc" || error "Failed to set permissions on $line.asc"
                ;;
        esac
    done <<< "${SIGN_OBJECT}"
}

real_sign_git_tag() {
    log "Processing real sign-git-tag request for ${SIGN_OBJECT}"

    [[ -n "${GH_USER:-}" ]] || error "GH_USER is required for git tag signing"
    [[ -n "${GH_KEY:-}" ]] || error "GH_KEY is required for git tag signing"
    [[ -n "${GITHUB_REPOSITORY:-}" ]] || error "GITHUB_REPOSITORY is required for git tag signing"

    # Setup git authentication
    local askpass_script
    askpass_script=$(mktemp -t askpass.XXXXXXXX) || error "Failed to create askpass script"
    chmod 700 "$askpass_script" || error "Failed to set askpass script permissions"

    cat > "$askpass_script" << EOF
#!/bin/bash

echo "${GH_KEY}"
EOF

    trap 'rm -f "$askpass_script"' EXIT

    export GIT_ASKPASS="$askpass_script"
    export GIT_USERNAME="$GH_USER"

    # Setup git remote and sign tag
    git remote add github "https://${GH_USER}@github.com/${GITHUB_REPOSITORY}" || error "Failed to add GitHub remote"
    git fetch --tags || error "Failed to fetch tags"

    # Check unified structure first, then legacy paths
    local config_file="/var/sigul/config/client.conf"
    if [[ ! -f "$config_file" ]]; then
        config_file="/etc/sigul/client.conf"
        [[ -f "$HOME/.sigul-config/client.conf" ]] && config_file="$HOME/.sigul-config/client.conf"
    fi

    sigul --batch -c "$config_file" sign-git-tag "$SIGUL_KEY_NAME" "$SIGN_OBJECT" < "$SIGUL_PASS_FILE" || error "Git tag signing failed"
    git push -f github "$SIGN_OBJECT" || error "Failed to push signed tag"
}

# Main execution
main() {
    # Change to workspace if specified, otherwise stay in current directory
    if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
        cd "$GITHUB_WORKSPACE"
    fi
    # Note: Don't change to /var/sigul automatically as it breaks container working directory

    # If no signing operation specified, just run the command
    if [[ -z "${SIGN_TYPE:-}" && -z "${SIGN_OBJECT:-}" ]]; then
        exec "$@"
        return
    fi

    # Validate common parameters
    validate_required_params

    # Execute based on mode
    if [[ "$MOCK_MODE" == "true" ]]; then
        log "Running in MOCK mode"
        case "$SIGN_TYPE" in
            "sign-data") mock_sign_data ;;
            "sign-git-tag") mock_sign_git_tag ;;
        esac
    else
        log "Running in REAL signing mode"
        validate_real_mode_params
        setup_real_environment
        case "$SIGN_TYPE" in
            "sign-data") real_sign_data ;;
            "sign-git-tag") real_sign_git_tag ;;
        esac
    fi

    log "Signing operation completed successfully"
}

main "$@"
