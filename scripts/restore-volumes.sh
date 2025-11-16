#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Sigul Volume Restore Script
#
# This script restores Docker volumes from backups created by backup-volumes.sh.
# It can restore individual volumes or all volumes from a specific backup timestamp.
#
# Usage:
#   ./restore-volumes.sh <volume-name> <backup-file>
#   ./restore-volumes.sh --restore-all <timestamp>
#
# Options:
#   --restore-all TIMESTAMP    Restore all volumes from backup with given timestamp
#   --backup-dir DIR          Directory containing backups (default: ./backups)
#   --force                   Skip confirmation prompts
#   --help                    Show this help message

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Default configuration
BACKUP_DIR="${BACKUP_DIR:-./backups}"
FORCE=false
RESTORE_ALL=false
TIMESTAMP=""
VOLUME_NAME=""
BACKUP_FILE=""

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] RESTORE:${NC} $*"
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
    cat << 'EOF'
Sigul Volume Restore Script

Usage:
  # Restore a single volume
  ./restore-volumes.sh <volume-name> <backup-file>

  # Restore all volumes from a specific backup
  ./restore-volumes.sh --restore-all <timestamp>

Options:
  --restore-all TIMESTAMP    Restore all volumes from backup with given timestamp
  --backup-dir DIR          Directory containing backups (default: ./backups)
  --force                   Skip confirmation prompts (DANGEROUS)
  --help                    Show this help message

Examples:
  # Restore single volume
  ./restore-volumes.sh sigul_server_data backups/sigul_server_data-20250116-120000.tar.gz

  # Restore all volumes from a backup timestamp
  ./restore-volumes.sh --restore-all 20250116-120000

  # Restore with custom backup directory
  ./restore-volumes.sh --backup-dir /mnt/backups --restore-all 20250116-120000

Warning:
  This operation will OVERWRITE existing volume data!
  Make sure services are stopped before restoring:
    docker-compose -f docker-compose.sigul.yml down

EOF
    exit 0
}

# Parse command line arguments
parse_args() {
    if [ $# -eq 0 ]; then
        show_help
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --restore-all)
                RESTORE_ALL=true
                TIMESTAMP="$2"
                shift 2
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help)
                show_help
                ;;
            *)
                if [ -z "$VOLUME_NAME" ]; then
                    VOLUME_NAME="$1"
                    shift
                elif [ -z "$BACKUP_FILE" ]; then
                    BACKUP_FILE="$1"
                    shift
                else
                    error "Unknown option: $1"
                    echo "Use --help for usage information"
                    exit 1
                fi
                ;;
        esac
    done

    # Validate arguments
    if [ "$RESTORE_ALL" = false ]; then
        if [ -z "$VOLUME_NAME" ] || [ -z "$BACKUP_FILE" ]; then
            error "Missing required arguments for single volume restore"
            echo "Usage: $0 <volume-name> <backup-file>"
            echo "Use --help for more information"
            exit 1
        fi
    else
        if [ -z "$TIMESTAMP" ]; then
            error "Missing timestamp for --restore-all"
            echo "Usage: $0 --restore-all <timestamp>"
            exit 1
        fi
    fi
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

    # Check if backup directory exists
    if [ ! -d "${BACKUP_DIR}" ]; then
        fatal "Backup directory not found: ${BACKUP_DIR}"
    fi

    success "Prerequisites check passed"
}

# Check if services are running
check_services_stopped() {
    log "Checking if services are stopped..."

    local running_containers
    running_containers=$(docker ps --filter "name=sigul" --format "{{.Names}}" 2>/dev/null || true)

    if [ -n "$running_containers" ]; then
        error "Sigul services are still running:"
        echo "$running_containers" | while IFS= read -r line; do echo "  - $line"; done
        echo ""
        warn "You must stop services before restoring volumes:"
        warn "  docker-compose -f docker-compose.sigul.yml down"
        echo ""

        if [ "$FORCE" = false ]; then
            fatal "Aborting restore to prevent data corruption"
        else
            warn "Forcing restore despite running services (--force specified)"
        fi
    else
        success "Services are stopped"
    fi
}

# Confirm restore operation
confirm_restore() {
    local volume="$1"

    if [ "$FORCE" = true ]; then
        warn "Skipping confirmation (--force specified)"
        return 0
    fi

    echo ""
    warn "WARNING: This operation will OVERWRITE existing data in volume: ${volume}"
    warn "This action cannot be undone!"
    echo ""
    read -r -p "Type 'yes' to continue: " CONFIRM

    if [ "${CONFIRM}" != "yes" ]; then
        log "Restore cancelled by user"
        exit 0
    fi
}

# Restore a single volume
restore_volume() {
    local volume_name="$1"
    local backup_file="$2"

    log "Restoring volume: ${volume_name}"
    log "From backup: ${backup_file}"

    # Verify backup file exists
    if [ ! -f "${backup_file}" ]; then
        fatal "Backup file not found: ${backup_file}"
    fi

    # Get backup file size
    local backup_size
    backup_size=$(du -h "${backup_file}" | cut -f1)
    log "Backup size: ${backup_size}"

    # Confirm restore
    confirm_restore "${volume_name}"

    # Remove existing volume if it exists
    if docker volume inspect "${volume_name}" &> /dev/null; then
        log "Removing existing volume: ${volume_name}"
        if ! docker volume rm "${volume_name}" 2>/dev/null; then
            error "Failed to remove existing volume"
            error "Make sure no containers are using this volume"
            return 1
        fi
    fi

    # Create fresh volume
    log "Creating fresh volume: ${volume_name}"
    if ! docker volume create "${volume_name}" &> /dev/null; then
        fatal "Failed to create volume: ${volume_name}"
    fi

    # Restore data
    log "Restoring data..."
    if docker run --rm \
        -v "${volume_name}:/volume" \
        -v "$(dirname "${backup_file}"):/backup:ro" \
        alpine:latest \
        tar xzf "/backup/$(basename "${backup_file}")" -C /volume 2>/dev/null; then

        success "Successfully restored ${volume_name}"
        return 0
    else
        error "Failed to restore ${volume_name}"
        return 1
    fi
}

# Get list of backup files for a timestamp
get_backup_files() {
    local timestamp="$1"
    local files=()

    # Find all backup files matching the timestamp
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "${BACKUP_DIR}" -name "*-${timestamp}.tar.gz" -print0 2>/dev/null)

    echo "${files[@]}"
}

# Extract volume name from backup filename
get_volume_name_from_file() {
    local backup_file="$1"
    local filename
    filename=$(basename "$backup_file")

    # Remove timestamp and extension to get volume name
    # Example: sigul_server_data-20250116-120000.tar.gz -> sigul_server_data
    local volume_name
    volume_name=$(echo "$filename" | sed -E 's/-[0-9]{8}-[0-9]{6}\.tar\.gz$//')

    echo "$volume_name"
}

# Restore all volumes from a timestamp
restore_all_volumes() {
    local timestamp="$1"

    log "Restoring all volumes from backup timestamp: ${timestamp}"

    # Get list of backup files
    local backup_files
    mapfile -t backup_files < <(get_backup_files "$timestamp")

    if [ ${#backup_files[@]} -eq 0 ]; then
        fatal "No backup files found for timestamp: ${timestamp}"
    fi

    log "Found ${#backup_files[@]} backup file(s)"
    echo ""

    # List files to be restored
    for file in "${backup_files[@]}"; do
        local volume
        volume=$(get_volume_name_from_file "$file")
        local size
        size=$(du -h "$file" | cut -f1)
        log "  - ${volume} (${size})"
    done

    echo ""
    warn "This will restore ${#backup_files[@]} volume(s)"
    confirm_restore "ALL VOLUMES"

    # Restore each volume
    local success_count=0
    local failed_count=0

    echo ""
    for file in "${backup_files[@]}"; do
        local volume
        volume=$(get_volume_name_from_file "$file")

        if restore_volume "$volume" "$file"; then
            success_count=$((success_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
        echo ""
    done

    log "=== Restore Summary ==="
    log "Successful: ${success_count}"

    if [ $failed_count -gt 0 ]; then
        warn "Failed: ${failed_count}"
    fi

    echo ""
    if [ $failed_count -eq 0 ]; then
        success "All volumes restored successfully"
        return 0
    else
        warn "Some volumes failed to restore"
        return 1
    fi
}

# Verify restored data
verify_restored_data() {
    local volume_name="$1"

    log "Verifying restored data in ${volume_name}..."

    # Check if volume has content
    local file_count
    file_count=$(docker run --rm \
        -v "${volume_name}:/volume:ro" \
        alpine:latest \
        find /volume -type f | wc -l)

    if [ "$file_count" -gt 0 ]; then
        success "Volume contains ${file_count} file(s)"
        return 0
    else
        warn "Volume appears to be empty"
        return 1
    fi
}

# Main restore function
main() {
    log "=== Sigul Volume Restore ==="
    echo ""

    # Parse arguments
    parse_args "$@"

    # Check prerequisites
    check_prerequisites

    # Check if services are stopped
    check_services_stopped

    echo ""

    # Perform restore
    if [ "$RESTORE_ALL" = true ]; then
        restore_all_volumes "$TIMESTAMP"
    else
        restore_volume "$VOLUME_NAME" "$BACKUP_FILE"
        verify_restored_data "$VOLUME_NAME"
    fi

    echo ""
    success "=== Restore Complete ==="
    echo ""
    log "Next steps:"
    log "  1. Start services: docker-compose -f docker-compose.sigul.yml up -d"
    log "  2. Check service health: docker ps"
    log "  3. Verify logs: docker logs sigul-bridge && docker logs sigul-server"
    echo ""
}

# Execute main function
main "$@"
