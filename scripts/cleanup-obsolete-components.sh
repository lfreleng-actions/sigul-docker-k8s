#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Cleanup Script for Obsolete OpenSSL Components
#
# This script removes obsolete OpenSSL-based certificate files and scripts
# that have been replaced by the NSS-based PKI implementation.
#
# Usage:
#   ./cleanup-obsolete-components.sh [--dry-run] [--force]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DRY_RUN=false
FORCE_CLEANUP=false
BACKUP_DIR="backup-$(date +%Y%m%d_%H%M%S)"

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] CLEANUP:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] CLEANUP WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] CLEANUP ERROR:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] CLEANUP SUCCESS:${NC} $*"
}

# Function to show usage
show_usage() {
    cat << EOF
Cleanup Script for Obsolete OpenSSL Components

This script removes obsolete OpenSSL-based certificate files and scripts
that have been replaced by the NSS-based PKI implementation.

Usage:
  $0 [OPTIONS]

Options:
  --dry-run         Show what would be removed without actually deleting
  --force           Skip confirmation prompts and proceed with cleanup
  --backup          Create backup before deletion (default: true)
  --help            Show this help message

Files to be removed:
  - pki/setup-ca.sh (replaced by NSS scripts)
  - pki/ca-key.pem (NSS stores keys internally)
  - pki/ca.crt (NSS handles CA certificates)
  - pki/ca.conf (OpenSSL configuration)
  - pki/ca.srl (OpenSSL serial file)
  - pki/generate-component-cert.sh (replaced by NSS functions)
  - Legacy certificate directories
  - Obsolete configuration files

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE_CLEANUP=true
                shift
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
}

# Function to check if we're in the right directory
check_project_root() {
    if [[ ! -f "docker-compose.sigul.yml" ]] || [[ ! -d "pki" ]] || [[ ! -d "scripts" ]]; then
        error "This script must be run from the sigul-sign-docker project root directory"
        error "Expected files: docker-compose.sigul.yml, pki/, scripts/"
        return 1
    fi

    if [[ ! -f "REFACTORING_PLAN.md" ]]; then
        warn "REFACTORING_PLAN.md not found - this may not be the correct project"
    fi

    return 0
}

# Function to create backup of files before deletion
create_backup() {
    local files_to_backup=("$@")

    if [[ ${#files_to_backup[@]} -eq 0 ]]; then
        log "No files to backup"
        return 0
    fi

    log "Creating backup directory: $BACKUP_DIR"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would create backup directory: $BACKUP_DIR"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    for file in "${files_to_backup[@]}"; do
        if [[ -f "$file" ]]; then
            local backup_path="$BACKUP_DIR/$file"
            mkdir -p "$(dirname "$backup_path")"
            cp "$file" "$backup_path"
            log "Backed up: $file → $backup_path"
        elif [[ -d "$file" ]]; then
            local backup_path="$BACKUP_DIR/$file"
            mkdir -p "$(dirname "$backup_path")"
            cp -r "$file" "$backup_path"
            log "Backed up directory: $file → $backup_path"
        fi
    done

    success "Backup completed in: $BACKUP_DIR"
}

# Function to remove a file or directory
remove_item() {
    local item="$1"
    local description="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ -e "$item" ]]; then
            log "[DRY RUN] Would remove: $item ($description)"
            return 0
        else
            log "[DRY RUN] Not found (OK): $item ($description)"
            return 0
        fi
    fi

    if [[ -e "$item" ]]; then
        if [[ -f "$item" ]]; then
            rm "$item"
            success "Removed file: $item ($description)"
        elif [[ -d "$item" ]]; then
            rm -rf "$item"
            success "Removed directory: $item ($description)"
        fi
    else
        log "Not found (OK): $item ($description)"
    fi
}

# Function to clean up obsolete PKI files
cleanup_obsolete_pki_files() {
    log "=== Cleaning up obsolete PKI files ==="

    local obsolete_files=(
        "pki/setup-ca.sh"
        "pki/ca-key.pem"
        "pki/ca.crt"
        "pki/ca.conf"
        "pki/ca.srl"
        "pki/generate-component-cert.sh"
    )

    local obsolete_descriptions=(
        "OpenSSL CA setup script (replaced by NSS scripts)"
        "OpenSSL CA private key (NSS stores keys internally)"
        "OpenSSL CA certificate (NSS handles CA certificates)"
        "OpenSSL CA configuration (NSS uses different config format)"
        "OpenSSL serial number file (NSS handles serials internally)"
        "OpenSSL component certificate generator (replaced by NSS functions)"
    )

    # Create backup if any files exist
    local existing_files=()
    for file in "${obsolete_files[@]}"; do
        if [[ -e "$file" ]]; then
            existing_files+=("$file")
        fi
    done

    if [[ ${#existing_files[@]} -gt 0 ]]; then
        create_backup "${existing_files[@]}"
    fi

    # Remove obsolete files
    for i in "${!obsolete_files[@]}"; do
        remove_item "${obsolete_files[$i]}" "${obsolete_descriptions[$i]}"
    done
}

# Function to clean up legacy certificate directories
cleanup_legacy_cert_directories() {
    log "=== Cleaning up legacy certificate directories ==="

    local legacy_dirs=(
        "pki/certs"
        "pki/private"
        "pki/newcerts"
        "certificates"
        "secrets/certificates"
    )

    local legacy_descriptions=(
        "Legacy OpenSSL certificate directory"
        "Legacy OpenSSL private key directory"
        "Legacy OpenSSL new certificates directory"
        "Old certificate storage directory"
        "Legacy secrets certificate directory (replaced by NSS databases)"
    )

    # Create backup if any directories exist
    local existing_dirs=()
    for dir in "${legacy_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            existing_dirs+=("$dir")
        fi
    done

    if [[ ${#existing_dirs[@]} -gt 0 ]]; then
        create_backup "${existing_dirs[@]}"
    fi

    # Remove legacy directories
    for i in "${!legacy_dirs[@]}"; do
        remove_item "${legacy_dirs[$i]}" "${legacy_descriptions[$i]}"
    done
}

# Function to clean up obsolete configuration files
cleanup_obsolete_config_files() {
    log "=== Cleaning up obsolete configuration files ==="

    local obsolete_configs=(
        "config/openssl.conf"
        "config/ca.conf"
        "pki/openssl.cnf"
        ".env.openssl"
    )

    local config_descriptions=(
        "OpenSSL configuration file (replaced by NSS config)"
        "CA configuration file (NSS uses different format)"
        "OpenSSL configuration template (no longer needed)"
        "OpenSSL environment variables (replaced by NSS variables)"
    )

    # Create backup if any config files exist
    local existing_configs=()
    for config in "${obsolete_configs[@]}"; do
        if [[ -e "$config" ]]; then
            existing_configs+=("$config")
        fi
    done

    if [[ ${#existing_configs[@]} -gt 0 ]]; then
        create_backup "${existing_configs[@]}"
    fi

    # Remove obsolete config files
    for i in "${!obsolete_configs[@]}"; do
        remove_item "${obsolete_configs[$i]}" "${config_descriptions[$i]}"
    done
}

# Function to clean up obsolete scripts
cleanup_obsolete_scripts() {
    log "=== Cleaning up obsolete scripts ==="

    local obsolete_scripts=(
        "scripts/generate-certificates.sh"
        "scripts/setup-openssl-ca.sh"
        "scripts/create-component-certs.sh"
        "scripts/openssl-cert-manager.sh"
    )

    local script_descriptions=(
        "Legacy certificate generation script (replaced by NSS scripts)"
        "OpenSSL CA setup script (replaced by setup-bridge-ca.sh)"
        "Component certificate creation script (replaced by NSS setup scripts)"
        "OpenSSL certificate manager (replaced by NSS certificate management)"
    )

    # Create backup if any scripts exist
    local existing_scripts=()
    for script in "${obsolete_scripts[@]}"; do
        if [[ -e "$script" ]]; then
            existing_scripts+=("$script")
        fi
    done

    if [[ ${#existing_scripts[@]} -gt 0 ]]; then
        create_backup "${existing_scripts[@]}"
    fi

    # Remove obsolete scripts
    for i in "${!obsolete_scripts[@]}"; do
        remove_item "${obsolete_scripts[$i]}" "${script_descriptions[$i]}"
    done
}

# Function to clean up temporary and cache files
cleanup_temp_files() {
    log "=== Cleaning up temporary and cache files ==="

    local temp_patterns=(
        "*.tmp"
        "*.temp"
        ".openssl_*"
        "pki/*.old"
        "pki/*.bak"
        "scripts/*.old"
        "scripts/*.bak"
    )

    for pattern in "${temp_patterns[@]}"; do
        # Use find to safely handle globbing
        while IFS= read -r -d '' file; do
            remove_item "$file" "Temporary/backup file"
        done < <(find . -maxdepth 3 -name "$pattern" -type f -print0 2>/dev/null || true)
    done
}

# Function to update .gitignore to remove obsolete entries
update_gitignore() {
    log "=== Updating .gitignore file ==="

    if [[ ! -f ".gitignore" ]]; then
        log "No .gitignore file found, skipping update"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would update .gitignore to remove obsolete OpenSSL entries"
        return 0
    fi

    # Create backup of .gitignore
    cp ".gitignore" ".gitignore.backup"

    # Remove obsolete entries (lines containing these patterns)
    local obsolete_patterns=(
        "ca-key.pem"
        "ca.crt"
        "ca.conf"
        "ca.srl"
        "certificates/"
        "*.crt"
        "*.key"
        "*.pem"
    )

    local temp_gitignore=".gitignore.tmp"
    cp ".gitignore" "$temp_gitignore"

    for pattern in "${obsolete_patterns[@]}"; do
        # Remove lines containing the pattern, but be careful not to remove NSS-related entries
        sed -i "/^[^#]*$pattern/d" "$temp_gitignore" 2>/dev/null || true
    done

    # Add NSS-specific entries if not already present
    if ! grep -q "nss/.*\.db" "$temp_gitignore" 2>/dev/null; then
        {
            echo ""
            echo "# NSS databases (generated at runtime)"
            echo "nss/*/cert9.db"
            echo "nss/*/key4.db"
            echo "nss/*/pkcs11.txt"
        } >> "$temp_gitignore"
    fi

    mv "$temp_gitignore" ".gitignore"
    success "Updated .gitignore file (backup saved as .gitignore.backup)"
}

# Function to display cleanup summary
display_cleanup_summary() {
    log "=== Cleanup Summary ==="

    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN MODE - No files were actually removed"
        log "Run without --dry-run to perform actual cleanup"
    else
        success "Cleanup completed successfully"

        if [[ -d "$BACKUP_DIR" ]]; then
            log "Backup created in: $BACKUP_DIR"
            log "You can restore files from backup if needed"
        fi
    fi

    echo
    log "Next steps:"
    echo "  1. Review the backup directory if any issues arise"
    echo "  2. Test the NSS-based implementation"
    echo "  3. Update documentation to reflect the changes"
    echo "  4. Commit the cleanup changes to version control"
    echo
}

# Function to get user confirmation
get_confirmation() {
    if [[ "$FORCE_CLEANUP" == "true" ]] || [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    echo
    warn "This will remove obsolete OpenSSL components and may not be reversible"
    warn "A backup will be created in: $BACKUP_DIR"
    echo
    read -p "Do you want to continue? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Cleanup cancelled by user"
        exit 0
    fi
}

# Main execution function
main() {
    parse_args "$@"

    log "Starting cleanup of obsolete OpenSSL components"
    log "Dry run mode: $DRY_RUN"
    log "Force mode: $FORCE_CLEANUP"
    echo

    # Check we're in the right directory
    if ! check_project_root; then
        exit 1
    fi

    # Get user confirmation
    get_confirmation

    # Perform cleanup operations
    cleanup_obsolete_pki_files
    echo
    cleanup_legacy_cert_directories
    echo
    cleanup_obsolete_config_files
    echo
    cleanup_obsolete_scripts
    echo
    cleanup_temp_files
    echo
    update_gitignore
    echo

    # Display summary
    display_cleanup_summary
}

# Execute main function
main "$@"
