#!/bin/bash
# Quick test to verify patches will be applied during Docker build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Testing Patch Application Process ==="
echo ""

# Simulate the Docker build process
echo "1. Checking patches directory exists..."
if [[ -d "${SCRIPT_DIR}/patches" ]]; then
    echo "   ✓ patches/ directory exists"
    ls -la "${SCRIPT_DIR}/patches/"
else
    echo "   ✗ patches/ directory NOT FOUND"
    exit 1
fi

echo ""
echo "2. Verifying patch file..."
if [[ -f "${SCRIPT_DIR}/patches/01-add-comprehensive-debugging.patch" ]]; then
    echo "   ✓ Patch file exists"
    echo "   Size: $(wc -l < "${SCRIPT_DIR}/patches/01-add-comprehensive-debugging.patch") lines"
else
    echo "   ✗ Patch file NOT FOUND"
    exit 1
fi

echo ""
echo "3. Testing patch application (dry-run)..."
tmpdir=$(mktemp -d)
cd "$tmpdir"

echo "   Downloading Sigul v1.4 source..."
curl -sL "https://pagure.io/sigul/archive/v1.4/sigul-v1.4.tar.gz" | tar xz
cd sigul-v1.4

echo "   Applying patch (dry-run)..."
if patch -p1 --dry-run < "${SCRIPT_DIR}/patches/01-add-comprehensive-debugging.patch" > /dev/null 2>&1; then
    echo "   ✓ Patch applies cleanly (dry-run)"
else
    echo "   ✗ Patch FAILED to apply (dry-run)"
    patch -p1 --dry-run < "${SCRIPT_DIR}/patches/01-add-comprehensive-debugging.patch"
    cd "${SCRIPT_DIR}"
    rm -rf "$tmpdir"
    exit 1
fi

echo ""
echo "4. Checking patched code for debug markers..."
if patch -p1 < "${SCRIPT_DIR}/patches/01-add-comprehensive-debugging.patch" > /dev/null 2>&1; then
    if grep -q "NSS INITIALIZATION DEBUG" src/utils.py; then
        echo "   ✓ NSS debug markers found in utils.py"
    else
        echo "   ✗ NSS debug markers NOT found"
        cd "${SCRIPT_DIR}"
        rm -rf "$tmpdir"
        exit 1
    fi
    
    if grep -q "DOUBLE-TLS CLIENT INIT DEBUG" src/double_tls.py; then
        echo "   ✓ Double-TLS debug markers found in double_tls.py"
    else
        echo "   ✗ Double-TLS debug markers NOT found"
        cd "${SCRIPT_DIR}"
        rm -rf "$tmpdir"
        exit 1
    fi
    
    if grep -q "CLIENT CONNECTION STARTING" src/client.py; then
        echo "   ✓ Client debug markers found in client.py"
    else
        echo "   ✗ Client debug markers NOT found"
        cd "${SCRIPT_DIR}"
        rm -rf "$tmpdir"
        exit 1
    fi
else
    echo "   ✗ Patch application FAILED"
    cd "${SCRIPT_DIR}"
    rm -rf "$tmpdir"
    exit 1
fi

cd "${SCRIPT_DIR}"
rm -rf "$tmpdir"

echo ""
echo "=== ALL TESTS PASSED ==="
echo ""
echo "Conclusion: Patches will be successfully applied during Docker build"
