#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Simplified sigul installation script
# This script handles architecture-specific sigul installation in a clean, testable way

set -euo pipefail

ARCH=$(uname -m)
# Normalize architecture names (Docker reports arm64, but system may report aarch64)
case "$ARCH" in
    arm64) ARCH="aarch64" ;;
    amd64) ARCH="x86_64" ;;
esac
SIGUL_VERSION="1.4"

# Logging functions
log_info() {
    echo "[INFO] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Check if sigul is already installed
check_existing_installation() {
    if command -v sigul >/dev/null 2>&1; then
        local version
        version=$(sigul --version 2>/dev/null || echo "unknown")
        log_info "Sigul already installed: $version"
        return 0
    fi
    return 1
}

# Build and install sigul from source (universal method for all architectures)
install_from_source() {
    log_info "Building sigul from source for $ARCH"

    local build_dir="/tmp/sigul-build"
    local component="${1:-client}"

    # Clean up any previous build
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"

    # Clone source from official upstream repository
    # For local development: place sigul source in /build-context/sigul
    # For CI/production: always use official upstream from Pagure

    # Check if local source is explicitly provided (not just empty .gitkeep)
    if [[ -d "/build-context/sigul" ]] && [[ -f "/build-context/sigul/configure.ac" ]]; then
        log_info "Using local sigul source from /build-context/sigul (development mode)"
        cp -r /build-context/sigul ./sigul
        log_info "Copied local sigul source"
    else
        # CI/Production: Always use official public Sigul repository
        log_info "Cloning sigul from official upstream repository (Pagure)"

        local sigul_repo="https://pagure.io/sigul.git"
        local sigul_branch="master"

        log_info "Repository: $sigul_repo"
        log_info "Branch: $sigul_branch"

        if ! git clone --depth 1 --branch "$sigul_branch" "$sigul_repo" sigul; then
            log_error "Failed to clone sigul from official upstream repository"
            log_error "Repository: $sigul_repo"
            log_error "Branch: $sigul_branch"
            return 1
        fi

        log_info "Cloned sigul source from official upstream"
    fi

    cd sigul

    # Apply debugging patches if they exist
    if [[ -d "/workspace/patches" ]] || [[ -d "/tmp/patches" ]]; then
        local patch_dir="/workspace/patches"
        if [[ ! -d "$patch_dir" ]]; then
            patch_dir="/tmp/patches"
        fi

        if [[ -d "$patch_dir" ]]; then
            log_info "Applying debugging patches from $patch_dir"
            for patch_file in "$patch_dir"/*.patch; do
                if [[ -f "$patch_file" ]]; then
                    log_info "Applying patch: $(basename "$patch_file")"
                    if patch -p1 < "$patch_file"; then
                        log_info "✓ Patch applied successfully: $(basename "$patch_file")"
                    else
                        log_error "✗ Failed to apply patch: $(basename "$patch_file")"
                        log_error "Continuing anyway - build may fail or lack debugging"
                    fi
                fi
            done
        fi
    else
        log_debug "No patches directory found - building without patches"
    fi

    # Configure and build
    log_info "Configuring sigul build"
    autoreconf -i
    ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var

    log_info "Building sigul (using $(nproc) cores)"
    make -j"$(nproc)"

    log_info "Installing sigul"
    make install

    # Verify installation based on component
    case "$component" in
        client)
            if ! command -v sigul >/dev/null 2>&1; then
                log_error "Sigul client installation failed"
                return 1
            fi
            ;;
        server)
            if ! command -v sigul_server >/dev/null 2>&1; then
                log_error "Sigul server installation failed"
                return 1
            fi
            ;;
        bridge)
            if ! command -v sigul_bridge >/dev/null 2>&1; then
                log_error "Sigul bridge installation failed"
                return 1
            fi
            ;;
    esac

    # Clean up
    cd /tmp
    rm -rf "$build_dir"

    log_info "Sigul $component built and installed successfully"
}



# Main installation function
install_sigul() {
    local component="${1:-client}"

    log_info "Installing sigul $component for architecture: $ARCH"

    # Check if already installed
    if check_existing_installation; then
        log_info "Sigul installation already present, skipping"
        return 0
    fi

    # Use source builds for all architectures for consistency and to avoid UBI 9 RPM dependency issues
    install_from_source "$component"
}

# Verify installation
verify_installation() {
    local component="${1:-client}"

    log_info "Verifying sigul $component installation"

    case "$component" in
        client)
            if ! command -v sigul >/dev/null 2>&1; then
                log_error "Sigul client verification failed: binary not found"
                return 1
            fi

            if ! sigul --version >/dev/null 2>&1; then
                log_error "Sigul client verification failed: --version command failed"
                return 1
            fi

            log_info "Sigul client verification passed"
            ;;
        server)
            if ! command -v sigul_server >/dev/null 2>&1; then
                log_error "Sigul server verification failed: binary not found"
                return 1
            fi
            log_info "Sigul server verification passed"
            ;;
        bridge)
            if ! command -v sigul_bridge >/dev/null 2>&1; then
                log_error "Sigul bridge verification failed: binary not found"
                return 1
            fi
            log_info "Sigul bridge verification passed"
            ;;
    esac

    return 0
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMPONENT]

Install sigul component for the current architecture.

COMPONENT:
    client    Install sigul client (default)
    server    Install sigul server
    bridge    Install sigul bridge

OPTIONS:
    -h, --help     Show this help message
    -d, --debug    Enable debug logging
    -v, --verify   Verify installation after install

Examples:
    $0                    # Install sigul client
    $0 client             # Install sigul client
    $0 server             # Install sigul server
    $0 -v bridge          # Install sigul bridge and verify
EOF
}

# Parse command line arguments
main() {
    local component="client"
    local verify=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -d|--debug)
                export DEBUG=1
                shift
                ;;
            -v|--verify)
                verify=true
                shift
                ;;
            client|server|bridge)
                component="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    log_info "Starting sigul $component installation"
    log_debug "Architecture: $ARCH"
    log_debug "Sigul version: $SIGUL_VERSION"

    # Install sigul
    if ! install_sigul "$component"; then
        log_error "Sigul $component installation failed"
        exit 1
    fi

    # Verify if requested
    if [[ "$verify" == "true" ]]; then
        if ! verify_installation "$component"; then
            log_error "Sigul $component verification failed"
            exit 1
        fi
    fi

    log_info "Sigul $component installation completed successfully"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
