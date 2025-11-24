#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Volume Validation Script for Sigul Docker Stack
#
# This script validates that Docker volumes are correctly configured
# and contain the expected certificate and configuration files.
#
# Usage:
#   ./scripts/validate-volumes.sh [OPTIONS]
#
# Options:
#   --verbose     Enable verbose output
#   --help        Show this help message

set -euo pipefail

# Script configuration

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VERBOSE=false

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] VALIDATE:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✅ SUCCESS:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERROR:${NC} $*" >&2
}

verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

show_help() {
    cat << EOF
Volume Validation Script for Sigul Docker Stack

This script validates that Docker volumes are correctly configured
and contain the expected certificate and configuration files.

Usage:
  $0 [OPTIONS]

Options:
  --verbose     Enable verbose output
  --help        Show this help message

Examples:
  $0                    # Run validation with default options
  $0 --verbose          # Run validation with verbose output

Exit Codes:
  0 - All validations passed
  1 - One or more validations failed
EOF
}

# Parse command-line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Detect volume name prefix
detect_volume_prefix() {
    local prefix
    # Try to find existing volumes with known suffixes
    if docker volume ls --format "{{.Name}}" | grep -q "sigul-docker_sigul_bridge_nss"; then
        prefix="sigul-docker"
    elif docker volume ls --format "{{.Name}}" | grep -q "sigul-sign-docker_sigul_bridge_nss"; then
        prefix="sigul-sign-docker"
    elif docker volume ls --format "{{.Name}}" | grep -q "sigul_bridge_nss"; then
        prefix=""
    else
        warn "Could not detect volume prefix, using default 'sigul-docker'"
        prefix="sigul-docker"
    fi
    echo "$prefix"
}

# Check if volume exists
check_volume_exists() {
    local volume_name="$1"
    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Validate volume contains expected files
validate_volume_contents() {
    local volume_name="$1"
    local expected_path="$2"
    local expected_files="$3"

    verbose "Validating volume: $volume_name"
    verbose "  Expected mount path: $expected_path"
    verbose "  Expected files: $expected_files"

    # Use a temporary container to inspect volume contents
    local output
    output=$(docker run --rm -v "$volume_name:$expected_path:ro" alpine sh -c "ls -la $expected_path 2>/dev/null || echo 'VOLUME_EMPTY'")

    if echo "$output" | grep -q "VOLUME_EMPTY"; then
        error "Volume $volume_name is empty or inaccessible"
        return 1
    fi

    # Check for expected files
    local all_found=true
    for file in $expected_files; do
        if ! echo "$output" | grep -q "$file"; then
            warn "  Missing expected file: $file"
            all_found=false
        else
            verbose "  ✓ Found: $file"
        fi
    done

    if [[ "$all_found" == "true" ]]; then
        success "Volume $volume_name contains expected files"
        return 0
    else
        error "Volume $volume_name is missing some expected files"
        return 1
    fi
}

# Main validation function
main() {
    parse_args "$@"

    log "=== Sigul Docker Volume Validation ==="
    log "Verbose mode: $VERBOSE"
    echo ""

    local volume_prefix
    volume_prefix=$(detect_volume_prefix)

    if [[ -n "$volume_prefix" ]]; then
        log "Detected volume prefix: $volume_prefix"
    else
        log "Using volumes without prefix"
    fi
    echo ""

    local validation_failed=false

    # Define volumes to validate
    declare -A volumes=(
        ["bridge_nss"]="cert9.db key4.db pkcs11.txt"
        ["bridge_data"]=""  # Application data, no specific files required
        ["server_nss"]="cert9.db key4.db pkcs11.txt"
        ["server_data"]=""  # Application data
        ["shared_config"]=""  # Config files, created by containers
    )

    # Validate each volume
    for volume_type in "${!volumes[@]}"; do
        local volume_name
        if [[ -n "$volume_prefix" ]]; then
            volume_name="${volume_prefix}_sigul_${volume_type}"
        else
            volume_name="sigul_${volume_type}"
        fi

        log "Checking volume: $volume_name (type: $volume_type)"

        if ! check_volume_exists "$volume_name"; then
            warn "Volume does not exist: $volume_name"
            warn "  This is normal if the stack has not been deployed yet"
            continue
        fi

        verbose "Volume exists: $volume_name"

        # Determine expected path based on volume type
        local expected_path
        case "$volume_type" in
            *_nss)
                expected_path="/etc/pki/sigul/${volume_type%_nss}"
                ;;
            *_data)
                expected_path="/var/lib/sigul/${volume_type%_data}"
                ;;
            shared_config)
                expected_path="/etc/sigul"
                ;;
            *)
                expected_path="/unknown"
                ;;
        esac

        # Validate contents if expected files are defined
        local expected_files="${volumes[$volume_type]}"
        if [[ -n "$expected_files" ]]; then
            if ! validate_volume_contents "$volume_name" "$expected_path" "$expected_files"; then
                validation_failed=true
            fi
        else
            verbose "Skipping content validation (no expected files defined)"
            success "Volume exists: $volume_name"
        fi
        echo ""
    done

    # Summary
    log "=== Validation Summary ==="

    if [[ "$validation_failed" == "true" ]]; then
        error "Some volume validations failed"
        error "This may indicate:"
        error "  1. Containers have not been initialized yet"
        error "  2. Certificate initialization failed"
        error "  3. Volume permissions issues"
        echo ""
        error "Troubleshooting steps:"
        error "  1. Run: docker compose -f docker-compose.sigul.yml up cert-init"
        error "  2. Check logs: docker compose -f docker-compose.sigul.yml logs cert-init"
        error "  3. Verify NSS databases: docker exec sigul-bridge certutil -L -d sql:/etc/pki/sigul/bridge"
        return 1
    else
        success "All volume validations passed"
        success "Sigul Docker volumes are properly configured"
        return 0
    fi
}

# Run main function
main "$@"
