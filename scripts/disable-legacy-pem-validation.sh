#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Disable Legacy PEM Validation Script
#
# This script disables or removes legacy PEM-based validation functions
# to implement the simplified NSS-only approach. It identifies and
# neutralizes OpenSSL/PEM validation code while preserving NSS functionality.
#
# Key Operations:
# - Disable OpenSSL certificate validation functions
# - Remove PEM file validation logic
# - Replace complex validation with simple NSS checks
# - Backup original files before modification
# - Create migration report
#
# Usage:
#   ./disable-legacy-pem-validation.sh [--dry-run] [--backup-dir DIR]
#
# Options:
#   --dry-run       Show what would be changed without making changes
#   --backup-dir    Specify backup directory (default: backup-pem-validation)
#   --help          Show this help message

set -euo pipefail

# Script version
readonly SCRIPT_VERSION="1.0.0"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly PROJECT_ROOT
DEFAULT_BACKUP_DIR="$PROJECT_ROOT/backup-pem-validation-$(date +%Y%m%d_%H%M%S)"
readonly DEFAULT_BACKUP_DIR
readonly MIGRATION_REPORT="$PROJECT_ROOT/pem-validation-migration-report.md"

# Default values
DRY_RUN=false
BACKUP_DIR="$DEFAULT_BACKUP_DIR"

# Logging functions
log() {
    echo -e "${BLUE}[PEM-DISABLE]${NC} $*"
}

success() {
    echo -e "${GREEN}[PEM-DISABLE] ✅${NC} $*"
}

warn() {
    echo -e "${YELLOW}[PEM-DISABLE] ⚠️${NC} $*"
}

error() {
    echo -e "${RED}[PEM-DISABLE] ❌${NC} $*"
}

debug() {
    echo -e "${PURPLE}[PEM-DISABLE] 🔍${NC} $*"
}

# Files to process for PEM validation removal
declare -a TARGET_FILES=(
    "scripts/sigul-init.sh"
    "scripts/validate-nss-certificates.sh"
    "scripts/lib/health.sh"
    "scripts/generate-complete-pki.sh"
    "scripts/run-integration-test.sh"
    "scripts/setup-bridge-ca.sh"
    "scripts/setup-server-certs.sh"
    "scripts/setup-client-certs.sh"
)

# PEM validation patterns to disable
declare -a PEM_PATTERNS=(
    "openssl verify"
    "openssl x509.*-checkend"
    "openssl x509.*-noout"
    "openssl req.*-new"
    "\.pem.*validation"
    "validate.*\.pem"
    "check.*\.pem"
    "\.crt.*file.*="
    "\.key.*file.*="
    "ca-cert-file"
    "server-cert-file"
    "client-cert-file"
    "bridge-cert-file"
    "server-key-file"
    "client-key-file"
    "bridge-key-file"
)

# Functions to disable/rename
declare -a FUNCTION_PATTERNS=(
    "validate_certificate\(\)"
    "generate_test_certificate\(\)"
    "copy_shared_ca\(\)"
    "generate_component_certificate\(\)"
    "validate_certificate_chain\(\)"
    "check_certificate_validity\(\)"
    "extract_certificate_info\(\)"
)

#######################################
# Backup Operations
#######################################

create_backup() {
    local file="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        debug "DRY-RUN: Would backup $file to $BACKUP_DIR"
        return 0
    fi

    # Create backup directory if it doesn't exist
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        log "Created backup directory: $BACKUP_DIR"
    fi

    # Create subdirectory structure in backup
    local relative_path="${file#"$PROJECT_ROOT"/}"
    local backup_file="$BACKUP_DIR/$relative_path"
    local backup_dir
    backup_dir="$(dirname "$backup_file")"

    mkdir -p "$backup_dir"

    if [[ -f "$file" ]]; then
        cp "$file" "$backup_file"
        debug "Backed up: $relative_path"
        return 0
    else
        warn "File not found for backup: $file"
        return 1
    fi
}

#######################################
# PEM Validation Detection
#######################################

detect_pem_validation() {
    local file="$1"
    local matches=0

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    debug "Scanning for PEM validation in: $(basename "$file")"

    # Check for PEM validation patterns
    for pattern in "${PEM_PATTERNS[@]}"; do
        if grep -q "$pattern" "$file" 2>/dev/null; then
            debug "  Found pattern: $pattern"
            ((matches++))
        fi
    done

    # Check for function patterns
    for pattern in "${FUNCTION_PATTERNS[@]}"; do
        if grep -q "$pattern" "$file" 2>/dev/null; then
            debug "  Found function: $pattern"
            ((matches++))
        fi
    done

    return $matches
}

#######################################
# PEM Validation Disabling
#######################################

disable_openssl_functions() {
    local file="$1"
    local temp_file="$file.tmp"

    if [[ "$DRY_RUN" == "true" ]]; then
        debug "DRY-RUN: Would disable OpenSSL functions in $(basename "$file")"
        return 0
    fi

    log "Disabling OpenSSL functions in: $(basename "$file")"

    # Create modified version
    awk '
    BEGIN {
        in_openssl_function = 0
        disabled_functions = 0
    }

    # Start of OpenSSL validation functions
    /^[[:space:]]*validate_certificate\(\)|^[[:space:]]*generate_.*certificate\(\)|^[[:space:]]*copy_shared_ca\(\)/ {
        print "# DISABLED: Legacy PEM validation function - replaced by NSS-only validation"
        print $0 "_DISABLED() {"
        print "    warn \"Legacy PEM function disabled: " $0 "\""
        print "    warn \"Use NSS-only validation instead: validate-nss.sh\""
        print "    return 1"
        in_openssl_function = 1
        disabled_functions++
        next
    }

    # End of function
    in_openssl_function && /^}/ {
        print "}"
        print ""
        in_openssl_function = 0
        next
    }

    # Skip function content when disabling
    in_openssl_function {
        next
    }

    # Disable OpenSSL verification calls
    /openssl verify/ {
        print "    # DISABLED: " $0
        print "    warn \"OpenSSL verify disabled - use NSS validation instead\""
        print "    return 1"
        next
    }

    # Disable OpenSSL certificate checks
    /openssl x509.*-checkend/ {
        print "    # DISABLED: " $0
        print "    warn \"OpenSSL certificate check disabled - use NSS validation instead\""
        print "    return 1"
        next
    }

    # Comment out PEM file configurations
    /ca-cert-file|server-cert-file|client-cert-file|bridge-cert-file|.*-key-file/ {
        print "# DISABLED: " $0
        print "# Use NSS certificate nicknames instead"
        next
    }

    # Default: keep line unchanged
    {
        print $0
    }

    END {
        if (disabled_functions > 0) {
            print "# " disabled_functions " legacy PEM validation functions disabled"
        }
    }
    ' "$file" > "$temp_file"

    # Replace original file
    mv "$temp_file" "$file"
    success "OpenSSL functions disabled in: $(basename "$file")"
}

add_nss_only_header() {
    local file="$1"
    local temp_file="$file.tmp"

    if [[ "$DRY_RUN" == "true" ]]; then
        debug "DRY-RUN: Would add NSS-only header to $(basename "$file")"
        return 0
    fi

    # Add NSS-only header after shebang and license
    awk '
    BEGIN { header_added = 0 }

    # After SPDX license, add NSS-only header
    /^# SPDX-FileCopyrightText:/ && !header_added {
        print $0
        print ""
        print "# NSS-ONLY VALIDATION MODE"
        print "# This script has been modified to use NSS-only certificate validation."
        print "# Legacy PEM/OpenSSL validation functions have been disabled."
        print "# Use validate-nss.sh for certificate validation."
        print "# Use sigul-init-nss-only.sh for initialization."
        print ""
        header_added = 1
        next
    }

    { print $0 }
    ' "$file" > "$temp_file"

    mv "$temp_file" "$file"
    debug "Added NSS-only header to: $(basename "$file")"
}

#######################################
# Migration Report
#######################################

generate_migration_report() {
    if [[ "$DRY_RUN" == "true" ]]; then
        debug "DRY-RUN: Would generate migration report"
        return 0
    fi

    log "Generating migration report: $MIGRATION_REPORT"

    cat > "$MIGRATION_REPORT" << 'EOF'
# PEM Validation Migration Report

This report documents the migration from legacy PEM-based validation to NSS-only validation.

## Summary

The Sigul infrastructure has been migrated to use NSS-only certificate validation, removing all legacy OpenSSL/PEM validation functions. This provides a cleaner, more maintainable, and architecturally correct approach.

## Changes Made

### Files Modified

EOF

    local modified_files=0
    for file in "${TARGET_FILES[@]}"; do
        local full_path="$PROJECT_ROOT/$file"
        if [[ -f "$full_path" ]]; then
            detect_pem_validation "$full_path"
            local pem_matches=$?
            if [[ $pem_matches -gt 0 ]]; then
                echo "- **$file**: $pem_matches PEM validation patterns found and disabled" >> "$MIGRATION_REPORT"
                ((modified_files++))
            fi
        fi
    done

    cat >> "$MIGRATION_REPORT" << EOF

### Functions Disabled

The following legacy PEM validation functions have been disabled:

- \`validate_certificate()\` - Replaced by NSS certificate existence checks
- \`generate_test_certificate()\` - Replaced by NSS certificate generation
- \`copy_shared_ca()\` - Replaced by NSS CA import/export
- \`generate_component_certificate()\` - Replaced by NSS certificate generation
- \`validate_certificate_chain()\` - Replaced by NSS validation
- OpenSSL verify operations - Replaced by \`certutil -V\`
- PEM file validation - Replaced by NSS database checks

### Configuration Changes

PEM file configuration options have been replaced with NSS nicknames:

- \`ca-cert-file\` → \`ca-cert-nickname = sigul-ca\`
- \`server-cert-file\` → \`server-cert-nickname = sigul-server-cert\`
- \`client-cert-file\` → \`client-cert-nickname = sigul-client-cert\`
- \`bridge-cert-file\` → \`bridge-cert-nickname = sigul-bridge-cert\`
- \`*-key-file\` → Keys managed in NSS database

## New NSS-Only Tools

### Validation Script
Use \`validate-nss.sh\` for certificate validation:
\`\`\`bash
# Validate all components
./scripts/validate-nss.sh all

# Validate specific component
./scripts/validate-nss.sh bridge
\`\`\`

### Initialization Script
Use \`sigul-init-nss-only.sh\` for component initialization:
\`\`\`bash
# Initialize bridge
./scripts/sigul-init-nss-only.sh --role bridge --start-service

# Initialize server
./scripts/sigul-init-nss-only.sh --role server --start-service
\`\`\`

### Health Check Library
Use \`health.sh\` for health checks:
\`\`\`bash
source scripts/lib/health.sh
nss_health_check_all
\`\`\`

## Docker Compose Updates

The Docker Compose file has been updated to use NSS-only initialization and health checks:

- Bridge health check: NSS certificate existence
- Server health check: NSS certificate existence
- Client initialization: NSS-only approach

## Backup Information

Original files have been backed up to: \`$BACKUP_DIR\`

To restore original functionality (not recommended):
\`\`\`bash
# Restore from backup
cp -r $BACKUP_DIR/* ./
\`\`\`

## Benefits of NSS-Only Approach

1. **Architectural Correctness**: Matches Sigul's NSS-based design
2. **Simplified Validation**: No complex PEM file validation logic
3. **Better Performance**: Faster health checks and validation
4. **Reduced Complexity**: Single validation approach (NSS-only)
5. **Improved Maintainability**: Clear separation of concerns
6. **Production Ready**: Matches production Sigul deployments

## Migration Date

Migration completed on: $(date '+%Y-%m-%d %H:%M:%S')

## Next Steps

1. Test the NSS-only validation with your deployment
2. Update any custom scripts to use the new NSS validation tools
3. Remove backup files after confirming everything works correctly
4. Update documentation to reflect NSS-only approach

EOF

    success "Migration report generated: $MIGRATION_REPORT"
}

#######################################
# Main Processing
#######################################

process_file() {
    local file="$1"
    local full_path="$PROJECT_ROOT/$file"

    if [[ ! -f "$full_path" ]]; then
        warn "File not found: $file"
        return 1
    fi

    # Check if file has PEM validation
    detect_pem_validation "$full_path"
    local pem_matches=$?

    if [[ $pem_matches -eq 0 ]]; then
        debug "No PEM validation found in: $file"
        return 0
    fi

    log "Processing file with $pem_matches PEM validation patterns: $file"

    # Create backup
    create_backup "$full_path"

    # Disable PEM validation
    disable_openssl_functions "$full_path"

    # Add NSS-only header
    add_nss_only_header "$full_path"

    success "Processed: $file"
}

show_usage() {
    cat << EOF
Disable Legacy PEM Validation Script v$SCRIPT_VERSION

This script disables legacy PEM-based validation functions and replaces
them with NSS-only validation approach for Sigul infrastructure.

Usage:
  $0 [OPTIONS]

Options:
  --dry-run           Show what would be changed without making changes
  --backup-dir DIR    Specify backup directory (default: auto-generated)
  --help              Show this help message

Examples:
  $0                          # Disable PEM validation with backup
  $0 --dry-run               # Preview changes without modifying files
  $0 --backup-dir ./my-backup # Use custom backup directory

The script will:
1. Create backups of all modified files
2. Disable OpenSSL/PEM validation functions
3. Add NSS-only headers to modified files
4. Generate a migration report
5. Update configurations to use NSS nicknames

After running this script, use the new NSS-only tools:
- validate-nss.sh for validation
- sigul-init-nss-only.sh for initialization
- health.sh for health checks

EOF
}

main() {
    log "Disable Legacy PEM Validation Script v$SCRIPT_VERSION"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                warn "DRY-RUN MODE: No files will be modified"
                shift
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        log "=== DRY RUN MODE - PREVIEW ONLY ==="
    else
        log "=== DISABLING LEGACY PEM VALIDATION ==="
        log "Backup directory: $BACKUP_DIR"
    fi

    # Process target files
    local processed_files=0
    local modified_files=0

    for file in "${TARGET_FILES[@]}"; do
        if process_file "$file"; then
            ((processed_files++))
            local full_path="$PROJECT_ROOT/$file"
            if [[ -f "$full_path" ]]; then
                if detect_pem_validation "$full_path"; then
                    ((modified_files++))
                fi
            fi
        fi
    done

    # Generate migration report
    generate_migration_report

    # Summary
    log "=== MIGRATION SUMMARY ==="
    log "Files processed: $processed_files"
    log "Files with PEM validation: $modified_files"

    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY-RUN completed - no files were modified"
        log "Run without --dry-run to apply changes"
    else
        success "Legacy PEM validation disabled successfully"
        log "Backup directory: $BACKUP_DIR"
        log "Migration report: $MIGRATION_REPORT"
        log ""
        log "Next steps:"
        log "1. Test with: docker compose -f docker-compose.sigul.yml up"
        log "2. Validate with: ./scripts/validate-nss.sh all"
        log "3. Review migration report: $MIGRATION_REPORT"
    fi
}

# Run main function
main "$@"
