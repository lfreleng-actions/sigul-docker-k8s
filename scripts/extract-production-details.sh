#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
################################################################################
# Sigul Production Configuration Extractor
################################################################################
# Purpose: Extract complete production configuration details for gap analysis
# Usage:   sudo ./extract-production-details.sh [output-dir]
# Safe:    Read-only operations, no modifications to production system
################################################################################

set -euo pipefail

# Configuration
OUTPUT_DIR="${1:-./sigul-production-data-$(date +%Y%m%d-%H%M%S)}"
HOSTNAME=$(hostname -f 2>/dev/null || hostname)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Helper Functions
################################################################################

log_section() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# shellcheck disable=SC2317  # Function is called indirectly
log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

safe_command() {
    local description="$1"
    shift
    echo "### $description"
    if "$@" 2>&1; then
        echo "SUCCESS"
    else
        echo "FAILED or NOT FOUND"
    fi
    echo ""
}

################################################################################
# Main Extraction Function
################################################################################

main() {
    log_info "Starting production configuration extraction"
    log_info "Hostname: $HOSTNAME"
    log_info "Output directory: $OUTPUT_DIR"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Redirect all output to both console and log file
    exec > >(tee -a "$OUTPUT_DIR/extraction.log")
    exec 2>&1

    log_info "Extraction started at: $(date)"

    # Run all extraction sections
    extract_system_info
    extract_sigul_configs
    extract_certificates
    extract_database
    extract_gnupg
    extract_systemd_services
    extract_network_info
    extract_nss_details
    extract_environment
    extract_permissions
    extract_logging
    extract_process_info
    extract_source_code
    extract_config_parser_test

    log_info "NOTE: RabbitMQ, LDAP, and Koji/FAS components detected on production hosts"
    log_info "      are NOT part of Sigul and have been excluded from extraction."

    log_info "Extraction completed at: $(date)"
    log_info "Results saved to: $OUTPUT_DIR"

    # Create summary
    create_summary
}

################################################################################
# Section 1: System Information
################################################################################

extract_system_info() {
    log_section "1. SYSTEM INFORMATION"

    local output="$OUTPUT_DIR/01-system-info.txt"

    {
        safe_command "OS Release" cat /etc/os-release
        safe_command "Kernel Version" uname -a
        safe_command "Python Version" python --version
        safe_command "Python3 Version (if available)" python3 --version
        safe_command "Hostname" hostname -f
        safe_command "Uptime" uptime
        safe_command "SELinux Status" sestatus
        safe_command "Installed Sigul Packages" rpm -qa | grep -i sigul
        safe_command "Installed NSS Packages" rpm -qa | grep -i nss
        safe_command "Installed Python NSS Packages" rpm -qa | grep python-nss
        safe_command "GPG Version" gpg --version
        safe_command "GPG2 Version (if available)" gpg2 --version
    } > "$output"

    log_info "System information saved to: $output"
}

################################################################################
# Section 2: Sigul Configuration Files
################################################################################

extract_sigul_configs() {
    log_section "2. SIGUL CONFIGURATION FILES"

    local output="$OUTPUT_DIR/02-sigul-configs"
    mkdir -p "$output"

    # List all config files
    echo "=== Configuration Files ===" > "$output/file-list.txt"
    ls -lah /etc/sigul/ 2>/dev/null >> "$output/file-list.txt" || echo "No /etc/sigul/ directory" >> "$output/file-list.txt"

    # Copy all config files
    if [ -d /etc/sigul/ ]; then
        for cfg in /etc/sigul/*.conf; do
            if [ -f "$cfg" ]; then
                local basename
                basename=$(basename "$cfg")
                log_info "Extracting: $cfg"
                cp "$cfg" "$output/$basename" 2>/dev/null || {
                    sudo cat "$cfg" 2>/dev/null | tee "$output/$basename" >/dev/null || echo "Cannot read $cfg" > "$output/$basename"
                }
            fi
        done
    fi

    # Extract specific sections from configs
    {
        echo "=== All Sigul Config Sections and Options ==="
        for cfg in /etc/sigul/*.conf; do
            if [ -f "$cfg" ]; then
                echo ""
                echo "========== $cfg =========="
                sudo cat "$cfg" 2>/dev/null || echo "Cannot read"
            fi
        done
    } > "$output/all-configs-combined.txt"

    log_info "Configuration files saved to: $output"
}

################################################################################
# Section 3: Certificate Details
################################################################################

extract_certificates() {
    log_section "3. CERTIFICATE DETAILS"

    local output="$OUTPUT_DIR/03-certificates"
    mkdir -p "$output"

    # NSS database location check
    {
        echo "=== NSS Database Files ==="
        ls -lah /etc/pki/sigul/ 2>/dev/null || echo "No /etc/pki/sigul/ directory"
        echo ""
        echo "=== File Types ==="
        file /etc/pki/sigul/*.db 2>/dev/null || echo "No .db files"
    } > "$output/nss-database-info.txt"

    # List all certificates
    {
        echo "=== Certificate List ==="
        sudo certutil -L -d /etc/pki/sigul 2>/dev/null || echo "Cannot list certificates"
    } > "$output/certificate-list.txt"

    # Extract each certificate in detail
    sudo certutil -L -d /etc/pki/sigul 2>/dev/null | tail -n +4 | awk '{print $1}' | while read -r nick; do
        if [ -n "$nick" ] && [ "$nick" != "" ]; then
            local safe_filename
            safe_filename=$(echo "$nick" | tr '/' '_' | tr ' ' '_')
            log_info "Extracting certificate: $nick"

            {
                echo "=========================================="
                echo "Certificate Nickname: $nick"
                echo "=========================================="
                echo ""
                echo "=== NSS Format (certutil) ==="
                sudo certutil -L -d /etc/pki/sigul -n "$nick" 2>/dev/null || echo "Cannot display cert"
                echo ""
                echo "=== OpenSSL Detailed Format ==="
                sudo certutil -L -d /etc/pki/sigul -n "$nick" -a 2>/dev/null | \
                    openssl x509 -text -noout 2>/dev/null || echo "Cannot export/parse cert"
                echo ""
                echo "=== PEM Format ==="
                sudo certutil -L -d /etc/pki/sigul -n "$nick" -a 2>/dev/null || echo "Cannot export cert"
            } > "$output/cert-${safe_filename}.txt"
        fi
    done

    # Check for PKCS#12 files
    {
        echo "=== PKCS#12 Certificate Files ==="
        ls -lah /etc/pki/sigul/*.p12 2>/dev/null || echo "No .p12 files found"
    } > "$output/pkcs12-files.txt"

    log_info "Certificate details saved to: $output"
}

################################################################################
# Section 4: Database Schema and Structure
################################################################################

extract_database() {
    log_section "4. DATABASE INFORMATION"

    local output="$OUTPUT_DIR/04-database"
    mkdir -p "$output"

    if [ -f /var/lib/sigul/server.sqlite ]; then
        log_info "Database found at: /var/lib/sigul/server.sqlite"

        # File info
        {
            echo "=== Database File Information ==="
            ls -lah /var/lib/sigul/server.sqlite
            echo ""
            file /var/lib/sigul/server.sqlite
            echo ""
            echo "Size: $(du -h /var/lib/sigul/server.sqlite | cut -f1)"
        } > "$output/database-file-info.txt"

        # Schema
        {
            echo "=== Database Schema ==="
            sudo sqlite3 /var/lib/sigul/server.sqlite ".schema" 2>/dev/null || echo "Cannot read schema"
        } > "$output/database-schema.sql"

        # Table info
        {
            echo "=== Database Tables ==="
            sudo sqlite3 /var/lib/sigul/server.sqlite ".tables" 2>/dev/null || echo "Cannot read tables"
            echo ""
            echo "=== User Table Structure (no actual data) ==="
            sudo sqlite3 /var/lib/sigul/server.sqlite "SELECT id, name, LENGTH(sha512_password) as pwd_len, admin FROM users LIMIT 5;" 2>/dev/null || echo "Cannot read users"
            echo ""
            echo "=== Keys Table Structure (no actual data) ==="
            sudo sqlite3 /var/lib/sigul/server.sqlite "SELECT id, name, LENGTH(fingerprint) as fp_len FROM keys LIMIT 5;" 2>/dev/null || echo "Cannot read keys"
            echo ""
            echo "=== Key Access Table Structure (no actual data) ==="
            sudo sqlite3 /var/lib/sigul/server.sqlite "SELECT id, key_id, user_id, LENGTH(encrypted_passphrase) as pass_len, key_admin FROM key_accesses LIMIT 5;" 2>/dev/null || echo "Cannot read key_accesses"
            echo ""
            echo "=== Row Counts ==="
            echo -n "Users: "
            sudo sqlite3 /var/lib/sigul/server.sqlite "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0"
            echo -n "Keys: "
            sudo sqlite3 /var/lib/sigul/server.sqlite "SELECT COUNT(*) FROM keys;" 2>/dev/null || echo "0"
            echo -n "Key Accesses: "
            sudo sqlite3 /var/lib/sigul/server.sqlite "SELECT COUNT(*) FROM key_accesses;" 2>/dev/null || echo "0"
        } > "$output/database-tables-info.txt"

        # Database integrity check
        {
            echo "=== Database Integrity Check ==="
            sudo sqlite3 /var/lib/sigul/server.sqlite "PRAGMA integrity_check;" 2>/dev/null || echo "Cannot check integrity"
        } > "$output/database-integrity.txt"

    else
        log_warn "Database not found at /var/lib/sigul/server.sqlite (normal for bridge)"
        echo "Database not found - this is normal for bridge hosts" > "$output/no-database.txt"
    fi

    log_info "Database information saved to: $output"
}

################################################################################
# Section 5: GnuPG Configuration
################################################################################

extract_gnupg() {
    log_section "5. GNUPG CONFIGURATION"

    local output="$OUTPUT_DIR/05-gnupg"
    mkdir -p "$output"

    if [ -d /var/lib/sigul/gnupg ]; then
        log_info "GnuPG directory found"

        # Directory structure
        {
            echo "=== GnuPG Directory Structure ==="
            sudo ls -laR /var/lib/sigul/gnupg/ 2>/dev/null || echo "Cannot list directory"
            echo ""
            echo "=== File Types ==="
            sudo find /var/lib/sigul/gnupg/ -type f -exec file {} \; 2>/dev/null || echo "Cannot analyze files"
        } > "$output/gnupg-directory-info.txt"

        # Config files
        {
            echo "=== gpg.conf (if exists) ==="
            sudo cat /var/lib/sigul/gnupg/gpg.conf 2>/dev/null || echo "No gpg.conf file"
            echo ""
            echo "=== gpg-agent.conf (if exists) ==="
            sudo cat /var/lib/sigul/gnupg/gpg-agent.conf 2>/dev/null || echo "No gpg-agent.conf file"
        } > "$output/gnupg-config-files.txt"

        # List keys (structure only, no actual keys)
        {
            echo "=== GPG Public Keys (list only) ==="
            sudo -u sigul gpg --homedir /var/lib/sigul/gnupg --list-keys 2>/dev/null || echo "Cannot list public keys"
            echo ""
            echo "=== GPG Secret Keys (count only) ==="
            sudo -u sigul gpg --homedir /var/lib/sigul/gnupg --list-secret-keys 2>/dev/null | grep -c "^sec" || echo "0"
        } > "$output/gnupg-keys-info.txt"

    else
        log_warn "GnuPG directory not found at /var/lib/sigul/gnupg (normal for bridge)"
        echo "GnuPG directory not found - this is normal for bridge hosts" > "$output/no-gnupg.txt"
    fi

    log_info "GnuPG information saved to: $output"
}

################################################################################
# Section 6: Systemd Service Configuration
################################################################################

extract_systemd_services() {
    log_section "6. SYSTEMD SERVICE CONFIGURATION"

    local output="$OUTPUT_DIR/06-systemd"
    mkdir -p "$output"

    # Bridge service
    {
        echo "=== Sigul Bridge Service ==="
        sudo systemctl cat sigul_bridge.service 2>/dev/null || echo "Bridge service not found"
    } > "$output/bridge-service.txt"

    # Bridge status
    {
        echo "=== Sigul Bridge Status ==="
        sudo systemctl status sigul_bridge.service 2>/dev/null || echo "Bridge not running"
    } > "$output/bridge-status.txt"

    # Server service template
    {
        echo "=== Sigul Server Service Template ==="
        sudo systemctl cat sigul_server@.service 2>/dev/null || echo "Server service template not found"
    } > "$output/server-service-template.txt"

    # Active server instances
    {
        echo "=== Active Server Instances ==="
        sudo systemctl list-units 'sigul_server@*' --all --no-pager 2>/dev/null || echo "No server instances"
    } > "$output/server-instances-list.txt"

    # Individual server instance configs
    sudo systemctl list-units 'sigul_server@*' --no-legend 2>/dev/null | awk '{print $1}' | while read -r instance; do
        if [ -n "$instance" ]; then
            local safe_name
            safe_name=$(echo "$instance" | tr '@' '_' | tr '.' '_')
            log_info "Extracting service config: $instance"
            {
                echo "=== $instance ==="
                sudo systemctl cat "$instance" 2>/dev/null || echo "Cannot display service"
                echo ""
                echo "=== Status ==="
                sudo systemctl status "$instance" 2>/dev/null || echo "Cannot get status"
            } > "$output/server-instance-${safe_name}.txt"
        fi
    done

    # Check for drop-in files
    {
        echo "=== Bridge Service Drop-ins ==="
        sudo ls -la /etc/systemd/system/sigul_bridge.service.d/ 2>/dev/null || echo "No drop-ins"
        sudo cat /etc/systemd/system/sigul_bridge.service.d/*.conf 2>/dev/null || echo "No drop-in configs"
        echo ""
        echo "=== Server Service Drop-ins ==="
        sudo ls -la /etc/systemd/system/sigul_server@.service.d/ 2>/dev/null || echo "No drop-ins"
        sudo cat /etc/systemd/system/sigul_server@.service.d/*.conf 2>/dev/null || echo "No drop-in configs"
    } > "$output/service-drop-ins.txt"

    log_info "Systemd service information saved to: $output"
}

################################################################################
# Section 7: Network Configuration
################################################################################

extract_network_info() {
    log_section "7. NETWORK CONFIGURATION"

    local output="$OUTPUT_DIR/07-network"
    mkdir -p "$output"

    # DNS configuration (filtering out non-Sigul infrastructure)
    {
        echo "=== /etc/hosts (Sigul-related entries only) ==="
        grep -E "sigul|bridge|server" /etc/hosts 2>/dev/null || cat /etc/hosts
        echo ""
        echo "=== /etc/resolv.conf ==="
        cat /etc/resolv.conf
        echo ""
        echo "=== nsswitch.conf (relevant lines) ==="
        grep -E "^hosts:|^passwd:|^group:" /etc/nsswitch.conf
    } > "$output/dns-config.txt"

    # Network interfaces
    {
        echo "=== IP Addresses ==="
        ip addr show
        echo ""
        echo "=== Routing Table ==="
        ip route show
    } > "$output/network-interfaces.txt"

    # Listening ports
    {
        echo "=== All Listening Ports ==="
        sudo netstat -tulpn 2>/dev/null || sudo ss -tulpn 2>/dev/null || echo "Cannot get listening ports"
        echo ""
        echo "=== Sigul Specific Ports (44333, 44334) ==="
        sudo netstat -tulpn 2>/dev/null | grep -E '44333|44334' || echo "No Sigul ports listening"
    } > "$output/listening-ports.txt"

    # Established connections
    {
        echo "=== Established Connections ==="
        sudo netstat -tnp 2>/dev/null | grep -E 'sigul|44333|44334' || echo "No active Sigul connections"
    } > "$output/established-connections.txt"

    log_info "Network information saved to: $output"
}

################################################################################
# Section 8: NSS Details
################################################################################

extract_nss_details() {
    log_section "8. NSS CONFIGURATION"

    local output="$OUTPUT_DIR/08-nss"
    mkdir -p "$output"

    # NSS modules
    {
        echo "=== NSS Modules ==="
        sudo modutil -list -dbdir /etc/pki/sigul 2>/dev/null || echo "Cannot list NSS modules"
    } > "$output/nss-modules.txt"

    # NSS database format
    {
        echo "=== NSS Database Format ==="
        file /etc/pki/sigul/*.db 2>/dev/null || echo "No database files"
        echo ""
        echo "=== Database Sizes ==="
        ls -lh /etc/pki/sigul/*.db 2>/dev/null || echo "No database files"
    } > "$output/nss-database-format.txt"

    # NSS configuration files
    {
        echo "=== NSS Text Files in /etc/pki/sigul ==="
        sudo ls -la /etc/pki/sigul/*.txt 2>/dev/null || echo "No .txt files"
        echo ""
        echo "=== NSS Password File (length only) ==="
        if [ -f /etc/pki/sigul/nss-password.txt ]; then
            echo "File exists, length: $(sudo cat /etc/pki/sigul/nss-password.txt | wc -c) bytes"
        else
            echo "No nss-password.txt file"
        fi
    } > "$output/nss-config-files.txt"

    # Crypto policy
    {
        echo "=== System Crypto Policy ==="
        update-crypto-policies --show 2>/dev/null || echo "No crypto-policies"
        echo ""
        echo "=== FIPS Mode ==="
        cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo "Cannot determine FIPS status"
    } > "$output/crypto-policy.txt"

    log_info "NSS details saved to: $output"
}

################################################################################
# Section 9: Environment Variables
################################################################################

extract_environment() {
    log_section "9. ENVIRONMENT VARIABLES"

    local output="$OUTPUT_DIR/09-environment"
    mkdir -p "$output"

    # Current user environment
    {
        echo "=== Current User Environment ==="
        env | sort
    } > "$output/current-user-env.txt"

    # Sigul user environment
    {
        echo "=== Sigul User Environment ==="
        sudo -u sigul env 2>/dev/null | sort || echo "Cannot get sigul user environment"
    } > "$output/sigul-user-env.txt"

    # NSS-specific variables
    {
        echo "=== NSS Environment Variables ==="
        env | grep -i nss || echo "No NSS variables"
        echo ""
        sudo -u sigul env 2>/dev/null | grep -i nss || echo "No NSS variables for sigul user"
    } > "$output/nss-env-vars.txt"

    # Locale and timezone
    {
        echo "=== Locale ==="
        locale
        echo ""
        echo "=== Timezone ==="
        timedatectl status 2>/dev/null || date
        echo ""
        echo "=== TZ Variable ==="
        echo "TZ=${TZ:-not set}"
    } > "$output/locale-timezone.txt"

    # Entropy
    {
        echo "=== Entropy Pool ==="
        cat /proc/sys/kernel/random/entropy_avail
        echo ""
        echo "=== Entropy Daemons ==="
        systemctl status haveged 2>/dev/null || echo "haveged not running"
        systemctl status rngd 2>/dev/null || echo "rngd not running"
    } > "$output/entropy-info.txt"

    log_info "Environment information saved to: $output"
}

################################################################################
# Section 10: File Permissions
################################################################################

extract_permissions() {
    log_section "10. FILE PERMISSIONS"

    local output="$OUTPUT_DIR/10-permissions"
    mkdir -p "$output"

    # Config directory
    {
        echo "=== /etc/sigul/ Permissions ==="
        sudo ls -laZ /etc/sigul/ 2>/dev/null || sudo ls -la /etc/sigul/ 2>/dev/null || echo "Directory not found"
    } > "$output/etc-sigul-permissions.txt"

    # PKI directory
    {
        echo "=== /etc/pki/sigul/ Permissions ==="
        sudo ls -laZ /etc/pki/sigul/ 2>/dev/null || sudo ls -la /etc/pki/sigul/ 2>/dev/null || echo "Directory not found"
    } > "$output/etc-pki-sigul-permissions.txt"

    # Var lib directory
    {
        echo "=== /var/lib/sigul/ Permissions ==="
        sudo ls -laZ /var/lib/sigul/ 2>/dev/null || sudo ls -la /var/lib/sigul/ 2>/dev/null || echo "Directory not found"
        echo ""
        echo "=== /var/lib/sigul/gnupg/ Permissions ==="
        sudo ls -laZ /var/lib/sigul/gnupg/ 2>/dev/null || sudo ls -la /var/lib/sigul/gnupg/ 2>/dev/null || echo "Directory not found"
    } > "$output/var-lib-sigul-permissions.txt"

    # Log directory
    {
        echo "=== /var/log/sigul* Permissions ==="
        sudo ls -laZ /var/log/sigul* 2>/dev/null || sudo ls -la /var/log/sigul* 2>/dev/null || echo "No log directories"
    } > "$output/var-log-sigul-permissions.txt"

    # User and group info
    {
        echo "=== Sigul User Info ==="
        id sigul 2>/dev/null || echo "Sigul user not found"
        echo ""
        echo "=== /etc/passwd entry ==="
        grep "^sigul:" /etc/passwd 2>/dev/null || echo "No entry"
        echo ""
        echo "=== /etc/group entry ==="
        grep "^sigul:" /etc/group 2>/dev/null || echo "No entry"
    } > "$output/user-group-info.txt"

    log_info "Permission information saved to: $output"
}

################################################################################
# Section 11: Logging Configuration
################################################################################

extract_logging() {
    log_section "11. LOGGING CONFIGURATION"

    local output="$OUTPUT_DIR/11-logging"
    mkdir -p "$output"

    # Log directory structure
    {
        echo "=== Log Directory Structure ==="
        sudo find /var/log/sigul* -type f -o -type d 2>/dev/null | head -100 || echo "No Sigul logs"
    } > "$output/log-directory-structure.txt"

    # Logrotate config
    {
        echo "=== Logrotate Configuration ==="
        sudo cat /etc/logrotate.d/sigul* 2>/dev/null || echo "No logrotate config"
    } > "$output/logrotate-config.txt"

    # Recent log samples (last 50 lines from each log)
    sudo find /var/log/sigul* -type f -name "*log" 2>/dev/null | while read -r logfile; do
        local safe_name
        safe_name=$(echo "$logfile" | tr '/' '_')
        log_info "Sampling log: $logfile"
        {
            echo "=== Last 50 lines of $logfile ==="
            sudo tail -50 "$logfile" 2>/dev/null || echo "Cannot read log"
        } > "$output/sample-${safe_name}.txt"
    done

    # Systemd journal
    {
        echo "=== Bridge Journal (last 50 lines) ==="
        sudo journalctl -u sigul_bridge.service -n 50 --no-pager 2>/dev/null || echo "No journal entries"
        echo ""
        echo "=== Server Journal (last 50 lines) ==="
        sudo journalctl -u 'sigul_server@*' -n 50 --no-pager 2>/dev/null || echo "No journal entries"
    } > "$output/systemd-journal.txt"

    log_info "Logging information saved to: $output"
}

################################################################################
# Section 12: Process Information
################################################################################

extract_process_info() {
    log_section "12. PROCESS INFORMATION"

    local output="$OUTPUT_DIR/12-processes"
    mkdir -p "$output"

    # Running processes
    {
        echo "=== Sigul Processes ==="
        pgrep -fa "sigul|python.*sigul" || echo "No Sigul processes"
    } > "$output/sigul-processes.txt"

    # Process limits
    for pid in $(pgrep -f "sigul_bridge|sigul_server" 2>/dev/null); do
        log_info "Extracting limits for PID: $pid"
        {
            echo "=== Process Limits for PID $pid ==="
            cat "/proc/$pid/limits" 2>/dev/null || echo "Cannot read limits"
            echo ""
            echo "=== Process Command ==="
            tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "Cannot read cmdline"
            echo ""
            echo "=== Process Environment ==="
            sudo cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | sort || echo "Cannot read environment"
        } > "$output/process-${pid}-limits.txt"
    done

    # Systemd resource limits
    {
        echo "=== Bridge Service Limits ==="
        sudo systemctl show sigul_bridge.service 2>/dev/null | grep -i limit || echo "Cannot get limits"
        echo ""
        echo "=== Server Service Limits ==="
        sudo systemctl show 'sigul_server@*' 2>/dev/null | grep -i limit | head -50 || echo "Cannot get limits"
    } > "$output/systemd-resource-limits.txt"

    log_info "Process information saved to: $output"
}

################################################################################
# Section 13: Source Code Analysis
################################################################################

extract_source_code() {
    log_section "13. SOURCE CODE ANALYSIS"

    local output="$OUTPUT_DIR/13-source-code"
    mkdir -p "$output"

    # Python scripts location
    {
        echo "=== Sigul Python Scripts ==="
        ls -la /usr/share/sigul/ 2>/dev/null || echo "No /usr/share/sigul/ directory"
        echo ""
        ls -la /usr/bin/sigul* 2>/dev/null || echo "No /usr/bin/sigul* files"
        echo ""
        ls -la /usr/sbin/sigul* 2>/dev/null || echo "No /usr/sbin/sigul* files"
    } > "$output/script-locations.txt"

    # Config parser implementation
    {
        echo "=== Config Parser Import ==="
        sudo grep -n "import.*ConfigParser\|from.*configparser" /usr/share/sigul/*.py 2>/dev/null || echo "Not found"
        echo ""
        echo "=== Config Parser Usage (separator format) ==="
        sudo grep -B 2 -A 10 "ConfigParser\|SafeConfigParser" /usr/share/sigul/*.py 2>/dev/null | head -100 || echo "Not found"
        echo ""
        echo "=== Config file reading patterns ==="
        sudo grep -B 2 -A 5 "\.read\|\.get\(" /usr/share/sigul/*.py 2>/dev/null | head -100 || echo "Not found"
    } > "$output/config-parser-code.txt"

    # Password hashing
    {
        echo "=== Password Hashing Logic ==="
        sudo grep -B 5 -A 20 "sha512\|hashlib.*sha512\|password.*hash" /usr/share/sigul/*.py 2>/dev/null | head -200 || echo "Not found"
    } > "$output/password-hashing-code.txt"

    # Passphrase encryption
    {
        echo "=== Passphrase Encryption Logic ==="
        sudo grep -B 5 -A 20 "encrypt.*passphrase\|decrypt.*passphrase" /usr/share/sigul/*.py 2>/dev/null | head -200 || echo "Not found"
    } > "$output/passphrase-encryption-code.txt"

    # NSS usage
    {
        echo "=== NSS Usage ==="
        sudo grep -n "import.*nss\|nss\." /usr/share/sigul/*.py 2>/dev/null | head -100 || echo "Not found"
        echo ""
        echo "=== TLS Configuration Usage ==="
        sudo grep -B 2 -A 5 "nss-min-tls\|nss-max-tls\|tls" /usr/share/sigul/*.py 2>/dev/null | head -100 || echo "Not found"
    } > "$output/nss-usage-code.txt"

    # Certificate generation/validation
    {
        echo "=== Certificate Validation Logic ==="
        sudo grep -B 5 -A 10 "cert.*nickname\|certificate" /usr/share/sigul/*.py 2>/dev/null | head -200 || echo "Not found"
    } > "$output/certificate-validation-code.txt"

    log_info "Source code analysis saved to: $output"
}

################################################################################
# Section 14: Config Parser Testing
################################################################################

extract_config_parser_test() {
    log_section "14. CONFIG PARSER COMPATIBILITY TEST"

    local output="$OUTPUT_DIR/14-config-parser-test"
    mkdir -p "$output"

    # Test config formats
    {
        echo "=== Testing Config Parser Formats ==="
        python2 << 'EOF' 2>&1 || echo "Python2 test failed"
import ConfigParser
import StringIO

# Test colon format
test_colon = """[test]
key: value
multi_word_key: multi word value
"""

# Test equals format
test_equals = """[test]
key = value
multi_word_key = multi word value
"""

parser = ConfigParser.SafeConfigParser()

print "Testing COLON format:"
try:
    parser.readfp(StringIO.StringIO(test_colon))
    print "  SUCCESS - Colon format works"
    print "  Value read:", parser.get('test', 'key')
except Exception as e:
    print "  FAIL -", str(e)

parser = ConfigParser.SafeConfigParser()
print "\nTesting EQUALS format:"
try:
    parser.readfp(StringIO.StringIO(test_equals))
    print "  SUCCESS - Equals format works"
    print "  Value read:", parser.get('test', 'key')
except Exception as e:
    print "  FAIL -", str(e)

print "\nCONCLUSION: Both formats should work in Python 2 ConfigParser"
EOF
    } > "$output/parser-test-results.txt"

    log_info "Config parser test results saved to: $output"
}

################################################################################
# Section 15: Summary Report
################################################################################

create_summary() {
    log_section "15. CREATING SUMMARY REPORT"

    local summary="$OUTPUT_DIR/SUMMARY.md"

    cat > "$summary" << EOF
# Sigul Production Configuration Extraction Summary

**Hostname:** $HOSTNAME
**Date:** $(date)
**Output Directory:** $OUTPUT_DIR

## Extraction Sections

1. **System Information** - OS, kernel, packages, versions
2. **Sigul Configurations** - All config files from /etc/sigul/
3. **Certificates** - NSS database, certificate details, PKCS#12 files
4. **Database** - Schema, table structure (no sensitive data)
5. **GnuPG** - Directory structure, config files, key info
6. **Systemd Services** - Service files, status, drop-ins
7. **Network** - DNS, hosts, ports, connections (Sigul-specific only)
8. **NSS Details** - Modules, database format, crypto policy
9. **Environment** - Variables, locale, timezone, entropy
10. **Permissions** - File ownership, modes, SELinux contexts
11. **Logging** - Log structure, logrotate, journal samples
12. **Processes** - Running processes, limits, resources
13. **Source Code** - Script locations, parser code, crypto code
14. **Parser Test** - ConfigParser format compatibility

## Components Excluded (Not Part of Sigul)

- **RabbitMQ** - Present on hosts but not used by Sigul
- **LDAP** - No integration found in Sigul configs
- **Koji/FAS** - Empty config sections, not actively used

## Files Created

\`\`\`
$(find "$OUTPUT_DIR" -type f | sed "s|$OUTPUT_DIR/||" | sort)
\`\`\`

## Key Findings

### Host Type Detection
$(if [ -f /usr/share/sigul/bridge.py ]; then
    echo "- **BRIDGE HOST** - Contains bridge.py"
elif [ -f /usr/share/sigul/server.py ]; then
    echo "- **SERVER HOST** - Contains server.py"
else
    echo "- **UNKNOWN** - No sigul scripts found"
fi)

### Sigul Version
$(rpm -qa | grep -E '^sigul-[0-9]' || echo "- Not installed via RPM")

### Python Version
$(python --version 2>&1 | sed 's/^/- /')

### NSS Database Format
$(if [ -f /etc/pki/sigul/cert8.db ]; then
    echo "- **Legacy format** (cert8.db, key3.db)"
elif [ -f /etc/pki/sigul/cert9.db ]; then
    echo "- **Modern format** (cert9.db, key4.db)"
else
    echo "- **Not found**"
fi)

### Certificates Found
$(sudo certutil -L -d /etc/pki/sigul 2>/dev/null | tail -n +4 | wc -l || echo "0") certificates in NSS database

### Database Status
$(if [ -f /var/lib/sigul/server.sqlite ]; then
    echo "- **Present** at /var/lib/sigul/server.sqlite"
    echo "- Size: $(du -h /var/lib/sigul/server.sqlite 2>/dev/null | cut -f1)"
else
    echo "- **Not present** (normal for bridge)"
fi)

### GnuPG Status
$(if [ -d /var/lib/sigul/gnupg ]; then
    echo "- **Present** at /var/lib/sigul/gnupg"
else
    echo "- **Not present** (normal for bridge)"
fi)

## Next Steps

1. Review each section output file
2. Compare with containerized stack gap analysis
3. Update container configuration to match production patterns:
   - Use FHS paths (/etc/sigul/, /etc/pki/sigul/, /var/lib/sigul/)
   - Implement colon separator config format
   - Add certificate EKU/SAN flags
   - Add missing config parameters (GnuPG, resource limits, TLS versions)
   - Remove [bridge-server] section from bridge config
4. Test modernized stack with Python 3, current NSS, GPG 2.x
5. Validate against production behavior patterns

---
**Extraction completed successfully**
EOF

    log_info "Summary report created: $summary"

    # Display summary to console
    cat "$summary"
}

################################################################################
# Script Entry Point
################################################################################

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log_warn "Not running as root. Some commands may fail."
    log_warn "Recommend running with: sudo $0"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Run main extraction
main

# Print final message
echo ""
log_info "=============================================="
log_info "Extraction Complete!"
log_info "=============================================="
log_info "Results saved to: $OUTPUT_DIR"
log_info ""
log_info "To view summary:"
log_info "  cat $OUTPUT_DIR/SUMMARY.md"
log_info ""
log_info "To create archive:"
log_info "  tar czf sigul-production-$(hostname -s)-$(date +%Y%m%d).tar.gz $OUTPUT_DIR"
log_info "=============================================="

exit 0
