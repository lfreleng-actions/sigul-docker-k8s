#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# BATS Test Setup Helper for Sigul Shell Functions
#
# This file provides common setup and helper functions for BATS tests
# of Sigul shell functions. It sets up test environments and provides
# utilities for mocking dependencies and validating outputs.

# Set up test environment
setup_test_env() {
    # Create temporary test directory
    export BATS_TEST_TMPDIR="${BATS_TMPDIR}/sigul-test-$$"
    mkdir -p "$BATS_TEST_TMPDIR"

    # Set up mock SIGUL_BASE_DIR
    export SIGUL_BASE_DIR="$BATS_TEST_TMPDIR/var/sigul"
    export PROJECT_ROOT="$BATS_TEST_TMPDIR/project"

    # Create required directory structure
    mkdir -p "$SIGUL_BASE_DIR"/{config,logs,pids,secrets,nss,database,gnupg,tmp}
    mkdir -p "$SIGUL_BASE_DIR/secrets/certificates"
    mkdir -p "$SIGUL_BASE_DIR/nss"/{server,bridge,client}
    mkdir -p "$SIGUL_BASE_DIR/logs"/{server,bridge,client}
    mkdir -p "$PROJECT_ROOT/test-artifacts"

    # Set required environment variables for tests
    export DEBUG="false"
    export SIGUL_ROLE="test"
    export NSS_PASSWORD="test-password"

    # Mock paths for dependencies
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
}

# Clean up test environment
teardown_test_env() {
    if [[ -d "$BATS_TEST_TMPDIR" ]]; then
        rm -rf "$BATS_TEST_TMPDIR"
    fi
}

# Create mock executable
# Arguments:
#   $1 - Command name
#   $2 - Exit code (default: 0)
#   $3 - Output content (optional)
create_mock_command() {
    local cmd_name="$1"
    local exit_code="${2:-0}"
    local output_content="$3"

    local mock_script="$BATS_TEST_TMPDIR/bin/$cmd_name"

    cat > "$mock_script" << EOF
#!/bin/bash
# Mock $cmd_name for testing
if [[ -n "$output_content" ]]; then
    echo "$output_content"
fi
exit $exit_code
EOF

    chmod +x "$mock_script"
}

# Create mock certificate file
# Arguments:
#   $1 - Certificate path
#   $2 - Content type (valid|expired|invalid)
create_mock_certificate() {
    local cert_path="$1"
    local content_type="${2:-valid}"

    mkdir -p "$(dirname "$cert_path")"

    case "$content_type" in
        "valid")
            cat > "$cert_path" << 'EOF'
-----BEGIN CERTIFICATE-----
MIICdTCCAd4CCQDMockCertificateValidForTesting1234567890ABCDEF
Valid mock certificate for testing purposes
Not a real certificate - for testing only
-----END CERTIFICATE-----
EOF
            ;;
        "expired")
            cat > "$cert_path" << 'EOF'
-----BEGIN CERTIFICATE-----
MIICdTCCAd4CCQDMockCertificateExpiredForTesting1234567890ABCDEF
Expired mock certificate for testing purposes
Not a real certificate - for testing only
-----END CERTIFICATE-----
EOF
            ;;
        "invalid")
            echo "Invalid certificate content" > "$cert_path"
            ;;
    esac
}

# Create mock NSS database files
# Arguments:
#   $1 - NSS directory path
#   $2 - Database type (valid|empty|missing)
create_mock_nss_database() {
    local nss_dir="$1"
    local db_type="${2:-valid}"

    mkdir -p "$nss_dir"

    case "$db_type" in
        "valid")
            # Create mock NSS database files
            echo "mock cert db content" > "$nss_dir/cert9.db"
            echo "mock key db content" > "$nss_dir/key4.db"
            echo "mock pkcs11 content" > "$nss_dir/pkcs11.txt"
            chmod 600 "$nss_dir"/*
            ;;
        "empty")
            # Create empty files
            touch "$nss_dir/cert9.db" "$nss_dir/key4.db" "$nss_dir/pkcs11.txt"
            chmod 600 "$nss_dir"/*
            ;;
        "missing")
            # Don't create files (they're missing)
            ;;
    esac
}

# Create mock NSS password file
# Arguments:
#   $1 - Password content (optional, defaults to "test-password")
create_mock_nss_password() {
    local password="${1:-test-password}"
    local password_file="$SIGUL_BASE_DIR/secrets/nss_password"

    mkdir -p "$(dirname "$password_file")"
    echo "$password" > "$password_file"
    chmod 600 "$password_file"
}

# Create mock certutil command
# Arguments:
#   $1 - Operation type (list-certs|list-keys|create-db)
#   $2 - Expected certificates/keys (space-separated)
create_mock_certutil() {
    # local operation="$1" - removed unused variable
    local expected_items="$2"

    local mock_certutil="$BATS_TEST_TMPDIR/bin/certutil"

    cat > "$mock_certutil" << EOF
#!/bin/bash
# Mock certutil for testing

case "\$1" in
    "-L")  # List certificates
        echo "Certificate Nickname                                         Trust Attributes"
        echo ""
        for item in $expected_items; do
            echo "\$item                                                  u,u,u"
        done
        ;;
    "-K")  # List private keys
        echo ""
        for item in $expected_items; do
            echo "< 0> rsa      mock-key-id    \$item"
        done
        ;;
    "-N")  # Create new database
        echo "Database created successfully"
        ;;
    "-A")  # Add certificate
        echo "Certificate added successfully"
        ;;
    *)
        echo "Mock certutil: unknown option \$1"
        exit 1
        ;;
esac
EOF

    chmod +x "$mock_certutil"
}

# Create mock openssl command
# Arguments:
#   $1 - Validation result (valid|expired|invalid)
create_mock_openssl() {
    local validation_result="$1"

    local mock_openssl="$BATS_TEST_TMPDIR/bin/openssl"

    cat > "$mock_openssl" << EOF
#!/bin/bash
# Mock openssl for testing

case "\$1" in
    "x509")
        if [[ "\$3" == "-checkend" ]]; then
            case "$validation_result" in
                "valid")
                    echo "Certificate will not expire"
                    exit 0
                    ;;
                "expired")
                    echo "Certificate will expire"
                    exit 1
                    ;;
                "invalid")
                    echo "unable to load certificate"
                    exit 1
                    ;;
            esac
        elif [[ "\$3" == "-dates" ]]; then
            echo "notBefore=Jan  1 00:00:00 2025 GMT"
            echo "notAfter=Dec 31 23:59:59 2025 GMT"
        elif [[ "\$3" == "-subject" ]]; then
            echo "subject=CN=Mock Certificate"
        fi
        ;;
    "dgst")
        echo "mock-sha256-hash"
        ;;
    *)
        echo "Mock openssl: unknown command \$1"
        exit 1
        ;;
esac
EOF

    chmod +x "$mock_openssl"
}

# Create mock jq command
create_mock_jq() {
    local mock_jq="$BATS_TEST_TMPDIR/bin/jq"

    cat > "$mock_jq" << 'EOF'
#!/bin/bash
# Mock jq for testing - very basic JSON processing

# Simple implementation for basic test cases
if [[ "$1" == "-n" ]]; then
    shift
    # Create JSON object from arguments
    echo "{}"
elif [[ "$1" == "." ]]; then
    # Pass through input
    cat
elif [[ "$1" == "-r" ]]; then
    # Raw output mode
    shift
    case "$1" in
        ".status")
            echo "running"
            ;;
        ".healthStatus")
            echo "healthy"
            ;;
        *)
            echo "mock-value"
            ;;
    esac
else
    # Default: return empty JSON
    echo "{}"
fi
EOF

    chmod +x "$mock_jq"
}

# Verify function output contains expected content
# Arguments:
#   $1 - Expected content
#   $2 - Actual output
assert_output_contains() {
    local expected="$1"
    local actual="$2"

    if [[ "$actual" != *"$expected"* ]]; then
        echo "Expected output to contain: $expected"
        echo "Actual output: $actual"
        return 1
    fi
}

# Verify JSON output has expected structure
# Arguments:
#   $1 - JSON output
#   $2 - Expected key
assert_json_has_key() {
    local json_output="$1"
    local expected_key="$2"

    # Simple check for key existence in JSON
    if [[ "$json_output" != *"\"$expected_key\""* ]]; then
        echo "Expected JSON to have key: $expected_key"
        echo "Actual JSON: $json_output"
        return 1
    fi
}

# Verify file exists and has expected permissions
# Arguments:
#   $1 - File path
#   $2 - Expected permissions (e.g., "644", "600")
assert_file_permissions() {
    local file_path="$1"
    local expected_perms="$2"

    if [[ ! -f "$file_path" ]]; then
        echo "Expected file to exist: $file_path"
        return 1
    fi

    local actual_perms
    actual_perms=$(stat -c%a "$file_path" 2>/dev/null || echo "unknown")

    if [[ "$actual_perms" != "$expected_perms" ]]; then
        echo "Expected permissions $expected_perms, got $actual_perms for $file_path"
        return 1
    fi
}

# Load function under test
# Arguments:
#   $1 - Script path relative to project root
load_function_under_test() {
    local script_path="$1"
    local full_path="$BATS_TEST_DIRNAME/../$script_path"

    if [[ ! -f "$full_path" ]]; then
        echo "Test script not found: $full_path"
        return 1
    fi

    # Source the script to load functions
    # shellcheck disable=SC1090
    source "$full_path"
}
