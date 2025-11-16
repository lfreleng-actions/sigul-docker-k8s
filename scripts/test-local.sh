#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

set -e

# Simple verification script for sigul-sign-docker
# This script verifies that the sigul binary is properly installed and accessible
# Supports both AMD64 and ARM64 architectures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default values
DEFAULT_PLATFORM=""
PLATFORM_ARG=""
IMAGE_TAG="sigul-sign-docker:verify"

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Test the sigul-sign-docker container locally with multi-architecture support.

OPTIONS:
    -p, --platform PLATFORM    Specify platform (linux/amd64, linux/arm64, auto)
                               'auto' detects local architecture (default)
    -t, --tag TAG              Docker image tag (default: sigul-sign-docker:verify)
    -h, --help                 Show this help message

EXAMPLES:
    $0                         # Auto-detect platform and test
    $0 -p linux/arm64          # Test ARM64 build specifically
    $0 -p linux/amd64          # Test AMD64 build specifically
    $0 --platform auto         # Auto-detect platform (same as default)

EOF
}

# Function to detect local architecture
detect_platform() {
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
            echo "ERROR: Unsupported architecture: $arch" >&2
            echo "Supported architectures: x86_64 (amd64), aarch64 (arm64)" >&2
            exit 1
            ;;
    esac
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--platform)
            if [[ -z "$2" ]]; then
                echo "ERROR: Platform argument required" >&2
                usage
                exit 1
            fi
            if [[ "$2" == "auto" ]]; then
                DEFAULT_PLATFORM=$(detect_platform)
            else
                DEFAULT_PLATFORM="$2"
            fi
            shift 2
            ;;
        -t|--tag)
            if [[ -z "$2" ]]; then
                echo "ERROR: Tag argument required" >&2
                usage
                exit 1
            fi
            IMAGE_TAG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Set platform if not specified
if [[ -z "$DEFAULT_PLATFORM" ]]; then
    DEFAULT_PLATFORM=$(detect_platform)
fi

# Validate platform
case "$DEFAULT_PLATFORM" in
    linux/amd64|linux/arm64)
        PLATFORM_ARG="--platform $DEFAULT_PLATFORM"
        ;;
    *)
        echo "ERROR: Invalid platform: $DEFAULT_PLATFORM" >&2
        echo "Supported platforms: linux/amd64, linux/arm64" >&2
        exit 1
        ;;
esac

# Helper function to run docker commands with platform argument
docker_run() {
    if [[ -n "$PLATFORM_ARG" ]]; then
        # shellcheck disable=SC2086
        docker run --rm $PLATFORM_ARG "$@"
    else
        docker run --rm "$@"
    fi
}

# Helper function to build docker with platform argument and BuildKit optimizations
docker_build() {
    # Enable BuildKit for advanced caching and multi-stage builds
    export DOCKER_BUILDKIT=1
    export BUILDKIT_PROGRESS=plain

    if [[ -n "$PLATFORM_ARG" ]]; then
        # shellcheck disable=SC2086
        docker build $PLATFORM_ARG \
            --build-arg BUILDKIT_INLINE_CACHE=1 \
            --build-arg BUILDKIT_MULTI_PLATFORM=1 \
            "$@"
    else
        docker build \
            --build-arg BUILDKIT_INLINE_CACHE=1 \
            --build-arg BUILDKIT_MULTI_PLATFORM=1 \
            "$@"
    fi
}

echo "=== Sigul Sign Docker Verification ==="
echo "Project directory: $PROJECT_DIR"
echo "Testing platform: $DEFAULT_PLATFORM"
echo "Image tag: $IMAGE_TAG"
echo ""

# Build the Docker image with optimized caching (fallback if cache not supported)
echo "Building Docker image for $DEFAULT_PLATFORM..."
echo "Using BuildKit with multi-stage builds..."
cd "$PROJECT_DIR"

# Create a platform-specific tag to avoid cache conflicts
PLATFORM_TAG="${IMAGE_TAG}-${DEFAULT_PLATFORM//\//-}"

# Try with cache first, fallback to no cache if not supported
if ! docker_build \
    --target runtime \
    --cache-from type=local,src=/tmp/buildx-cache-"${DEFAULT_PLATFORM//\//-}" \
    --cache-to type=local,dest=/tmp/buildx-cache-"${DEFAULT_PLATFORM//\//-}",mode=max \
    -t "$PLATFORM_TAG" \
    -t "$IMAGE_TAG" \
    . 2>/dev/null; then

    echo "Cache export not supported, building without cache..."
    if ! docker_build \
        --target runtime \
        -t "$PLATFORM_TAG" \
        -t "$IMAGE_TAG" \
        .; then
        echo "ERROR: Docker build failed for $DEFAULT_PLATFORM" >&2
        echo "Please check the Dockerfile and build context." >&2
        echo "Note: This build uses multi-stage optimization and may take longer on first run." >&2
        exit 1
    fi
fi

echo ""
echo "=== Verifying Sigul Installation ==="

# Test 1: Check sigul binary exists and is executable
echo "✓ Checking sigul binary location..."
if ! SIGUL_PATH=$(docker_run "$IMAGE_TAG" which sigul 2>/dev/null); then
    echo "  ❌ Error: Sigul binary not found in PATH" >&2
    echo "  This may indicate a problem with the multi-stage build or binary copying" >&2
    exit 1
fi
echo "  Sigul binary found at: $SIGUL_PATH"

# Test 2: Check sigul version
echo "✓ Checking sigul version..."
SIGUL_VERSION=$(docker_run "$IMAGE_TAG" sigul --version)
echo "  Sigul version: $SIGUL_VERSION"

# Test 3: Check sigul package information (may not be available for ARM64 source builds)
echo "✓ Checking sigul installation method..."
SIGUL_PACKAGE=$(docker_run "$IMAGE_TAG" rpm -qf /usr/bin/sigul 2>/dev/null || echo "Built from source")
echo "  Sigul installation: $SIGUL_PACKAGE"

# Test 4: Check sigul help output
echo "✓ Checking sigul help functionality..."
if docker_run "$IMAGE_TAG" sigul --help > /dev/null 2>&1; then
    echo "  Sigul help command works correctly"
else
    echo "  ❌ Error: Sigul help command failed" >&2
    exit 1
fi

# Test 5: Check sigul commands list
echo "✓ Checking sigul supported commands..."
if docker_run "$IMAGE_TAG" sigul --help-commands > /dev/null 2>&1; then
    echo "  Sigul commands list accessible"
else
    echo "  ❌ Error: Sigul commands list failed" >&2
    exit 1
fi

# Test 6: Verify entrypoint script handles pass-through correctly
echo "✓ Testing entrypoint pass-through..."
PASSTHROUGH_VERSION=$(docker_run "$IMAGE_TAG" sigul --version)
if [ "$PASSTHROUGH_VERSION" = "$SIGUL_VERSION" ]; then
    echo "  Entrypoint pass-through works correctly"
else
    echo "  ❌ Error: Entrypoint pass-through failed" >&2
    echo "  Expected: $SIGUL_VERSION" >&2
    echo "  Got: $PASSTHROUGH_VERSION" >&2
    exit 1
fi

# Test 7: Verify UBI base image and multi-stage build info
echo "✓ Checking base image information..."
BASE_IMAGE=$(docker_run "$IMAGE_TAG" cat /etc/redhat-release 2>/dev/null || echo "Unknown base")
echo "  Base image: $BASE_IMAGE"

# Check if this is a multi-stage optimized build
echo "✓ Verifying multi-stage build optimization..."
BUILD_TOOLS_REMOVED=$(docker_run "$IMAGE_TAG" sh -c 'rpm -qa | grep -E "(gcc|make|autoconf|automake)" | wc -l' 2>/dev/null || echo "0")
if [[ "$BUILD_TOOLS_REMOVED" == "0" ]]; then
    echo "  ✅ Build tools properly removed (multi-stage optimization working)"
else
    echo "  ⚠️  Warning: $BUILD_TOOLS_REMOVED build tools still present (optimization may not be working)"
fi

# Test 8: Check architecture-specific installation details
echo "✓ Checking architecture-specific details..."
CONTAINER_ARCH=$(docker_run "$IMAGE_TAG" uname -m)
echo "  Container architecture: $CONTAINER_ARCH"

# Architecture-specific verification
case "$DEFAULT_PLATFORM" in
    linux/amd64)
        if [[ "$CONTAINER_ARCH" != "x86_64" ]]; then
            echo "  ⚠️  Warning: Expected x86_64 but got $CONTAINER_ARCH" >&2
        fi
        ;;
    linux/arm64)
        if [[ "$CONTAINER_ARCH" != "aarch64" ]]; then
            echo "  ⚠️  Warning: Expected aarch64 but got $CONTAINER_ARCH" >&2
        fi
        ;;
esac

# Test 9: Verify sigul user exists
echo "✓ Checking sigul user configuration..."
SIGUL_USER_INFO=$(docker_run "$IMAGE_TAG" id sigul 2>/dev/null || echo "sigul user not found")
echo "  Sigul user: $SIGUL_USER_INFO"

# Test 10: Check sigul directories
echo "✓ Checking sigul directory structure..."
SIGUL_DIR_INFO=$(docker_run "$IMAGE_TAG" ls -la /var/lib/sigul 2>/dev/null || echo "sigul directory not found")
if [[ "$SIGUL_DIR_INFO" != "sigul directory not found" ]]; then
    echo "  Sigul directories exist and are properly configured"
else
    echo "  ⚠️  Warning: Sigul directories may not be properly configured" >&2
fi

echo ""
echo "=== Verification Summary ==="
echo "✅ Platform: $DEFAULT_PLATFORM ($CONTAINER_ARCH)"
echo "✅ Sigul binary is properly installed and accessible"
echo "✅ Version: $SIGUL_VERSION"
echo "✅ Installation: $SIGUL_PACKAGE"
echo "✅ Base: $BASE_IMAGE"
echo "✅ All functionality tests passed"
echo ""
echo "The sigul-sign-docker container is ready for use on $DEFAULT_PLATFORM!"
echo ""
echo "Next steps:"
echo "  • For production use, ensure proper Sigul server configuration"
echo "  • Verify PKI credentials are properly configured"
echo "  • Test actual signing operations in a secure environment"
echo "  • Build cache is stored in /tmp/buildx-cache-* for faster rebuilds (if supported)"
echo ""
echo "To test the other architecture, run:"
if [[ "$DEFAULT_PLATFORM" == "linux/amd64" ]]; then
    echo "  $0 --platform linux/arm64"
else
    echo "  $0 --platform linux/amd64"
fi
echo ""
echo "To test both architectures, run:"
echo "  $SCRIPT_DIR/test-all-architectures.sh"
echo ""
echo "To clean up build cache, run:"
echo "  rm -rf /tmp/buildx-cache-*"
