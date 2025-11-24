#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Python 3.12 installation script using pyenv
# This script installs Python 3.12 to support python-nss-ng wheels
# UBI9 ships with Python 3.9 (EOL), but python-nss-ng wheels require Python 3.10+

set -euo pipefail

PYTHON_VERSION="${PYTHON_VERSION:-3.12.7}"
PYENV_ROOT="${PYENV_ROOT:-/opt/pyenv}"

# Logging functions
log_info() {
    echo "[INFO] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_warning() {
    echo "[WARNING] $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Check if Python 3.12 is already installed
check_existing_python() {
    if command -v python3.12 >/dev/null 2>&1; then
        local version
        version=$(python3.12 --version 2>&1 | awk '{print $2}')
        log_info "Python 3.12 already installed: $version"
        return 0
    fi
    return 1
}

# Install pyenv build dependencies
install_dependencies() {
    log_info "Installing Python build dependencies"
    
    # Essential dependencies that must be present
    local essential_deps=(
        make
        gcc
        git
    )
    
    # Optional dependencies (install if available, but don't fail)
    local optional_deps=(
        gcc-c++
        zlib-devel
        bzip2-devel
        readline-devel
        sqlite-devel
        openssl-devel
        libffi-devel
        xz-devel
        tk-devel
    )
    
    # Check for curl or wget (one is required for pyenv)
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log_info "Neither curl nor wget found, attempting to install curl"
        essential_deps+=(curl)
    fi
    
    # Install essential dependencies (fail if not available)
    local missing_essential=()
    for pkg in "${essential_deps[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1 && ! command -v "${pkg}" >/dev/null 2>&1; then
            missing_essential+=("$pkg")
        fi
    done
    
    if [[ ${#missing_essential[@]} -gt 0 ]]; then
        log_info "Installing essential dependencies: ${missing_essential[*]}"
        if ! dnf install -y --setopt=install_weak_deps=False "${missing_essential[@]}" 2>&1; then
            log_error "Failed to install essential dependencies"
            return 1
        fi
    else
        log_info "All essential dependencies are already installed"
    fi
    
    # Install optional dependencies (warn but don't fail)
    local missing_optional=()
    for pkg in "${optional_deps[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            missing_optional+=("$pkg")
        fi
    done
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log_info "Attempting to install optional dependencies: ${missing_optional[*]}"
        # Try to install all at once, but don't fail
        dnf install -y --setopt=install_weak_deps=False "${missing_optional[@]}" 2>/dev/null || {
            log_warning "Some optional dependencies are not available"
            log_debug "Python will be built with available dependencies"
        }
    else
        log_info "All optional dependencies are already installed"
    fi
    
    log_info "Python build dependencies installation completed"
}

# Install pyenv
install_pyenv() {
    log_info "Installing pyenv to $PYENV_ROOT"
    
    if [[ -d "$PYENV_ROOT" ]]; then
        log_info "pyenv already installed at $PYENV_ROOT"
        return 0
    fi
    
    # Clone pyenv
    git clone --depth 1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
    
    # Set up environment
    export PYENV_ROOT="$PYENV_ROOT"
    export PATH="$PYENV_ROOT/bin:$PATH"
    
    log_info "pyenv installed successfully"
}

# Install Python 3.12 using pyenv
install_python312() {
    log_info "Installing Python $PYTHON_VERSION using pyenv"
    
    # Set up pyenv environment
    export PYENV_ROOT="$PYENV_ROOT"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
    
    # Check if already installed
    if pyenv versions | grep -q "$PYTHON_VERSION"; then
        log_info "Python $PYTHON_VERSION already installed via pyenv"
        pyenv global "$PYTHON_VERSION"
        return 0
    fi
    
    # Install Python (skip ensurepip to avoid build failures)
    log_info "Building Python $PYTHON_VERSION (this may take several minutes)"
    if ! PYTHON_CONFIGURE_OPTS="--without-ensurepip" \
        pyenv install "$PYTHON_VERSION" 2>&1; then
        log_error "Python $PYTHON_VERSION build failed"
        return 1
    fi
    
    # Set as global default
    pyenv global "$PYTHON_VERSION"
    
    # Verify installation
    if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
        log_error "Python $PYTHON_VERSION not found in pyenv versions"
        return 1
    fi
    
    log_info "Python $PYTHON_VERSION installed successfully"
}

# Configure system to use Python 3.12
configure_system() {
    log_info "Configuring system to use Python 3.12"
    
    # Create profile script for pyenv
    cat > /etc/profile.d/pyenv.sh << 'EOF'
export PYENV_ROOT="/opt/pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
    eval "$(pyenv init -)"
fi
EOF
    
    chmod +x /etc/profile.d/pyenv.sh
    
    # Source it for current session
    source /etc/profile.d/pyenv.sh
    
    # Create symlinks for convenience
    local python_bin="$PYENV_ROOT/versions/$PYTHON_VERSION/bin"
    
    # Update alternatives to prefer Python 3.12
    if [[ -f "$python_bin/python3.12" ]]; then
        ln -sf "$python_bin/python3.12" /usr/local/bin/python3.12
        ln -sf "$python_bin/python3.12" /usr/local/bin/python3
        ln -sf "$python_bin/python3.12" /usr/local/bin/python
        
        # pip
        ln -sf "$python_bin/pip3" /usr/local/bin/pip3
        ln -sf "$python_bin/pip3" /usr/local/bin/pip
        
        log_info "Created symlinks for Python 3.12"
    fi
    
    # Install and upgrade pip (since we built without ensurepip)
    log_info "Installing pip for Python 3.12"
    "$python_bin/python3.12" -m ensurepip --default-pip 2>/dev/null || {
        log_warning "ensurepip failed, downloading pip manually"
        if command -v curl >/dev/null 2>&1; then
            curl -sS https://bootstrap.pypa.io/get-pip.py | "$python_bin/python3.12"
        elif command -v wget >/dev/null 2>&1; then
            wget -qO- https://bootstrap.pypa.io/get-pip.py | "$python_bin/python3.12"
        else
            log_error "Cannot install pip: no curl or wget available"
            return 1
        fi
    }
    
    log_info "Upgrading pip"
    "$python_bin/python3.12" -m pip install --upgrade pip setuptools wheel
}

# Verify installation
verify_installation() {
    log_info "Verifying Python 3.12 installation"
    
    # Source pyenv environment
    export PYENV_ROOT="$PYENV_ROOT"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)" 2>/dev/null || true
    
    # Also explicitly set PATH to include Python 3.12
    local python_bin="$PYENV_ROOT/versions/$PYTHON_VERSION/bin"
    export PATH="$python_bin:$PATH"
    
    # Check Python version
    if ! python3 --version 2>&1 | grep -q "3.12"; then
        log_error "Python 3.12 verification failed: incorrect version"
        log_error "Expected: Python 3.12.x"
        log_error "Got: $(python3 --version 2>&1)"
        log_error "PATH: $PATH"
        log_error "Which python3: $(which python3)"
        return 1
    fi
    
    local version
    version=$(python3 --version 2>&1)
    log_info "Python verification passed: $version"
    
    # Check pip
    if ! python3 -m pip --version >/dev/null 2>&1; then
        log_error "pip verification failed"
        return 1
    fi
    
    local pip_version
    pip_version=$(python3 -m pip --version 2>&1)
    log_info "pip verification passed: $pip_version"
    
    # Test basic functionality
    if ! python3 -c "import sys; print(f'Python {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')" >/dev/null 2>&1; then
        log_error "Python 3.12 basic functionality test failed"
        return 1
    fi
    
    log_info "Python 3.12 installation verified successfully"
    return 0
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install Python 3.12 using pyenv for python-nss-ng compatibility.

OPTIONS:
    -h, --help              Show this help message
    -d, --debug             Enable debug logging
    -v, --verify            Verify installation after install
    -V, --version VERSION   Python version to install [default: $PYTHON_VERSION]

EXAMPLES:
    $0 --verify                    # Install Python 3.12.7 and verify
    $0 --version 3.12.8            # Install specific version

NOTES:
    - Python 3.9 (UBI9 default) is EOL as of October 2025
    - python-nss-ng requires Python 3.10+ for wheel compatibility
    - Python 3.12 provides better performance and security
EOF
}

# Main installation function
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
            -V|--version)
                PYTHON_VERSION="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    log_info "Starting Python 3.12 installation"
    log_info "Target Python version: $PYTHON_VERSION"
    log_info "pyenv root: $PYENV_ROOT"
    
    # Check if already installed
    if check_existing_python; then
        log_info "Python 3.12 already available, skipping installation"
        if [[ "$verify" == "true" ]]; then
            verify_installation
        fi
        return 0
    fi
    
    # Install dependencies
    if ! install_dependencies; then
        log_error "Failed to install dependencies"
        exit 1
    fi
    
    # Install pyenv
    if ! install_pyenv; then
        log_error "Failed to install pyenv"
        exit 1
    fi
    
    # Install Python 3.12
    if ! install_python312; then
        log_error "Failed to install Python 3.12"
        exit 1
    fi
    
    # Configure system
    if ! configure_system; then
        log_error "Failed to configure system"
        exit 1
    fi
    
    # Verify if requested
    if [[ "$verify" == "true" ]]; then
        if ! verify_installation; then
            log_error "Python 3.12 verification failed"
            exit 1
        fi
    fi
    
    log_info "Python 3.12 installation completed successfully"
    log_info "To use Python 3.12 in new shells, run: source /etc/profile.d/pyenv.sh"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi