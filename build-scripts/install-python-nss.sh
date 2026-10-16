#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Install python-nss-ng from its hash lock.
#
# The lock, build-scripts/requirements/python-nss-ng.txt, pins the
# version and carries the sha256 of every artefact PyPI publishes for
# it; Dependabot bumps it. pip installs with --require-hashes, so the
# build proceeds only with a wheel whose digest matches.
#
# Wheels only: --only-binary refuses the sdist, whose build would pull
# meson-python and its dependencies into an isolated environment that
# --require-hashes does not reach. python-nss-ng publishes manylinux
# wheels for both image architectures and every CPython the base can
# ship, so a base whose Python has no wheel fails here, visibly,
# rather than building with unverified tooling.

set -euo pipefail

REQUIREMENTS="${PYTHON_NSS_NG_REQUIREMENTS:-/tmp/requirements/python-nss-ng.txt}"

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

# Ensure pip is available
ensure_pip() {
    if ! command -v pip3 >/dev/null 2>&1; then
        log_error "pip3 not found, installing python3-pip"
        dnf install -y --setopt=install_weak_deps=False python3-pip
    fi
}

# Main installation function
install_python_nss_ng() {
    log_info "Installing python-nss-ng for architecture: $(uname -m)"
    log_info "Requirements lock: $REQUIREMENTS"

    # Check if already installed
    if check_existing_installation; then
        log_info "Python-NSS installation already present, skipping"
        return 0
    fi

    if [[ ! -r "$REQUIREMENTS" ]]; then
        log_error "Requirements lock not found: $REQUIREMENTS"
        return 1
    fi

    ensure_pip

    # Exactly what the lock names, every digest verified, wheels only
    pip3 install --require-hashes --only-binary=:all: -r "$REQUIREMENTS"
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

Install python-nss-ng from its hash-locked requirements file.

OPTIONS:
    -h, --help               Show this help message
    -d, --debug              Enable debug logging
    -v, --verify             Verify installation after install
    -r, --requirements FILE  Requirements lock to install from
                             [default: $REQUIREMENTS]

EXAMPLES:
    # Install from the lock copied into the image and verify
    $0 --verify

    # Install from a lock elsewhere
    $0 --requirements build-scripts/requirements/python-nss-ng.txt

ENVIRONMENT VARIABLES:
    PYTHON_NSS_NG_REQUIREMENTS  Requirements lock to install from
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
            -r|--requirements)
                REQUIREMENTS="$2"
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
    log_debug "REQUIREMENTS=$REQUIREMENTS"

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
