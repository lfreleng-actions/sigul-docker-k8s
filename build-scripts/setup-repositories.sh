#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Repository setup script for sigul containers
# This script handles EPEL and sigul repository setup with robust error handling

set -euo pipefail

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

# Detect if running on Fedora
is_fedora() {
    if [[ -f /etc/fedora-release ]]; then
        return 0
    fi
    return 1
}

# Setup EPEL repository with multiple mirror fallback
setup_epel() {
    log_info "Setting up EPEL repository"

    # Skip EPEL setup on Fedora - EPEL is only for RHEL/CentOS
    if is_fedora; then
        log_info "Fedora detected - skipping EPEL setup (not needed on Fedora)"
        return 0
    fi

    # Check if EPEL is already available
    if dnf repolist enabled 2>/dev/null | grep -q epel; then
        log_info "EPEL repository is already enabled"
        return 0
    fi

    # Define EPEL mirrors in order of preference
    local epel_mirrors=(
        "https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
        "https://download.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
        "https://mirror.stream.centos.org/9-stream/CRB/x86_64/os/Packages/epel-release-9-7.el9.noarch.rpm"
        "https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=noarch"
    )

    local success=false
    local max_attempts=3
    local timeout=30

    for mirror in "${epel_mirrors[@]}"; do
        log_info "Attempting to install EPEL from: $mirror"

        for attempt in $(seq 1 $max_attempts); do
            log_debug "Attempt $attempt/$max_attempts for mirror: $mirror"

            if timeout $timeout dnf install -y --nogpgcheck \
                --setopt=timeout=$timeout \
                --setopt=retries=2 \
                --setopt=minrate=1000 \
                "$mirror" 2>/dev/null; then
                log_info "Successfully installed EPEL from: $mirror (attempt $attempt)"
                success=true
                break 2
            else
                log_debug "Failed attempt $attempt for mirror: $mirror"
                if [[ $attempt -lt $max_attempts ]]; then
                    sleep $(( attempt * 2 ))
                fi
            fi
        done

        log_info "All attempts failed for mirror: $mirror, trying next mirror..."
    done

    if [[ "$success" != "true" ]]; then
        log_error "Failed to install EPEL from all mirrors"
        log_info "Available repositories:"
        dnf repolist 2>/dev/null || true
        return 1
    fi

    # Verify EPEL installation
    if ! dnf repolist enabled 2>/dev/null | grep -q epel; then
        log_error "EPEL repository not found after installation"
        log_info "Available repositories:"
        dnf repolist 2>/dev/null || true
        return 1
    fi

    log_info "EPEL repository setup completed successfully"
    return 0
}

# Setup sigul repository
setup_sigul_repo() {
    log_info "Setting up sigul repository"

    # Skip sigul repository setup on Fedora - packages available in main repos
    if is_fedora; then
        log_info "Fedora detected - skipping sigul repository setup (packages in main repos)"
        return 0
    fi

    local repo_file="/etc/yum.repos.d/fedora-infra-sigul.repo"

    # Check if repository already exists
    if [[ -f "$repo_file" ]] && dnf repolist enabled 2>/dev/null | grep -q fedora-infra-sigul; then
        log_info "Sigul repository is already configured"
        return 0
    fi

    # Create sigul repository configuration
    cat > "$repo_file" << 'EOF'
[fedora-infra-sigul]
name=Fedora builder packages for sigul
baseurl=https://kojipkgs.fedoraproject.org/repos-dist/epel9-infra/latest/$basearch/
enabled=1
gpgcheck=0
skip_if_unavailable=True
timeout=30
retries=3
EOF

    # Verify repository is accessible
    if ! timeout 30 dnf repolist enabled 2>/dev/null | grep -q fedora-infra-sigul; then
        log_error "Failed to enable sigul repository"
        log_info "Repository file contents:"
        cat "$repo_file" 2>/dev/null || true
        return 1
    fi

    log_info "Sigul repository setup completed successfully"
    return 0
}

# Clean DNF cache
clean_cache() {
    log_info "Cleaning DNF cache"
    dnf clean all
    log_debug "DNF cache cleaned"
}

# Test repository connectivity
test_repositories() {
    log_info "Testing repository connectivity"

    # Skip repository tests on Fedora
    if is_fedora; then
        log_info "Fedora detected - skipping repository tests (using main repos)"
        return 0
    fi

    # Test EPEL
    if ! timeout 30 dnf makecache --repo=epel 2>/dev/null; then
        log_error "Failed to refresh EPEL repository cache"
        return 1
    fi

    # Test sigul repository
    if ! timeout 30 dnf makecache --repo=fedora-infra-sigul 2>/dev/null; then
        log_error "Failed to refresh sigul repository cache"
        return 1
    fi

    log_info "Repository connectivity test passed"
    return 0
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Setup EPEL and sigul repositories for RPM-based container builds.

OPTIONS:
    -h, --help     Show this help message
    -d, --debug    Enable debug logging
    -t, --test     Test repository connectivity after setup
    --epel-only    Setup only EPEL repository
    --sigul-only   Setup only sigul repository

Examples:
    $0                    # Setup both repositories
    $0 --test             # Setup and test repositories
    $0 --epel-only        # Setup only EPEL
    $0 -d --test          # Setup with debug logging and test
EOF
}

# Main function
main() {
    local test_repos=false
    local epel_only=false
    local sigul_only=false

    # Parse command line arguments
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
            -t|--test)
                test_repos=true
                shift
                ;;
            --epel-only)
                epel_only=true
                shift
                ;;
            --sigul-only)
                sigul_only=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    log_info "Starting repository setup"

    # Setup repositories
    if [[ "$sigul_only" != "true" ]]; then
        if ! setup_epel; then
            log_error "EPEL repository setup failed"
            exit 1
        fi
    fi

    if [[ "$epel_only" != "true" ]]; then
        if ! setup_sigul_repo; then
            log_error "Sigul repository setup failed"
            exit 1
        fi
    fi

    # Clean cache
    clean_cache

    # Test repositories if requested
    if [[ "$test_repos" == "true" ]]; then
        if ! test_repositories; then
            log_error "Repository connectivity test failed"
            exit 1
        fi
    fi

    log_info "Repository setup completed successfully"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
