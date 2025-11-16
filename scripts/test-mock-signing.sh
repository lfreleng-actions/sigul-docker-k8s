#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

set -euo pipefail

# Test helper script for validating mock signing functionality
# This script provides an easy way to test the mock signing container locally

readonly SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Function to validate mock signature output
validate_mock_signature() {
    local output="$1"
    local expected_file="$2"
    local expected_type="$3"

    if ! echo "$output" | grep -q "SIGUL_MOCK_SIGNATURE_START"; then
        error "Mock signature start marker not found"
    fi

    if ! echo "$output" | grep -q "SIGUL_MOCK_SIGNATURE_END"; then
        error "Mock signature end marker not found"
    fi

    if ! echo "$output" | grep -q "FILE: $expected_file"; then
        error "Expected file '$expected_file' not found in signature"
    fi

    if ! echo "$output" | grep -q "TYPE: $expected_type"; then
        error "Expected type '$expected_type' not found in signature"
    fi

    if ! echo "$output" | grep -q "-----BEGIN PGP SIGNATURE-----"; then
        error "PGP signature block not found"
    fi

    if ! echo "$output" | grep -q "-----END PGP SIGNATURE-----"; then
        error "PGP signature end block not found"
    fi

    log "✅ Mock signature validation passed for $expected_file"
}

# Test single file signing
test_single_file() {
    log "Testing single file mock signing..."

    local test_dir="$PROJECT_DIR/test-workspace"
    mkdir -p "$test_dir/files"
    echo "Test content for single file" > "$test_dir/files/test-single.txt"

    local output
    output=$(docker run --rm \
        -v "$test_dir:/workspace" \
        -w /workspace \
        -e SIGN_TYPE=sign-data \
        -e SIGN_OBJECT=files/test-single.txt \
        -e SIGUL_KEY_NAME=test-key \
        -e SIGUL_MOCK_MODE=true \
        sigul-client:latest 2>&1)

    echo "Container output:"
    echo "$output"
    echo

    validate_mock_signature "$output" "files/test-single.txt" "sign-data"
    log "Single file test completed successfully"
}

# Test wildcard signing
test_wildcard() {
    log "Testing wildcard mock signing..."

    local test_dir="$PROJECT_DIR/test-workspace"
    mkdir -p "$test_dir/files"
    echo "File 1" > "$test_dir/files/file1.txt"
    echo "File 2" > "$test_dir/files/file2.txt"
    echo "Binary data" > "$test_dir/files/data.bin"

    local output
    output=$(docker run --rm \
        -v "$test_dir:/workspace" \
        -w /workspace \
        -e SIGN_TYPE=sign-data \
        -e SIGN_OBJECT='files/*.txt' \
        -e SIGUL_KEY_NAME=test-key \
        -e SIGUL_MOCK_MODE=true \
        sigul-client:latest 2>&1)

    echo "Container output:"
    echo "$output"
    echo

    # Should have signatures for both .txt files but not .bin
    if echo "$output" | grep -q "FILE: files/file1.txt"; then
        log "✅ Found signature for file1.txt"
    else
        error "Missing signature for file1.txt"
    fi

    if echo "$output" | grep -q "FILE: files/file2.txt"; then
        log "✅ Found signature for file2.txt"
    else
        error "Missing signature for file2.txt"
    fi

    if echo "$output" | grep -q "FILE: files/data.bin"; then
        error "Unexpected signature for data.bin (should not match *.txt pattern)"
    else
        log "✅ Correctly excluded data.bin from *.txt pattern"
    fi

    log "Wildcard test completed successfully"
}

# Test git tag signing
test_git_tag() {
    log "Testing git tag mock signing..."

    local test_dir="$PROJECT_DIR/test-workspace/git-repo"
    mkdir -p "$test_dir"
    cd "$test_dir"

    # Create minimal git repo
    git init >/dev/null 2>&1
    git config user.name "Test User"
    git config user.email "test@example.com"
    echo "test repo" > README.md
    git add README.md >/dev/null 2>&1
    git commit -m "Initial commit" >/dev/null 2>&1
    git tag v1.0.0-test

    local output
    output=$(docker run --rm \
        -v "$test_dir:/workspace" \
        -w /workspace \
        -e SIGN_TYPE=sign-git-tag \
        -e SIGN_OBJECT=v1.0.0-test \
        -e SIGUL_KEY_NAME=test-key \
        -e SIGUL_MOCK_MODE=true \
        sigul-client:latest 2>&1)

    echo "Container output:"
    echo "$output"
    echo

    validate_mock_signature "$output" "v1.0.0-test" "sign-git-tag"
    log "Git tag test completed successfully"

    cd "$PROJECT_DIR"
}

# Test error handling
test_error_handling() {
    log "Testing error handling..."

    local test_dir="$PROJECT_DIR/test-workspace"
    mkdir -p "$test_dir"

    # Test missing file
    log "Testing missing file handling..."
    if docker run --rm \
        -v "$test_dir:/workspace" \
        -w /workspace \
        -e SIGN_TYPE=sign-data \
        -e SIGN_OBJECT=nonexistent.txt \
        -e SIGUL_KEY_NAME=test-key \
        -e SIGUL_MOCK_MODE=true \
        sigul-client:latest >/dev/null 2>&1; then
        error "Should have failed for missing file"
    else
        log "✅ Correctly handled missing file"
    fi

    # Test missing SIGN_TYPE
    log "Testing missing SIGN_TYPE handling..."
    if docker run --rm \
        -v "$test_dir:/workspace" \
        -w /workspace \
        -e SIGN_OBJECT=files/test.txt \
        -e SIGUL_KEY_NAME=test-key \
        -e SIGUL_MOCK_MODE=true \
        sigul-client:latest >/dev/null 2>&1; then
        error "Should have failed for missing SIGN_TYPE"
    else
        log "✅ Correctly handled missing SIGN_TYPE"
    fi

    log "Error handling tests completed successfully"
}

# Clean up test workspace
cleanup() {
    log "Cleaning up test workspace..."
    rm -rf "$PROJECT_DIR/test-workspace"
    log "Cleanup completed"
}

# Main execution
main() {
    log "Starting mock signing tests..."

    # Check if Docker image exists
    if ! docker image inspect sigul-client:latest >/dev/null 2>&1; then
        error "Docker image 'sigul-client:latest' not found. Please build it first."
    fi

    # Create test workspace
    mkdir -p "$PROJECT_DIR/test-workspace"

    # Run tests
    test_single_file
    echo
    test_wildcard
    echo
    test_git_tag
    echo
    test_error_handling
    echo

    cleanup

    log "🎉 All mock signing tests passed successfully!"
}

# Handle script termination
trap cleanup EXIT

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
