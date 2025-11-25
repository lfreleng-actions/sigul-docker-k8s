#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Diagnostic Script for Command-Line Argument Passing
#
# This script checks if CLI arguments are being properly passed to
# the bridge, server, and client processes.

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log() {
    echo -e "${BLUE}[DIAGNOSE]${NC} $*"
}

success() {
    echo -e "${GREEN}[DIAGNOSE]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[DIAGNOSE]${NC} $*"
}

error() {
    echo -e "${RED}[DIAGNOSE]${NC} $*"
}

section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}========================================${NC}"
}

#######################################
# Check Wrapper Scripts
#######################################

check_wrapper_scripts() {
    section "Checking Wrapper Scripts"

    local scripts=(
        "/usr/sbin/sigul_bridge"
        "/usr/sbin/sigul_server"
        "/usr/bin/sigul"
    )

    for script in "${scripts[@]}"; do
        log "Checking $script..."

        if [ ! -f "$script" ]; then
            error "  ❌ NOT FOUND"
            continue
        fi

        if [ ! -x "$script" ]; then
            error "  ❌ NOT EXECUTABLE"
            continue
        fi

        success "  ✅ EXISTS and EXECUTABLE"

        log "  Content:"
        sed 's/^/    /' "$script"
        echo ""

        # Check if it properly passes arguments
        if grep -q '"$@"' "$script"; then
            success "  ✅ Passes arguments with \"\$@\""
        else
            warn "  ⚠️  May not pass arguments correctly"
        fi
    done
}

#######################################
# Check Python Modules
#######################################

check_python_modules() {
    section "Checking Python Modules"

    local modules=(
        "bridge"
        "server"
        "client"
    )

    # Find where sigul python modules are installed
    local sigul_path
    sigul_path=$(python3 -c "import sys; import os; paths = [p for p in sys.path if 'sigul' in p]; print(paths[0] if paths else '/usr/share/sigul')" 2>/dev/null || echo "/usr/share/sigul")

    log "Python module path: $sigul_path"

    for module in "${modules[@]}"; do
        log "Checking ${module}.py..."

        local module_file="${sigul_path}/${module}.py"

        if [ ! -f "$module_file" ]; then
            error "  ❌ NOT FOUND at $module_file"
            continue
        fi

        success "  ✅ EXISTS at $module_file"

        # Check if it has main() function
        if grep -q "def main(" "$module_file"; then
            success "  ✅ Has main() function"
        else
            error "  ❌ Missing main() function"
        fi

        # Check if it calls main
        if grep -q "if __name__ == '__main__':" "$module_file"; then
            success "  ✅ Has __main__ entry point"
        else
            error "  ❌ Missing __main__ entry point"
        fi
    done
}

#######################################
# Check Argument Parsing in utils.py
#######################################

check_utils_argument_parsing() {
    section "Checking Argument Parsing in utils.py"

    local sigul_path
    sigul_path=$(python3 -c "import sys; import os; paths = [p for p in sys.path if 'sigul' in p]; print(paths[0] if paths else '/usr/share/sigul')" 2>/dev/null || echo "/usr/share/sigul")

    local utils_file="${sigul_path}/utils.py"

    if [ ! -f "$utils_file" ]; then
        error "utils.py NOT FOUND at $utils_file"
        return
    fi

    log "Checking utils.py at $utils_file"

    # Check for optparse usage
    if grep -q "optparse" "$utils_file"; then
        success "✅ Uses optparse for argument parsing"
    else
        error "❌ Does not use optparse"
    fi

    # Check for get_daemon_options function
    if grep -q "def get_daemon_options" "$utils_file"; then
        success "✅ Has get_daemon_options() function"

        log "Function signature:"
        grep -A 10 "def get_daemon_options" "$utils_file" | sed 's/^/  /'
    else
        error "❌ Missing get_daemon_options() function"
    fi

    # Check for config file option
    if grep -q "add_option.*-c.*--config-file" "$utils_file"; then
        success "✅ Supports -c/--config-file option"
    else
        error "❌ Missing config file option"
    fi

    # Check for verbosity option
    if grep -q "add_option.*-v.*--verbose" "$utils_file"; then
        success "✅ Supports -v/--verbose option"
    else
        warn "⚠️  Missing verbosity option"
    fi
}

#######################################
# Test Actual Argument Passing
#######################################

test_argument_passing() {
    section "Testing Actual Argument Passing"

    log "Testing sigul_bridge wrapper..."

    # Create a test config file
    local test_config="/tmp/test-bridge.conf"
    cat > "$test_config" << 'EOF'
[bridge]
bridge-cert-nickname: test-bridge
EOF

    log "Running: /usr/sbin/sigul_bridge -c $test_config --help 2>&1 | head -20"
    if /usr/sbin/sigul_bridge -c "$test_config" --help 2>&1 | head -20; then
        success "✅ Command executed (help output above)"
    else
        error "❌ Command failed with exit code $?"
    fi

    rm -f "$test_config"
}

#######################################
# Check Process Arguments
#######################################

check_running_processes() {
    section "Checking Running Process Arguments"

    log "Looking for running sigul processes..."

    if pgrep -f "sigul_bridge" > /dev/null 2>&1; then
        log "Bridge process(es) found:"
        # shellcheck disable=SC2009  # ps/grep pattern used for detailed output
        ps aux | grep "[s]igul_bridge" | sed 's/^/  /'

        log "Full command line:"
        pgrep -fa "sigul_bridge" | sed 's/^/  /'
    else
        warn "No bridge processes running"
    fi

    if pgrep -f "sigul_server" > /dev/null 2>&1; then
        log "Server process(es) found:"
        # shellcheck disable=SC2009  # ps/grep pattern used for detailed output
        ps aux | grep "[s]igul_server" | sed 's/^/  /'

        log "Full command line:"
        pgrep -fa "sigul_server" | sed 's/^/  /'
    else
        warn "No server processes running"
    fi
}

#######################################
# Check Log Files
#######################################

check_log_files() {
    section "Checking Log Files"

    local log_files=(
        "/var/log/sigul_bridge.log"
        "/var/log/sigul_server.log"
        "/var/log/sigul_client.log"
    )

    for log_file in "${log_files[@]}"; do
        log "Checking $log_file..."

        if [ ! -f "$log_file" ]; then
            warn "  ⚠️  File does not exist"
            continue
        fi

        local size
        size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")

        if [ "$size" -eq 0 ]; then
            error "  ❌ File is EMPTY (0 bytes)"
        else
            success "  ✅ File has content ($size bytes)"

            log "  Last 5 lines:"
            tail -5 "$log_file" | sed 's/^/    /'
        fi
    done
}

#######################################
# Check Configuration Files
#######################################

check_config_files() {
    section "Checking Configuration Files"

    local config_files=(
        "/etc/sigul/bridge.conf"
        "/etc/sigul/server.conf"
        "/etc/sigul/client.conf"
    )

    for config_file in "${config_files[@]}"; do
        log "Checking $config_file..."

        if [ ! -f "$config_file" ]; then
            error "  ❌ File does not exist"
            continue
        fi

        success "  ✅ File exists"

        # Check for log-level setting
        if grep -q "^log-level:" "$config_file"; then
            local log_level
            log_level=$(grep "^log-level:" "$config_file" | cut -d: -f2 | tr -d ' ')
            log "  Log level: $log_level"
        else
            warn "  ⚠️  No log-level setting found"
        fi
    done
}

#######################################
# Main
#######################################

main() {
    log "Sigul Command-Line Argument Diagnostic Tool"
    log "============================================"

    check_wrapper_scripts
    check_python_modules
    check_utils_argument_parsing
    check_config_files
    check_log_files
    check_running_processes
    test_argument_passing

    section "Diagnostic Complete"
    log "Review the output above for any issues with argument passing."
}

main "$@"
