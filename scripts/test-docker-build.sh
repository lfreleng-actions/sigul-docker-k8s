#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation

# Test script for Docker builds with network resilience validation
# This script tests all Docker builds and validates network connectivity handling

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
    echo -e "${BLUE}=== $* ===${NC}"
}

# Configuration
COMPONENTS=("client" "server" "bridge")
PLATFORMS=("linux/amd64" "linux/arm64")
BUILD_TIMEOUT=600  # 10 minutes
TEST_TIMEOUT=120   # 2 minutes
CLEANUP=${CLEANUP:-true}

# Global variables
FAILED_BUILDS=()
SUCCESSFUL_BUILDS=()
SKIPPED_BUILDS=()

# Cleanup function
cleanup() {
    if [[ "${CLEANUP}" == "true" ]]; then
        log_info "Cleaning up test images..."
        docker images --filter "reference=sigul-test-*" -q | xargs -r docker rmi -f || true
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites"

    # Check Docker
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi

    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    # Check buildx
    if ! docker buildx version >/dev/null 2>&1; then
        log_error "Docker buildx is not available"
        exit 1
    fi

    # Check project structure
    if [[ ! -d "${PROJECT_ROOT}/build-scripts" ]]; then
        log_error "build-scripts directory not found"
        exit 1
    fi

    local missing_files=()
    for component in "${COMPONENTS[@]}"; do
        if [[ ! -f "${PROJECT_ROOT}/Dockerfile.${component}" ]]; then
            missing_files+=("Dockerfile.${component}")
        fi
    done

    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log_error "Missing Dockerfile(s): ${missing_files[*]}"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Test network connectivity to required repositories
test_network_connectivity() {
    log_step "Testing network connectivity to required repositories"

    local urls=(
        "https://dl.fedoraproject.org/pub/epel/"
        "https://download.fedoraproject.org/pub/epel/"
        "https://kojipkgs.fedoraproject.org/repos-dist/epel9-infra/"
        "https://github.com/ModeSevenIndustrialSolutions/sigul"
        "https://github.com/ModeSevenIndustrialSolutions/python-nss"
    )

    local failed_urls=()

    for url in "${urls[@]}"; do
        log_info "Testing connectivity to: ${url}"
        if timeout 10 curl -s --head "${url}" >/dev/null 2>&1; then
            log_success "✓ ${url}"
        else
            log_warning "✗ ${url} (may cause build issues)"
            failed_urls+=("${url}")
        fi
    done

    if [[ ${#failed_urls[@]} -gt 0 ]]; then
        log_warning "Some URLs are not accessible: ${failed_urls[*]}"
        log_warning "Builds may use fallback mirrors or fail"
    else
        log_success "All repository URLs are accessible"
    fi
}

# Build a single component
build_component() {
    local component="$1"
    local platform="$2"
    local dockerfile="Dockerfile.${component}"
    local image_tag
    image_tag="sigul-test-${component}:${platform//\//-}-$(date +%s)"

    log_info "Building ${component} for ${platform}"

    # Change to project root for build context
    cd "${PROJECT_ROOT}"

    local build_cmd=(
        docker buildx build
        --platform "${platform}"
        --file "${dockerfile}"
        --tag "${image_tag}"
        --load
        --progress=plain
        .
    )

    log_info "Build command: ${build_cmd[*]}"

    # Run build with timeout
    if timeout "${BUILD_TIMEOUT}" "${build_cmd[@]}"; then
        log_success "Build successful: ${component} (${platform})"
        SUCCESSFUL_BUILDS+=("${component}:${platform}")

        # Test the built image
        test_image "${image_tag}" "${component}"

        return 0
    else
        log_error "Build failed: ${component} (${platform})"
        FAILED_BUILDS+=("${component}:${platform}")
        return 1
    fi
}

# Test a built image
test_image() {
    local image_tag="$1"
    local component="$2"

    log_info "Testing image: ${image_tag}"

    # Basic image inspection
    if ! docker inspect "${image_tag}" >/dev/null 2>&1; then
        log_error "Image inspection failed: ${image_tag}"
        return 1
    fi

    # Test image can start (basic smoke test)
    local container_id
    if container_id=$(timeout "${TEST_TIMEOUT}" docker run -d "${image_tag}" sleep 10 2>/dev/null); then
        log_success "Image starts successfully: ${image_tag}"

        # Check if sigul binary is available
        case "${component}" in
            client)
                if docker exec "${container_id}" which sigul >/dev/null 2>&1; then
                    log_success "sigul client binary found in image"
                else
                    log_warning "sigul client binary not found in image"
                fi
                ;;
            server)
                if docker exec "${container_id}" which sigul_server >/dev/null 2>&1; then
                    log_success "sigul_server binary found in image"
                else
                    log_warning "sigul_server binary not found in image"
                fi
                ;;
            bridge)
                if docker exec "${container_id}" which sigul_bridge >/dev/null 2>&1; then
                    log_success "sigul_bridge binary found in image"
                else
                    log_warning "sigul_bridge binary not found in image"
                fi
                ;;
        esac

        # Cleanup container
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
    else
        log_warning "Image failed to start or timed out: ${image_tag}"
    fi

    # Clean up the test image
    docker rmi "${image_tag}" >/dev/null 2>&1 || true
}

# Test repository setup script independently
test_repository_setup() {
    log_step "Testing repository setup script"

    local repo_script="${PROJECT_ROOT}/build-scripts/setup-repositories.sh"

    if [[ ! -f "${repo_script}" ]]; then
        log_error "Repository setup script not found: ${repo_script}"
        return 1
    fi

    # Test script in a UBI container
    local test_image="registry.access.redhat.com/ubi9/ubi-minimal:latest"
    local container_id

    log_info "Testing repository setup in UBI container"

    if container_id=$(docker run -d "${test_image}" sleep 300 2>/dev/null); then
        # Copy script to container
        if docker cp "${repo_script}" "${container_id}:/tmp/setup-repositories.sh" && \
           docker exec "${container_id}" microdnf install -y dnf && \
           docker exec "${container_id}" chmod +x /tmp/setup-repositories.sh && \
           timeout "${TEST_TIMEOUT}" docker exec "${container_id}" /tmp/setup-repositories.sh --test; then
            log_success "Repository setup script test passed"
        else
            log_error "Repository setup script test failed"
        fi

        # Cleanup
        docker rm -f "${container_id}" >/dev/null 2>&1 || true
    else
        log_error "Failed to start test container for repository setup"
        return 1
    fi
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Test Docker builds for sigul components with network resilience validation.

OPTIONS:
    -h, --help              Show this help message
    -c, --component COMP    Test specific component (client|server|bridge)
    -p, --platform PLAT     Test specific platform (linux/amd64|linux/arm64)
    -f, --fast              Skip network connectivity tests
    -k, --keep              Keep test images (don't cleanup)
    --timeout SECONDS       Build timeout in seconds (default: 600)

Examples:
    $0                           # Test all components and platforms
    $0 -c client                 # Test only client component
    $0 -p linux/amd64            # Test only amd64 platform
    $0 -c client -p linux/amd64  # Test client on amd64 only
    $0 --fast                    # Skip network tests, build only
    $0 --keep                    # Don't cleanup test images
EOF
}

# Parse command line arguments
parse_args() {
    local selected_components=()
    local selected_platforms=()
    local fast_mode=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--component)
                if [[ -n "${2:-}" ]]; then
                    selected_components+=("$2")
                    shift 2
                else
                    log_error "Component name required"
                    exit 1
                fi
                ;;
            -p|--platform)
                if [[ -n "${2:-}" ]]; then
                    selected_platforms+=("$2")
                    shift 2
                else
                    log_error "Platform name required"
                    exit 1
                fi
                ;;
            -f|--fast)
                fast_mode=true
                shift
                ;;
            -k|--keep)
                CLEANUP=false
                shift
                ;;
            --timeout)
                if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    BUILD_TIMEOUT="$2"
                    shift 2
                else
                    log_error "Valid timeout in seconds required"
                    exit 1
                fi
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Set defaults if not specified
    if [[ ${#selected_components[@]} -eq 0 ]]; then
        selected_components=("${COMPONENTS[@]}")
    fi

    if [[ ${#selected_platforms[@]} -eq 0 ]]; then
        selected_platforms=("${PLATFORMS[@]}")
    fi

    # Export for use in other functions
    export SELECTED_COMPONENTS=("${selected_components[@]}")
    export SELECTED_PLATFORMS=("${selected_platforms[@]}")
    export FAST_MODE="${fast_mode}"
}

# Main test function
main() {
    parse_args "$@"

    log_step "Starting Docker build tests"
    log_info "Components: ${SELECTED_COMPONENTS[*]}"
    log_info "Platforms: ${SELECTED_PLATFORMS[*]}"
    log_info "Build timeout: ${BUILD_TIMEOUT}s"
    log_info "Cleanup: ${CLEANUP}"

    # Run prerequisite checks
    check_prerequisites

    # Test network connectivity (unless in fast mode)
    if [[ "${FAST_MODE}" != "true" ]]; then
        test_network_connectivity
        test_repository_setup
    fi

    # Test builds for each component and platform combination
    local total_builds=0
    local start_time
    start_time=$(date +%s)

    for component in "${SELECTED_COMPONENTS[@]}"; do
        for platform in "${SELECTED_PLATFORMS[@]}"; do
            ((total_builds++))
            log_step "Build ${total_builds}: ${component} on ${platform}"

            # Skip ARM64 builds if not on ARM64 runner (for faster testing)
            if [[ "${platform}" == "linux/arm64" ]] && [[ "$(uname -m)" != "aarch64" ]] && [[ "${FAST_MODE}" == "true" ]]; then
                log_warning "Skipping ARM64 build in fast mode on non-ARM64 host"
                SKIPPED_BUILDS+=("${component}:${platform}")
                continue
            fi

            build_component "${component}" "${platform}" || true
        done
    done

    # Print summary
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_step "Test Summary"
    log_info "Duration: ${duration}s"
    log_info "Total builds attempted: ${total_builds}"
    log_success "Successful builds: ${#SUCCESSFUL_BUILDS[@]} - ${SUCCESSFUL_BUILDS[*]:-none}"

    if [[ ${#SKIPPED_BUILDS[@]} -gt 0 ]]; then
        log_warning "Skipped builds: ${#SKIPPED_BUILDS[@]} - ${SKIPPED_BUILDS[*]}"
    fi

    if [[ ${#FAILED_BUILDS[@]} -gt 0 ]]; then
        log_error "Failed builds: ${#FAILED_BUILDS[@]} - ${FAILED_BUILDS[*]}"
        log_error "Some builds failed. Check the logs above for details."
        exit 1
    else
        log_success "All attempted builds completed successfully!"
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
