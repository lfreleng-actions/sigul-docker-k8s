#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Volume Backup Script
#
# This script backs up critical Docker volumes for the Sigul infrastructure.
# It creates timestamped tar.gz archives of volume contents.
#
# Usage:
#   ./backup-volumes.sh [--backup-dir DIR] [--all]
#
# Options:
#   --backup-dir DIR    Directory to store backups (default: ./backups)
#   --all               Backup all volumes including logs (default: critical only)
#   --help              Show this help message

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Default configuration
BACKUP_DIR="${BACKUP_DIR:-./backups}"
BACKUP_ALL=false
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] BACKUP:${NC} $*"
}

success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SUCCESS:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*"
}

fatal() {
    error "$*"
    exit 1
}

# Show usage
show_help() {
    cat << EOF
Sigul Volume Backup Script

Usage:
  $0 [OPTIONS]

Options:
  --backup-dir DIR    Directory to store backups (default: ./backups)
  --all               Backup all volumes including logs
  --help              Show this help message

Examples:
  # Backup critical volumes only
  $0

  # Backup all volumes including logs
  $0 --all

  # Backup to custom directory
  $0 --backup-dir /mnt/backups

  # Backup all volumes to custom directory
  $0 --all --backup-dir /mnt/backups

Backup Priority Levels:
  - CRITICAL: Server data (database + GnuPG keys)
  - HIGH: NSS certificate databases
  - MEDIUM: Server logs
  - LOW: Bridge logs, runtime data

EOF
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --all)
                BACKUP_ALL=true
                shift
                ;;
            --help)
                show_help
                ;;
            *)
                error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        fatal "Docker is not installed or not in PATH"
    fi

    # Check if docker-compose file exists
    if [ ! -f "docker-compose.sigul.yml" ]; then
        fatal "docker-compose.sigul.yml not found in current directory"
    fi

    success "Prerequisites check passed"
}

# Get list of volumes to backup
get_volumes_to_backup() {
    local volumes=()

    # Critical volumes (always backup)
    volumes+=("sigul_server_data")     # Server database + GnuPG keys - CRITICAL

    # High priority volumes (always backup)
    volumes+=("sigul_server_nss")      # Server NSS DB - HIGH
    volumes+=("sigul_bridge_nss")      # Bridge NSS DB - HIGH

    # Medium/Low priority volumes (only if --all specified)
    if [ "$BACKUP_ALL" = true ]; then
        volumes+=("sigul_server_logs")     # Server logs - MEDIUM
        volumes+=("sigul_bridge_logs")     # Bridge logs - LOW
        volumes+=("sigul_bridge_data")     # Bridge data - LOW
        volumes+=("sigul_server_config")   # Server config - HIGH
        volumes+=("sigul_bridge_config")   # Bridge config - HIGH
    fi

    echo "${volumes[@]}"
}

# Verify volume exists
verify_volume_exists() {
    local volume_name="$1"

    if ! docker volume inspect "$volume_name" &> /dev/null; then
        warn "Volume does not exist: $volume_name"
        return 1
    fi

    return 0
}

# Backup a single volume
backup_volume() {
    local volume_name="$1"
    local backup_file="${BACKUP_DIR}/${volume_name}-${TIMESTAMP}.tar.gz"
    local temp_file="${backup_file}.tmp"

    log "Backing up volume: $volume_name"

    # Verify volume exists
    if ! verify_volume_exists "$volume_name"; then
        warn "Skipping non-existent volume: $volume_name"
        return 1
    fi

    # Create backup using Alpine container
    if docker run --rm \
        -v "${volume_name}:/volume:ro" \
        -v "${BACKUP_DIR}:/backup" \
        alpine:latest \
        tar czf "/backup/$(basename "${temp_file}")" -C /volume . 2>/dev/null; then

        # Move temp file to final name
        mv "${temp_file}" "${backup_file}"

        # Get backup file size
        local size
        size=$(du -h "${backup_file}" | cut -f1)
        success "Backed up ${volume_name} → ${backup_file} (${size})"
        return 0
    else
        error "Failed to backup ${volume_name}"
        rm -f "${temp_file}"
        return 1
    fi
}

# Create backup manifest
create_manifest() {
    local manifest_file="${BACKUP_DIR}/backup-manifest-${TIMESTAMP}.txt"

    log "Creating backup manifest..."

    cat > "${manifest_file}" << EOF
Sigul Volume Backup Manifest
=============================

Backup Date: $(date)
Timestamp: ${TIMESTAMP}
Backup Directory: ${BACKUP_DIR}
Backup Mode: $([ "$BACKUP_ALL" = true ] && echo "ALL" || echo "CRITICAL")

Volumes Backed Up:
EOF

    # List all backup files created in this run
    for file in "${BACKUP_DIR}"/*-"${TIMESTAMP}".tar.gz; do
        if [ -f "$file" ]; then
            local filename
            filename=$(basename "$file")
            local size
            size=$(du -h "$file" | cut -f1)
            local volume_name
            volume_name=${filename%-"${TIMESTAMP}".tar.gz}
            echo "  - ${volume_name} (${size})" >> "${manifest_file}"
        fi
    done

    cat >> "${manifest_file}" << EOF

Restore Instructions:
=====================

To restore a volume:
  ./scripts/restore-volumes.sh <volume-name> <backup-file>

Example:
  ./scripts/restore-volumes.sh sigul_server_data ${BACKUP_DIR}/sigul_server_data-${TIMESTAMP}.tar.gz

To restore all volumes from this backup:
  ./scripts/restore-volumes.sh --restore-all ${TIMESTAMP}

Important Notes:
- Restoring volumes will OVERWRITE existing data
- Stop services before restoring: docker-compose -f docker-compose.sigul.yml down
- Start services after restoring: docker-compose -f docker-compose.sigul.yml up -d

EOF

    success "Created manifest: ${manifest_file}"
}

# Main backup function
main() {
    log "=== Sigul Volume Backup ==="
    log "Backup directory: ${BACKUP_DIR}"
    log "Timestamp: ${TIMESTAMP}"
    log "Mode: $([ "$BACKUP_ALL" = true ] && echo "ALL volumes" || echo "CRITICAL volumes only")"
    echo ""

    # Parse arguments
    parse_args "$@"

    # Check prerequisites
    check_prerequisites

    # Create backup directory if it doesn't exist
    if [ ! -d "${BACKUP_DIR}" ]; then
        log "Creating backup directory: ${BACKUP_DIR}"
        mkdir -p "${BACKUP_DIR}"
    fi

    # Get list of volumes to backup
    local volumes
    mapfile -t volumes < <(get_volumes_to_backup)
    log "Backing up ${#volumes[@]} volume(s)"
    echo ""

    # Backup each volume
    local success_count=0
    local failed_count=0

    for volume in "${volumes[@]}"; do
        if backup_volume "$volume"; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
    done

    echo ""
    log "=== Backup Summary ==="
    log "Successful: ${success_count}"

    if [ $failed_count -gt 0 ]; then
        warn "Failed: ${failed_count}"
    fi

    # Create manifest
    if [ $success_count -gt 0 ]; then
        create_manifest
    fi

    echo ""
    if [ $failed_count -eq 0 ]; then
        success "=== Backup Complete ==="
        success "All volumes backed up successfully"
        success "Backups saved to: ${BACKUP_DIR}"
        return 0
    else
        warn "=== Backup Complete with Errors ==="
        warn "Some volumes failed to backup"
        warn "Check the output above for details"
        return 1
    fi
}

# Execute main function
main "$@"
