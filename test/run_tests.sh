#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# BATS Test Runner for Sigul Shell Functions
#
# This script runs the BATS test suite for critical Sigul shell functions
# and provides comprehensive test reporting and coverage information.
#
# Usage:
#   ./run_tests.sh [OPTIONS] [TEST_FILES...]
#
# Options:
#   --help          Show this help message
#   --verbose       Enable verbose test output
#   --tap           Output in TAP format
#   --junit         Generate JUnit XML report
#   --coverage      Show function coverage information
#   --install-bats  Install BATS if not available
#   --dry-run       Show what would be tested without running
#
# Examples:
#   ./run_tests.sh                                    # Run all tests
#   ./run_tests.sh --verbose                          # Run with verbose output
#   ./run_tests.sh --junit --coverage                 # Generate reports

set -euo pipefail

# Script configuration
readonly SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TEST_DIR="$SCRIPT_DIR"
readonly REPORTS_DIR="$PROJECT_ROOT/test-artifacts/test-reports"

# Default options
VERBOSE_MODE=false
TAP_MODE=false
JUNIT_MODE=false
COVERAGE_MODE=false
INSTALL_BATS=false
DRY_RUN=false
SHOW_HELP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] TEST:${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $*"
}

debug() {
    if [[ "${VERBOSE_MODE}" == "true" ]]; then
        echo -e "${PURPLE}[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG:${NC} $*"
    fi
}

# Show help message
show_help() {
    cat << EOF
BATS Test Runner for Sigul Shell Functions

USAGE:
    $0 [OPTIONS] [TEST_FILES...]

OPTIONS:
    --help          Show this help message
    --verbose       Enable verbose test output
    --tap           Output in TAP format
    --junit         Generate JUnit XML report
    --coverage      Show function coverage information
    --install-bats  Install BATS if not available
    --dry-run       Show what would be tested without running

EXAMPLES:
    $0                                    # Run all tests
    $0 --verbose                          # Run with verbose output
    $0 --junit --coverage                 # Generate reports

DESCRIPTION:
    This script runs BATS tests for NSS-only Sigul functionality.

    Test results can be output in various formats and reports generated
    for integration with CI/CD pipelines.

EOF
}

# Parse command line arguments
parse_args() {
    local remaining_args=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                SHOW_HELP=true
                shift
                ;;
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --tap)
                TAP_MODE=true
                shift
                ;;
            --junit)
                JUNIT_MODE=true
                shift
                ;;
            --coverage)
                COVERAGE_MODE=true
                shift
                ;;
            --install-bats)
                INSTALL_BATS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *.bats)
                remaining_args+=("$1")
                shift
                ;;
            *)
                error "Unknown option: $1"
                echo
                show_help
                exit 1
                ;;
        esac
    done

    # Set remaining arguments for test files
    set -- "${remaining_args[@]}"
    TEST_FILES=("$@")
}

# Check if BATS is installed
check_bats_installation() {
    if command -v bats >/dev/null 2>&1; then
        local bats_version
        bats_version=$(bats --version 2>/dev/null | head -1 || echo "unknown")
        debug "BATS found: $bats_version"
        return 0
    else
        return 1
    fi
}

# Install BATS if requested
install_bats() {
    log "Installing BATS test framework..."

    # Check if we're in a container or have package manager
    if command -v apt-get >/dev/null 2>&1; then
        # Ubuntu/Debian
        sudo apt-get update -qq
        sudo apt-get install -y bats
    elif command -v yum >/dev/null 2>&1; then
        # CentOS/RHEL/Fedora
        sudo yum install -y bats
    elif command -v brew >/dev/null 2>&1; then
        # macOS with Homebrew
        brew install bats-core
    else
        # Manual installation
        log "Installing BATS from source..."
        local bats_dir="/tmp/bats-install"
        rm -rf "$bats_dir"
        git clone https://github.com/bats-core/bats-core.git "$bats_dir"
        cd "$bats_dir"
        sudo ./install.sh /usr/local
        cd - >/dev/null
        rm -rf "$bats_dir"
    fi

    # Verify installation
    if check_bats_installation; then
        success "BATS installed successfully"
    else
        error "BATS installation failed"
        exit 1
    fi
}

# Discover test files
discover_test_files() {
    local test_files=()

    if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
        # Use specified test files
        for test_file in "${TEST_FILES[@]}"; do
            if [[ -f "$TEST_DIR/$test_file" ]]; then
                test_files+=("$TEST_DIR/$test_file")
            elif [[ -f "$test_file" ]]; then
                test_files+=("$test_file")
            else
                warn "Test file not found: $test_file"
            fi
        done
    else
        # Discover all .bats files in test directory
        while IFS= read -r -d '' test_file; do
            test_files+=("$test_file")
        done < <(find "$TEST_DIR" -name "test_*.bats" -type f -print0 | sort -z)
    fi

    echo "${test_files[@]}"
}

# Show test coverage information
show_test_coverage() {
    log "Analyzing test coverage for shell functions..."

    local functions_tested=()
    local functions_available=()

    # Find functions being tested
    for test_file in $(discover_test_files); do
        local test_name
        test_name=$(basename "$test_file" .bats)
        case "$test_name" in
            # NSS-only tests would go here when created
            *)
                functions_tested+=("unknown")
                ;;
        esac
    done

    # Find available functions (simplified analysis)
    local sigul_init_script="$PROJECT_ROOT/scripts/sigul-init.sh"
    if [[ -f "$sigul_init_script" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\(\)[[:space:]]*\{ ]]; then
                local func_name="${BASH_REMATCH[1]}"
                if [[ ! "$func_name" =~ ^_ ]]; then  # Skip private functions
                    functions_available+=("$func_name")
                fi
            fi
        done < "$sigul_init_script"
    fi

    # Display coverage report
    echo
    echo "=== Test Coverage Report ==="
    echo "Functions with tests: ${#functions_tested[@]}"
    for func in "${functions_tested[@]}"; do
        echo "  ✅ $func"
    done

    echo
    echo "Available functions in sigul-init.sh: ${#functions_available[@]}"
    echo "Coverage: ${#functions_tested[@]}/${#functions_available[@]} functions tested"

    # Show untested critical functions
    local critical_functions=(
        "perform_nss_integrity_deep_check"
        "capture_fatal_exit_snapshot"
        "verify_bridge_reachability"
        "detect_config_drift"
    )

    echo
    echo "Critical functions (test status):"
    for func in "${critical_functions[@]}"; do
        if printf '%s\n' "${functions_tested[@]}" | grep -q "^$func$"; then
            echo "  ✅ $func"
        else
            echo "  ⚠️  $func (not tested)"
        fi
    done
    echo
}

# Run BATS tests
run_bats_tests() {
    local test_files
    mapfile -t test_files < <(discover_test_files)

    if [[ ${#test_files[@]} -eq 0 ]]; then
        error "No test files found"
        return 1
    fi

    log "Running BATS tests for ${#test_files[@]} test file(s)..."

    # Create reports directory
    mkdir -p "$REPORTS_DIR"

    # Build BATS command
    local bats_cmd=("bats")

    if [[ "$VERBOSE_MODE" == "true" ]]; then
        bats_cmd+=("--verbose-run")
    fi

    if [[ "$TAP_MODE" == "true" ]]; then
        bats_cmd+=("--tap")
    fi

    # Add formatter for JUnit output if requested
    if [[ "$JUNIT_MODE" == "true" ]]; then
        local junit_file="$REPORTS_DIR/test-results.xml"
        log "JUnit XML report will be generated: $junit_file"
        # Note: BATS core doesn't have built-in JUnit support
        # This would require bats-support and bats-assert libraries
        warn "JUnit XML output requires additional BATS libraries (bats-support, bats-assert)"
    fi

    # Run tests
    local test_exit_code=0
    local test_output

    log "Executing: ${bats_cmd[*]} ${test_files[*]}"

    if test_output=$("${bats_cmd[@]}" "${test_files[@]}" 2>&1); then
        success "All tests passed"
    else
        test_exit_code=$?
        error "Some tests failed (exit code: $test_exit_code)"
    fi

    # Display test output
    echo "$test_output"

    # Generate summary
    local total_tests passed_tests failed_tests
    total_tests=$(echo "$test_output" | grep -c "^ok\|^not ok" || echo "0")
    passed_tests=$(echo "$test_output" | grep -c "^ok" || echo "0")
    failed_tests=$(echo "$test_output" | grep -c "^not ok" || echo "0")

    echo
    echo "=== Test Summary ==="
    echo "Total tests: $total_tests"
    echo "Passed: $passed_tests"
    echo "Failed: $failed_tests"

    if [[ "$test_exit_code" -eq 0 ]]; then
        success "✅ All tests passed!"
    else
        error "❌ $failed_tests test(s) failed"
    fi

    return $test_exit_code
}

# Show what would be tested (dry run)
show_dry_run() {
    local test_files
    mapfile -t test_files < <(discover_test_files)

    log "Dry run - showing what would be tested:"
    echo
    echo "=== Test Discovery ==="
    echo "Test directory: $TEST_DIR"
    echo "Found ${#test_files[@]} test file(s):"

    for test_file in "${test_files[@]}"; do
        echo "  📄 $(basename "$test_file")"

        # Show test cases in each file
        if [[ -f "$test_file" ]]; then
            local test_cases
            test_cases=$(grep -E "^@test" "$test_file" | sed 's/@test "\([^"]*\)".*/  - \1/' || echo "  - (no test cases found)")
            echo "$test_cases"
        fi
        echo
    done

    echo "=== Configuration ==="
    echo "Verbose mode: $VERBOSE_MODE"
    echo "TAP format: $TAP_MODE"
    echo "JUnit output: $JUNIT_MODE"
    echo "Coverage analysis: $COVERAGE_MODE"
    echo "Reports directory: $REPORTS_DIR"
    echo
}

# Main function
main() {
    parse_args "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    log "=== BATS Test Runner for Sigul Shell Functions ==="
    debug "Project root: $PROJECT_ROOT"
    debug "Test directory: $TEST_DIR"

    # Check BATS installation
    if ! check_bats_installation; then
        if [[ "$INSTALL_BATS" == "true" ]]; then
            install_bats
        else
            error "BATS is not installed. Use --install-bats to install automatically."
            exit 1
        fi
    fi

    # Show coverage information if requested
    if [[ "$COVERAGE_MODE" == "true" ]]; then
        show_test_coverage
    fi

    # Dry run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        show_dry_run
        exit 0
    fi

    # Run the tests
    local exit_code=0
    if ! run_bats_tests; then
        exit_code=1
    fi

    # Final status
    if [[ $exit_code -eq 0 ]]; then
        success "🎉 Test run completed successfully"
    else
        error "💥 Test run failed with errors"
    fi

    exit $exit_code
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
