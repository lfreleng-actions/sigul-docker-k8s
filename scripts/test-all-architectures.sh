#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Comprehensive multi-architecture test script for sigul-sign-docker
# Tests both AMD64 and ARM64 builds with detailed reporting

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_SCRIPT="$SCRIPT_DIR/test-local.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
PLATFORMS=("linux/amd64" "linux/arm64")
RESULTS=()
FAILED_PLATFORMS=()
SKIPPED_PLATFORMS=()

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

print_header() {
    echo ""
    print_status "$BLUE" "========================================"
    print_status "$BLUE" "$1"
    print_status "$BLUE" "========================================"
    echo ""
}

print_section() {
    echo ""
    print_status "$YELLOW" "--- $1 ---"
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Test sigul-sign-docker container on all supported architectures.

OPTIONS:
    --platforms PLATFORMS      Comma-separated list of platforms to test
                               (default: linux/amd64,linux/arm64)
    --continue-on-error        Continue testing other platforms even if one fails
    --cleanup                  Clean up Docker images after testing
    --verbose                  Enable verbose output
    -h, --help                 Show this help message

EXAMPLES:
    $0                              # Test all platforms
    $0 --platforms linux/amd64     # Test only AMD64
    $0 --continue-on-error          # Test all, don't stop on failures
    $0 --cleanup --verbose          # Test all with cleanup and verbose output

EOF
}

# Parse command line arguments
CONTINUE_ON_ERROR=false
CLEANUP=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --platforms)
            if [[ -z "$2" ]]; then
                print_status "$RED" "ERROR: Platforms argument required"
                usage
                exit 1
            fi
            IFS=',' read -ra PLATFORMS <<< "$2"
            shift 2
            ;;
        --continue-on-error)
            CONTINUE_ON_ERROR=true
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_status "$RED" "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Function to check if Docker supports buildx
check_buildx() {
    if ! docker buildx version >/dev/null 2>&1; then
        print_status "$YELLOW" "Warning: Docker buildx not available"
        print_status "$YELLOW" "Multi-platform builds and advanced caching will not work properly"
        return 1
    fi

    # Enable BuildKit
    export DOCKER_BUILDKIT=1
    export BUILDKIT_PROGRESS=plain

    print_status "$GREEN" "Docker BuildKit enabled with multi-stage build support"
    return 0
}

# Function to check platform availability
check_platform_support() {
    local platform=$1

    # Try to inspect a simple image for the platform
    if docker manifest inspect --verbose alpine:latest 2>/dev/null | grep -q "$platform"; then
        return 0
    fi

    # Fallback: try to run a simple container
    if docker run --rm --platform "$platform" alpine:latest echo "test" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Function to get local architecture
get_local_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "linux/amd64"
            ;;
        aarch64|arm64)
            echo "linux/arm64"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Function to test a single platform
test_platform() {
    local platform=$1
    local platform_name="${platform//\//-}"
    local start_time
    local end_time
    local duration

    start_time=$(date +%s)

    print_section "Testing $platform"

    # Check if we can test this platform
    if ! check_platform_support "$platform"; then
        print_status "$YELLOW" "⚠️  Platform $platform not supported on this system"
        SKIPPED_PLATFORMS+=("$platform")
        RESULTS+=("$platform: SKIPPED (not supported)")
        return 0
    fi

    print_status "$BLUE" "Starting test for $platform..."
    print_status "$BLUE" "Using BuildKit with multi-stage builds and optimized caching..."

    # Create cache directory for this platform
    mkdir -p "/tmp/buildx-cache-$platform_name"

    # Run the test script with appropriate flags
    local test_args=(--platform "$platform" --tag "sigul-sign-docker:test-$platform_name")

    if [[ "$VERBOSE" == "true" ]]; then
        if "$TEST_SCRIPT" "${test_args[@]}"; then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            print_status "$GREEN" "✅ $platform test PASSED (${duration}s)"
            RESULTS+=("$platform: PASSED (${duration}s)")
            return 0
        else
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            print_status "$RED" "❌ $platform test FAILED (${duration}s)"
            FAILED_PLATFORMS+=("$platform")
            RESULTS+=("$platform: FAILED (${duration}s)")
            return 1
        fi
    else
        # Capture output and only show on failure or if verbose
        local output
        if output=$("$TEST_SCRIPT" "${test_args[@]}" 2>&1); then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            print_status "$GREEN" "✅ $platform test PASSED (${duration}s)"
            RESULTS+=("$platform: PASSED (${duration}s)")
            return 0
        else
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            print_status "$RED" "❌ $platform test FAILED (${duration}s)"
            print_status "$RED" "Error output:"
            echo "$output"
            FAILED_PLATFORMS+=("$platform")
            RESULTS+=("$platform: FAILED (${duration}s)")
            return 1
        fi
    fi
}

# Function to cleanup Docker images
cleanup_images() {
    print_section "Cleaning up Docker images and build cache"

    local cleaned=0
    for platform in "${PLATFORMS[@]}"; do
        local platform_name="${platform//\//-}"
        local image_tag="sigul-sign-docker:test-$platform_name"

        if docker image inspect "$image_tag" >/dev/null 2>&1; then
            print_status "$BLUE" "Removing $image_tag..."
            docker rmi "$image_tag" >/dev/null 2>&1 || true
            ((cleaned++))
        fi

        # Clean up platform-specific cache
        if [[ -d "/tmp/buildx-cache-$platform_name" ]]; then
            print_status "$BLUE" "Removing build cache for $platform_name..."
            rm -rf "/tmp/buildx-cache-$platform_name" || true
            ((cleaned++))
        fi
    done

    # Also clean up the default verify tag
    if docker image inspect "sigul-sign-docker:verify" >/dev/null 2>&1; then
        print_status "$BLUE" "Removing sigul-sign-docker:verify..."
        docker rmi "sigul-sign-docker:verify" >/dev/null 2>&1 || true
        ((cleaned++))
    fi

    # Clean up any remaining buildx cache
    if [[ -d "/tmp/buildx-cache-linux-amd64" || -d "/tmp/buildx-cache-linux-arm64" ]]; then
        print_status "$BLUE" "Removing remaining build cache directories..."
        rm -rf /tmp/buildx-cache-linux-* 2>/dev/null || true
    fi

    if [[ $cleaned -gt 0 ]]; then
        print_status "$GREEN" "Cleaned up $cleaned Docker images/caches"
    else
        print_status "$BLUE" "No images or caches to clean up"
    fi
}

# Function to display final summary
display_summary() {
    local total_platforms=${#PLATFORMS[@]}
    local passed_platforms=$((total_platforms - ${#FAILED_PLATFORMS[@]} - ${#SKIPPED_PLATFORMS[@]}))
    local failed_platforms=${#FAILED_PLATFORMS[@]}
    local skipped_platforms=${#SKIPPED_PLATFORMS[@]}

    print_header "TEST SUMMARY"

    print_status "$BLUE" "Total platforms tested: $total_platforms"
    print_status "$GREEN" "Passed: $passed_platforms"
    print_status "$RED" "Failed: $failed_platforms"
    print_status "$YELLOW" "Skipped: $skipped_platforms"

    echo ""
    print_status "$BLUE" "Detailed results:"
    for result in "${RESULTS[@]}"; do
        if [[ "$result" == *"PASSED"* ]]; then
            print_status "$GREEN" "  ✅ $result"
        elif [[ "$result" == *"FAILED"* ]]; then
            print_status "$RED" "  ❌ $result"
        elif [[ "$result" == *"SKIPPED"* ]]; then
            print_status "$YELLOW" "  ⚠️  $result"
        fi
    done

    if [[ ${#FAILED_PLATFORMS[@]} -eq 0 && ${#SKIPPED_PLATFORMS[@]} -lt ${#PLATFORMS[@]} ]]; then
        echo ""
        print_status "$GREEN" "🎉 All supported platforms passed!"
        return 0
    elif [[ ${#FAILED_PLATFORMS[@]} -gt 0 ]]; then
        echo ""
        print_status "$RED" "❌ Some platforms failed:"
        for platform in "${FAILED_PLATFORMS[@]}"; do
            print_status "$RED" "  - $platform"
        done
        return 1
    else
        echo ""
        print_status "$YELLOW" "⚠️  All platforms were skipped (not supported on this system)"
        return 2
    fi
}

# Main execution
main() {
    local local_arch
    local_arch=$(get_local_arch)

    print_header "Multi-Architecture Docker Test"

    print_status "$BLUE" "Project directory: $PROJECT_DIR"
    print_status "$BLUE" "Local architecture: $local_arch"
    print_status "$BLUE" "Platforms to test: ${PLATFORMS[*]}"
    print_status "$BLUE" "Continue on error: $CONTINUE_ON_ERROR"
    print_status "$BLUE" "Cleanup after test: $CLEANUP"
    print_status "$BLUE" "Verbose output: $VERBOSE"
    print_status "$BLUE" "Build optimization: Multi-stage builds with BuildKit caching enabled"

    # Check prerequisites
    print_section "Checking prerequisites"

    if [[ ! -f "$TEST_SCRIPT" ]]; then
        print_status "$RED" "ERROR: Test script not found at $TEST_SCRIPT"
        exit 1
    fi

    if ! docker --version >/dev/null 2>&1; then
        print_status "$RED" "ERROR: Docker not found or not running"
        exit 1
    fi

    if ! check_buildx; then
        print_status "$YELLOW" "Warning: Docker buildx not available - builds will be slower"
        print_status "$YELLOW" "Consider upgrading Docker to get BuildKit and caching benefits"
    fi

    print_status "$GREEN" "Prerequisites check passed"

    # Test each platform
    local overall_success=true

    for platform in "${PLATFORMS[@]}"; do
        if ! test_platform "$platform"; then
            if [[ "$CONTINUE_ON_ERROR" == "false" ]]; then
                print_status "$RED" "Stopping due to failure (use --continue-on-error to continue)"
                overall_success=false
                break
            else
                overall_success=false
            fi
        fi
    done

    # Cleanup if requested
    if [[ "$CLEANUP" == "true" ]]; then
        cleanup_images
    fi

    # Display final summary
    display_summary

    # Exit with appropriate code
    if [[ "$overall_success" == "true" ]]; then
        exit 0
    else
        exit 1
    fi
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
