#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Python-NSS-NG installation script
# This script installs python-nss-ng from PyPI or GitHub

set -euo pipefail

ARCH=$(uname -m)
# Normalize architecture names
case "$ARCH" in
    arm64) ARCH="aarch64" ;;
    amd64) ARCH="x86_64" ;;
esac

# Installation source: pypi or github
INSTALL_SOURCE="${INSTALL_SOURCE:-pypi}"
PYTHON_NSS_NG_VERSION="${PYTHON_NSS_NG_VERSION:-}"
PYTHON_NSS_NG_REPO="${PYTHON_NSS_NG_REPO:-https://github.com/ModeSevenIndustrialSolutions/python-nss-ng.git}"

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

# Check if python-nss-ng is already installed
check_existing_installation() {
    if python3 -c "import nss" >/dev/null 2>&1; then
        local version
        version=$(python3 -c "import nss; print(nss.__version__)" 2>/dev/null || echo "unknown")
        log_info "Python-NSS already installed: $version"
        return 0
    fi
    return 1
}

# Install required build dependencies (only needed for GitHub source builds)
install_build_dependencies() {
    log_info "Installing python-nss-ng build dependencies"

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
        log_info "All required build dependencies are already installed"
    fi
}

# Install from PyPI (recommended)
install_from_pypi() {
    log_info "Installing python-nss-ng from PyPI for $ARCH"

    # Ensure pip is available
    if ! command -v pip3 >/dev/null 2>&1; then
        log_error "pip3 not found, installing python3-pip"
        dnf install -y --setopt=install_weak_deps=False python3-pip
    fi

    # Install python-nss-ng
    if [[ -z "$PYTHON_NSS_NG_VERSION" ]]; then
        log_info "Installing latest version of python-nss-ng"
        pip3 install python-nss-ng
    else
        log_info "Installing python-nss-ng version $PYTHON_NSS_NG_VERSION"
        pip3 install "python-nss-ng==${PYTHON_NSS_NG_VERSION}"
    fi

    local installed_version
    installed_version=$(python3 -c "import nss; print(nss.__version__)" 2>/dev/null || echo "unknown")
    log_info "Python-NSS-NG installed successfully from PyPI: version $installed_version"
}

# Install from GitHub source (for development/testing)
install_from_github() {
    log_info "Installing python-nss-ng from GitHub source for $ARCH"

    # Install build dependencies
    install_build_dependencies

    # Ensure pip is available
    if ! command -v pip3 >/dev/null 2>&1; then
        log_error "pip3 not found, installing python3-pip"
        dnf install -y --setopt=install_weak_deps=False python3-pip
    fi

    # Install from git repository
    local git_ref="${PYTHON_NSS_NG_VERSION:-main}"
    log_info "Installing from ${PYTHON_NSS_NG_REPO}@${git_ref}"

    pip3 install "git+${PYTHON_NSS_NG_REPO}@${git_ref}"

    local installed_version
    installed_version=$(python3 -c "import nss; print(nss.__version__)" 2>/dev/null || echo "unknown")
    log_info "Python-NSS-NG installed successfully from GitHub: version $installed_version"
}

# Main installation function
install_python_nss_ng() {
    log_info "Installing python-nss-ng for architecture: $ARCH"
    log_info "Installation source: $INSTALL_SOURCE"
    log_debug "Repository: $PYTHON_NSS_NG_REPO"
    log_debug "Version: ${PYTHON_NSS_NG_VERSION:-latest}"

    # Check if already installed
    if check_existing_installation; then
        log_info "Python-NSS installation already present, skipping"
        return 0
    fi

    # Install based on source
    case "$INSTALL_SOURCE" in
        pypi)
            install_from_pypi
            ;;
        github)
            install_from_github
            ;;
        *)
            log_error "Unknown installation source: $INSTALL_SOURCE"
            log_error "Valid sources: pypi, github"
            return 1
            ;;
    esac
}

# Verify installation
verify_installation() {
    log_info "Verifying python-nss-ng installation"

    # Test import
    if ! python3 -c "import nss" >/dev/null 2>&1; then
        log_error "Python-NSS-NG verification failed: module cannot be imported"
        return 1
    fi

    # Test submodules
    if ! python3 -c "import nss.nss, nss.error, nss.io, nss.ssl" >/dev/null 2>&1; then
        log_error "Python-NSS-NG verification failed: submodules cannot be imported"
        return 1
    fi

    # Test basic functionality
    if ! python3 -c "import nss.nss; nss.nss.nss_init_nodb()" >/dev/null 2>&1; then
        log_error "Python-NSS-NG verification failed: NSS initialization test failed"
        return 1
    fi

    # Display version and details
    local version
    version=$(python3 -c "import nss; print(nss.__version__)" 2>/dev/null || echo "unknown")
    log_info "Python-NSS-NG verification passed: version $version"

    # Display package information if available
    if command -v pip3 >/dev/null 2>&1; then
        log_info "Package details:"
        pip3 show python-nss-ng 2>/dev/null || log_debug "Could not retrieve package details"
    fi

    return 0
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install python-nss-ng from PyPI or GitHub.

OPTIONS:
    -h, --help              Show this help message
    -d, --debug             Enable debug logging
    -v, --verify            Verify installation after install
    -s, --source SOURCE     Installation source (pypi|github) [default: pypi]
    -V, --version VERSION   Specific version to install [default: latest]
    -r, --repo URL          Git repository URL (for github source)

EXAMPLES:
    # Install latest from PyPI (recommended)
    $0 --verify

    # Install specific version from PyPI
    $0 --source pypi --version 0.1.0 --verify

    # Install from GitHub main branch
    $0 --source github --verify

    # Install specific GitHub tag/branch
    $0 --source github --version v0.1.0 --verify

ENVIRONMENT VARIABLES:
    INSTALL_SOURCE              Installation source (pypi|github)
    PYTHON_NSS_NG_VERSION       Version to install
    PYTHON_NSS_NG_REPO          GitHub repository URL
    DEBUG                       Enable debug output (0|1)
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
            -s|--source)
                INSTALL_SOURCE="$2"
                shift 2
                ;;
            -V|--version)
                PYTHON_NSS_NG_VERSION="$2"
                shift 2
                ;;
            -r|--repo)
                PYTHON_NSS_NG_REPO="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    log_info "Starting python-nss-ng installation"
    log_debug "INSTALL_SOURCE=$INSTALL_SOURCE"
    log_debug "PYTHON_NSS_NG_VERSION=${PYTHON_NSS_NG_VERSION:-latest}"
    log_debug "PYTHON_NSS_NG_REPO=$PYTHON_NSS_NG_REPO"

    # Install python-nss-ng
    if ! install_python_nss_ng; then
        log_error "Python-NSS-NG installation failed"
        exit 1
    fi

    # Verify if requested
    if [[ "$verify" == "true" ]]; then
        if ! verify_installation; then
            log_error "Python-NSS-NG verification failed"
            exit 1
        fi
    fi

    log_info "Python-NSS-NG installation completed successfully"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
