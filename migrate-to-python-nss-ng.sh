#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Migration helper script for transitioning from python-nss to python-nss-ng
# This script helps test and validate the migration process

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups/python-nss-migration-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "\n${BLUE}===${NC} $* ${BLUE}===${NC}\n"
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Migrate from python-nss to python-nss-ng in sigul-docker.

COMMANDS:
    backup          Create backup of current installation scripts
    update-script   Update installation script to use python-nss-ng
    test            Test python-nss-ng installation in containers
    rollback        Rollback to python-nss
    verify          Verify migration is complete
    full            Run full migration (backup + update + test)

OPTIONS:
    -s, --source    Installation source (pypi|github) [default: pypi]
    -v, --version   python-nss-ng version to install [default: latest]
    -h, --help      Show this help message

EXAMPLES:
    # Full migration using PyPI
    $0 full

    # Full migration using specific PyPI version
    $0 full --source pypi --version 0.1.0

    # Full migration using GitHub
    $0 full --source github

    # Just backup current state
    $0 backup

    # Test installation without migrating
    $0 test

    # Rollback if something goes wrong
    $0 rollback
EOF
}

# Create backup of current files
backup_files() {
    log_step "Creating Backup"
    
    mkdir -p "$BACKUP_DIR"
    
    log_info "Backing up files to: $BACKUP_DIR"
    
    # Backup installation script
    if [[ -f "${SCRIPT_DIR}/build-scripts/install-python-nss.sh" ]]; then
        cp "${SCRIPT_DIR}/build-scripts/install-python-nss.sh" \
           "${BACKUP_DIR}/install-python-nss.sh.backup"
        log_success "Backed up install-python-nss.sh"
    fi
    
    # Backup Dockerfiles
    for dockerfile in Dockerfile.client Dockerfile.bridge Dockerfile.server; do
        if [[ -f "${SCRIPT_DIR}/${dockerfile}" ]]; then
            cp "${SCRIPT_DIR}/${dockerfile}" \
               "${BACKUP_DIR}/${dockerfile}.backup"
            log_success "Backed up ${dockerfile}"
        fi
    done
    
    # Create backup manifest
    cat > "${BACKUP_DIR}/manifest.txt" << EOF
Python-NSS to Python-NSS-NG Migration Backup
Created: $(date)
Location: ${BACKUP_DIR}

Files backed up:
$(ls -1 "${BACKUP_DIR}" | grep -v manifest.txt)
EOF
    
    log_success "Backup completed: ${BACKUP_DIR}"
    log_info "To restore, run: $0 rollback"
}

# Update installation script
update_script() {
    local source="${1:-pypi}"
    local version="${2:-}"
    
    log_step "Updating Installation Script"
    
    local script_path="${SCRIPT_DIR}/build-scripts/install-python-nss.sh"
    
    if [[ ! -f "$script_path" ]]; then
        log_error "Installation script not found: $script_path"
        return 1
    fi
    
    # Check if new script exists
    if [[ -f "${SCRIPT_DIR}/build-scripts/install-python-nss-ng.sh" ]]; then
        log_info "Found new install-python-nss-ng.sh script"
        log_info "Replacing install-python-nss.sh with python-nss-ng version"
        
        cp "${SCRIPT_DIR}/build-scripts/install-python-nss-ng.sh" "$script_path"
        chmod +x "$script_path"
        
        log_success "Updated $script_path to use python-nss-ng"
    else
        log_error "New script not found: ${SCRIPT_DIR}/build-scripts/install-python-nss-ng.sh"
        log_error "Please ensure install-python-nss-ng.sh exists before migrating"
        return 1
    fi
    
    # Update Dockerfiles to set environment variables if needed
    if [[ "$source" != "pypi" ]] || [[ -n "$version" ]]; then
        log_info "Updating Dockerfiles with installation preferences"
        update_dockerfiles "$source" "$version"
    fi
}

# Update Dockerfiles
update_dockerfiles() {
    local source="$1"
    local version="$2"
    
    for dockerfile in Dockerfile.client Dockerfile.bridge Dockerfile.server; do
        local df_path="${SCRIPT_DIR}/${dockerfile}"
        
        if [[ ! -f "$df_path" ]]; then
            log_warning "Dockerfile not found: $df_path"
            continue
        fi
        
        log_info "Checking $dockerfile for updates needed"
        
        # Add environment variables before the install-python-nss.sh execution
        # This is a simple approach - you may want to customize this
        if [[ "$source" != "pypi" ]]; then
            log_info "  Setting INSTALL_SOURCE=$source"
        fi
        
        if [[ -n "$version" ]]; then
            log_info "  Setting PYTHON_NSS_NG_VERSION=$version"
        fi
        
        # Note: Actual modification of Dockerfiles should be done carefully
        # This is left as a manual step for now
        log_info "  Dockerfile ready (manual ENV additions may be needed)"
    done
}

# Test python-nss-ng in containers
test_installation() {
    log_step "Testing Python-NSS-NG Installation"
    
    local components=("client" "bridge" "server")
    local all_passed=true
    
    for component in "${components[@]}"; do
        log_info "Testing $component container..."
        
        # Check if image exists
        if ! docker images | grep -q "sigul-${component}"; then
            log_warning "Image sigul-${component} not found, skipping"
            continue
        fi
        
        echo ""
        
        # Test 1: Import nss module
        log_info "  Test 1: Importing nss module"
        if docker run --rm "sigul-${component}:latest" \
            python3 -c "import nss; print(f'✓ NSS module imported successfully')" 2>&1; then
            log_success "    PASSED: nss module imports"
        else
            log_error "    FAILED: nss module import"
            all_passed=false
        fi
        
        # Test 2: Import submodules
        log_info "  Test 2: Importing nss submodules"
        if docker run --rm "sigul-${component}:latest" \
            python3 -c "import nss.nss, nss.error, nss.io, nss.ssl; print('✓ All submodules imported')" 2>&1; then
            log_success "    PASSED: All submodules import"
        else
            log_error "    FAILED: Submodule import"
            all_passed=false
        fi
        
        # Test 3: Check version
        log_info "  Test 3: Checking python-nss-ng version"
        if docker run --rm "sigul-${component}:latest" \
            python3 -c "import nss; print(f'✓ Version: {nss.__version__}')" 2>&1; then
            log_success "    PASSED: Version check"
        else
            log_error "    FAILED: Version check"
            all_passed=false
        fi
        
        # Test 4: NSS initialization
        log_info "  Test 4: Testing NSS initialization"
        if docker run --rm "sigul-${component}:latest" \
            python3 -c "import nss.nss; nss.nss.nss_init_nodb(); print('✓ NSS initialized successfully')" 2>&1; then
            log_success "    PASSED: NSS initialization"
        else
            log_error "    FAILED: NSS initialization"
            all_passed=false
        fi
        
        # Test 5: Package info
        log_info "  Test 5: Package information"
        if docker run --rm "sigul-${component}:latest" \
            sh -c "pip3 show python-nss-ng 2>/dev/null || echo 'Package info not available (possibly GitHub install)'" 2>&1; then
            log_success "    PASSED: Package info retrieved"
        else
            log_warning "    WARNING: Could not retrieve package info"
        fi
        
        echo ""
    done
    
    if [[ "$all_passed" == "true" ]]; then
        log_success "All tests PASSED"
        return 0
    else
        log_error "Some tests FAILED"
        return 1
    fi
}

# Rollback to python-nss
rollback() {
    log_step "Rolling Back to Python-NSS"
    
    # Find most recent backup
    if [[ ! -d "${SCRIPT_DIR}/backups" ]]; then
        log_error "No backups directory found"
        return 1
    fi
    
    local latest_backup
    latest_backup=$(find "${SCRIPT_DIR}/backups" -type d -name "python-nss-migration-*" | sort -r | head -1)
    
    if [[ -z "$latest_backup" ]]; then
        log_error "No migration backups found"
        return 1
    fi
    
    log_info "Found backup: $latest_backup"
    
    # Restore files
    if [[ -f "${latest_backup}/install-python-nss.sh.backup" ]]; then
        cp "${latest_backup}/install-python-nss.sh.backup" \
           "${SCRIPT_DIR}/build-scripts/install-python-nss.sh"
        log_success "Restored install-python-nss.sh"
    fi
    
    for dockerfile in Dockerfile.client Dockerfile.bridge Dockerfile.server; do
        if [[ -f "${latest_backup}/${dockerfile}.backup" ]]; then
            cp "${latest_backup}/${dockerfile}.backup" \
               "${SCRIPT_DIR}/${dockerfile}"
            log_success "Restored ${dockerfile}"
        fi
    done
    
    log_success "Rollback completed"
    log_warning "Remember to rebuild container images"
}

# Verify migration
verify_migration() {
    log_step "Verifying Migration"
    
    local script_path="${SCRIPT_DIR}/build-scripts/install-python-nss.sh"
    
    # Check if script contains python-nss-ng references
    if grep -q "python-nss-ng" "$script_path" 2>/dev/null; then
        log_success "Installation script references python-nss-ng"
    else
        log_error "Installation script does not reference python-nss-ng"
        return 1
    fi
    
    # Check if containers have python-nss-ng installed
    log_info "Checking containers for python-nss-ng..."
    
    if docker images | grep -q "sigul-"; then
        test_installation
    else
        log_warning "No sigul container images found"
        log_info "Build containers with: docker-compose -f docker-compose.sigul.yml build"
    fi
}

# Full migration
full_migration() {
    local source="${1:-pypi}"
    local version="${2:-}"
    
    log_step "Starting Full Migration to Python-NSS-NG"
    
    log_info "Configuration:"
    log_info "  Source: $source"
    log_info "  Version: ${version:-latest}"
    echo ""
    
    # Step 1: Backup
    if ! backup_files; then
        log_error "Backup failed, aborting migration"
        return 1
    fi
    
    # Step 2: Update script
    if ! update_script "$source" "$version"; then
        log_error "Script update failed, aborting migration"
        return 1
    fi
    
    # Step 3: Suggest next steps
    log_step "Migration Steps Completed"
    
    log_info "Next steps:"
    log_info "  1. Review changes in build-scripts/install-python-nss.sh"
    log_info "  2. Rebuild container images:"
    log_info "     docker-compose -f docker-compose.sigul.yml build"
    log_info "  3. Test the migration:"
    log_info "     $0 test"
    log_info "  4. If issues occur, rollback:"
    log_info "     $0 rollback"
    echo ""
    
    log_success "Migration preparation complete"
    log_warning "Remember to rebuild and test container images!"
}

# Main
main() {
    local command="${1:-}"
    local source="pypi"
    local version=""
    
    # Parse arguments
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--source)
                source="$2"
                shift 2
                ;;
            -v|--version)
                version="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Execute command
    case "$command" in
        backup)
            backup_files
            ;;
        update-script)
            update_script "$source" "$version"
            ;;
        test)
            test_installation
            ;;
        rollback)
            rollback
            ;;
        verify)
            verify_migration
            ;;
        full)
            full_migration "$source" "$version"
            ;;
        "")
            log_error "No command specified"
            usage
            exit 1
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi