#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# NSS Certificate Validation Script for Sigul Infrastructure
#
# This script provides clean, focused NSS certificate validation across all
# Sigul components (bridge, server, client).
#
# Key Design Principles:
# - NSS certificate validation
# - Simple existence checks for required certificates
# - Fast execution for health checks and monitoring
# - Clear pass/fail results without complex diagnostics
#
# Usage:
#   ./validate-nss.sh [component]
#
# Arguments:
#   component - Optional: bridge|server|client|all (default: all)
#
# Exit codes:
#   0 - All validations passed
#   1 - One or more validations failed

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NSS_BASE_DIR="${NSS_DIR:-/etc/pki/sigul}"
SECRETS_DIR="${SECRETS_DIR:-/var/sigul/secrets}"

# Validation counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Logging functions
log() {
    echo -e "${BLUE}[NSS-VALIDATE]${NC} $*"
}

success() {
    echo -e "${GREEN}[NSS-VALIDATE] ✅${NC} $*"
}

error() {
    echo -e "${RED}[NSS-VALIDATE] ❌${NC} $*"
}

# shellcheck disable=SC2317  # Function is used indirectly
warn() {
    echo -e "${YELLOW}[NSS-VALIDATE] ⚠️${NC} $*"
}

# Test result tracking
test_result() {
    local test_name="$1"
    local result="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [[ "$result" == "PASS" ]]; then
        success "$test_name"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        error "$test_name"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

# Get NSS password from secrets
# shellcheck disable=SC2317  # Function is used indirectly
get_nss_password() {
    local password_file="$SECRETS_DIR/nss-password"
    if [[ -f "$password_file" ]]; then
        cat "$password_file"
    else
        echo ""
    fi
}

# Simple NSS database validation
validate_nss_database() {
    local component="$1"
    local nss_dir="$NSS_BASE_DIR/$component"

    log "Validating NSS database for $component"

    # Check if NSS database directory exists
    if [[ ! -d "$nss_dir" ]]; then
        test_result "$component NSS database directory exists" "FAIL"
        return 1
    fi
    test_result "$component NSS database directory exists" "PASS"

    # Check required NSS database files
    local required_files=("cert9.db" "key4.db" "pkcs11.txt")
    local files_ok=true

    for file in "${required_files[@]}"; do
        if [[ -f "$nss_dir/$file" ]]; then
            test_result "$component NSS file exists: $file" "PASS"
        else
            test_result "$component NSS file exists: $file" "FAIL"
            files_ok=false
        fi
    done

    if [[ "$files_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Simple certificate existence check
check_certificate_exists() {
    local component="$1"
    local cert_nickname="$2"
    local nss_dir="$NSS_BASE_DIR/$component"

    if certutil -d "sql:$nss_dir" -L -n "$cert_nickname" >/dev/null 2>&1; then
        test_result "$component certificate exists: $cert_nickname" "PASS"
        return 0
    else
        test_result "$component certificate exists: $cert_nickname" "FAIL"
        return 1
    fi
}

# Validate bridge certificates (simplified)
validate_bridge_simple() {
    log "=== Bridge NSS Validation (Simplified) ==="

    # Validate NSS database
    if ! validate_nss_database "bridge"; then
        return 1
    fi

    # Check required certificates
    local bridge_ok=true

    # CA certificate (required for bridge as CA)
    if ! check_certificate_exists "bridge" "sigul-ca"; then
        bridge_ok=false
    fi

    # Bridge service certificate (required for TLS)
    if ! check_certificate_exists "bridge" "sigul-bridge-cert"; then
        bridge_ok=false
    fi

    if [[ "$bridge_ok" == "true" ]]; then
        success "Bridge NSS validation completed successfully"
        return 0
    else
        error "Bridge NSS validation failed"
        return 1
    fi
}

# Validate server certificates (simplified)
validate_server_simple() {
    log "=== Server NSS Validation (Simplified) ==="

    # Validate NSS database
    if ! validate_nss_database "server"; then
        return 1
    fi

    # Check required certificates
    local server_ok=true

    # CA certificate (required to trust bridge)
    if ! check_certificate_exists "server" "sigul-ca"; then
        server_ok=false
    fi

    # Server service certificate (required for TLS with bridge)
    if ! check_certificate_exists "server" "sigul-server-cert"; then
        server_ok=false
    fi

    if [[ "$server_ok" == "true" ]]; then
        success "Server NSS validation completed successfully"
        return 0
    else
        error "Server NSS validation failed"
        return 1
    fi
}

# Validate client certificates (simplified)
validate_client_simple() {
    log "=== Client NSS Validation (Simplified) ==="

    # Validate NSS database
    if ! validate_nss_database "client"; then
        return 1
    fi

    # Check required certificates
    local client_ok=true

    # CA certificate (required to trust bridge)
    if ! check_certificate_exists "client" "sigul-ca"; then
        client_ok=false
    fi

    # Client certificate (required for client authentication)
    if ! check_certificate_exists "client" "sigul-client-cert"; then
        client_ok=false
    fi

    if [[ "$client_ok" == "true" ]]; then
        success "Client NSS validation completed successfully"
        return 0
    else
        error "Client NSS validation failed"
        return 1
    fi
}

# Print validation summary
print_summary() {
    log "=== NSS Validation Summary ==="
    log "Total tests: $TOTAL_TESTS"
    success "Passed: $PASSED_TESTS"
    if [[ $FAILED_TESTS -gt 0 ]]; then
        error "Failed: $FAILED_TESTS"
    else
        log "Failed: $FAILED_TESTS"
    fi

    if [[ $FAILED_TESTS -eq 0 ]]; then
        success "All NSS validations passed ✅"
    else
        error "NSS validation failures detected ❌"
    fi
}

# Main function
main() {
    local component="${1:-all}"

    log "Starting simplified NSS-only validation for: $component"
    log "NSS base directory: $NSS_BASE_DIR"

    local validation_result=0

    case "$component" in
        "bridge")
            validate_bridge_simple || validation_result=1
            ;;
        "server")
            validate_server_simple || validation_result=1
            ;;
        "client")
            validate_client_simple || validation_result=1
            ;;
        "all")
            validate_bridge_simple || validation_result=1
            validate_server_simple || validation_result=1
            validate_client_simple || validation_result=1
            ;;
        *)
            error "Invalid component: $component"
            error "Valid components: bridge, server, client, all"
            exit 1
            ;;
    esac

    print_summary

    # Exit with appropriate code
    exit $validation_result
}

# Show usage if requested
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    cat << EOF
NSS Certificate Validation for Sigul Infrastructure

This script validates NSS certificate setup with minimal complexity:
- Checks NSS database files exist
- Verifies required certificates exist in NSS databases
- Fast execution suitable for health checks

Usage:
  $0 [component]

Arguments:
  component    Component to validate (bridge|server|client|all)
               Default: all

Examples:
  $0                    # Validate all components
  $0 bridge            # Validate bridge only
  $0 server            # Validate server only
  $0 client            # Validate client only

Exit codes:
  0 - All validations passed
  1 - One or more validations failed

Environment Variables:
  NSS_DIR         Base NSS directory (default: /var/sigul/nss)
  SECRETS_DIR     Secrets directory (default: /var/sigul/secrets)

EOF
    exit 0
fi

# Run main function
main "$@"
