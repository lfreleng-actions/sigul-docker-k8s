#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Python-NSS installation script
# This script builds and installs python-nss from the GitHub fork

set -euo pipefail

ARCH=$(uname -m)
# Normalize architecture names
case "$ARCH" in
    arm64) ARCH="aarch64" ;;
    amd64) ARCH="x86_64" ;;
esac

PYTHON_NSS_VERSION="${PYTHON_NSS_VERSION:-master}"
PYTHON_NSS_REPO="${PYTHON_NSS_REPO:-https://github.com/ModeSevenIndustrialSolutions/python-nss.git}"

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

# Check if python-nss is already installed
check_existing_installation() {
    if python3 -c "import nss" >/dev/null 2>&1; then
        local version
        version=$(python3 -c "import nss; print(nss.__version__)" 2>/dev/null || echo "unknown")
        log_info "Python-NSS already installed: $version"
        return 0
    fi
    return 1
}

# Install required build dependencies
install_dependencies() {
    log_info "Installing python-nss build dependencies"
    
    # Check if dependencies are already installed
    local missing_deps=()
    
    for pkg in nss-devel nspr-devel python3-devel gcc; do
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            missing_deps+=("$pkg")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_info "Installing missing dependencies: ${missing_deps[*]}"
        dnf install -y --setopt=install_weak_deps=False "${missing_deps[@]}"
    else
        log_info "All required dependencies are already installed"
    fi
}

# Build and install python-nss from source
install_from_source() {
    log_info "Building python-nss from source for $ARCH"

    local build_dir="/tmp/python-nss-build"

    # Clean up any previous build
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"

    # Clone source from GitHub fork
    log_info "Cloning python-nss from GitHub fork: $PYTHON_NSS_REPO"
    if [[ "$PYTHON_NSS_VERSION" == "master" ]] || [[ "$PYTHON_NSS_VERSION" == "main" ]]; then
        git clone --depth 1 "$PYTHON_NSS_REPO" python-nss
    else
        git clone --depth 1 --branch "$PYTHON_NSS_VERSION" "$PYTHON_NSS_REPO" python-nss
    fi
    
    cd python-nss

    # Build and install
    log_info "Building python-nss (using $(nproc) cores)"
    python3 setup.py build

    log_info "Installing python-nss"
    python3 setup.py install

    # Verify installation
    if ! python3 -c "import nss" >/dev/null 2>&1; then
        log_error "Python-NSS installation verification failed"
        return 1
    fi

    local installed_version
    installed_version=$(python3 -c "import nss; print(nss.__version__)" 2>/dev/null || echo "unknown")
    log_info "Python-NSS installed successfully: version $installed_version"

    # Clean up
    cd /tmp
    rm -rf "$build_dir"

    log_info "Python-NSS build and installation completed"
}

# Main installation function
install_python_nss() {
    log_info "Installing python-nss for architecture: $ARCH"
    log_debug "Repository: $PYTHON_NSS_REPO"
    log_debug "Version/Branch: $PYTHON_NSS_VERSION"

    # Check if already installed
    if check_existing_installation; then
        log_info "Python-NSS installation already present, skipping"
        return 0
    fi

    # Install dependencies
    install_dependencies

    # Build from source
    install_from_source
}

# Verify installation
verify_installation() {
    log_info "Verifying python-nss installation"

    if ! python3 -c "import nss" >/dev/null 2>&1; then
        log_error "Python-NSS verification failed: module cannot be imported"
        return 1
    fi

    # Test basic functionality
    if ! python3 -c "import nss; nss.nss_init_nodb()" >/dev/null 2>&1; then
        log_error "Python-NSS verification failed: NSS initialization test failed"
        return 1
    fi

    local version
    version=$(python3 -c "import nss; print(nss.__version__)" 2>/dev/null || echo "unknown")
    log_info "Python-NSS verification passed: version $version"

    return 0
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Build and install python-nss from GitHub fork.

OPTIONS:
    -h, --help     Show this help message
    -d, --debug    Enable debug logging
    -v, --verify   Verify installation after install
    -r, --repo     Git repository URL (default: $PYTHON_NSS_REPO)
    -b, --branch   Git branch or tag (default: $PYTHON_NSS_VERSION)

Examples:
    $0                           # Install python-nss from default repo/branch
    $0 -v                        # Install and verify
    $0 -b v1.0.1                 # Install specific version
    $0 -r https://github.com/user/python-nss.git -b feature-branch
EOF
}

# Parse command line arguments
main() {
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
            -r|--repo)
                PYTHON_NSS_REPO="$2"
                shift 2
                ;;
            -b|--branch)
                PYTHON_NSS_VERSION="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    log_info "Starting python-nss installation"

    # Install python-nss
    if ! install_python_nss; then
        log_error "Python-NSS installation failed"
        exit 1
    fi

    # Verify if requested
    if [[ "$verify" == "true" ]]; then
        if ! verify_installation; then
            log_error "Python-NSS verification failed"
            exit 1
        fi
    fi

    log_info "Python-NSS installation completed successfully"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi