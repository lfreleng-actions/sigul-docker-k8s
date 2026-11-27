#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Remove pip from a finished image, then prove nothing of it remains.
#
# pip is a build-time tool here: it installs python-nss-ng (all images)
# and SQLAlchemy/passlib (bridge, server). No RPM requires python3-pip
# and no Sigul component imports it, so the published images do not
# need it.
#
# Shipping it is not harmless. pip vendors its own urllib3, msgpack and
# setuptools under pip/_vendor/, and upgrading pip cannot fix them:
# Fedora 44's python3-pip vendors urllib3 1.26.20, Fedora 45's vendors
# 2.6.3, and the newest pip on PyPI vendors 2.7.0, all affected by
# CVE-2026-97689 / GHSA-vxq7-64xx-v4gw (fixed in urllib3 2.8.0). Those
# copies carry no dist-info, so the SBOM omits them and the Grype gate
# cannot see them.
#
# Two installs exist: the /usr/local copy from the pip self-upgrade, and
# the dnf python3-pip package beneath it. Both go. The checks then fail
# the build if pip is still importable, still on PATH, or has left a
# vendored tree behind.
#
# Fedora's python-pip-wheel stays: python3-libs requires it for
# ensurepip. It is a wheel archive under /usr/share/python-wheels, never
# on sys.path, and is unpacked only when something creates a venv.

set -euo pipefail

if python3 -m pip --version >/dev/null 2>&1; then
    python3 -m pip uninstall --yes --break-system-packages \
        --root-user-action=ignore pip
fi

# pip prunes any directory its uninstall leaves empty. Its entry points
# were the only files in /usr/local/bin, so that directory goes too,
# dangling the /usr/local/sbin symlink and failing later COPY-free
# steps that write there. The filesystem package owns it; restore it.
install -d -o root -g root -m 0755 /usr/local/bin

if rpm -q python3-pip >/dev/null 2>&1; then
    dnf remove -y --no-autoremove python3-pip
fi
dnf clean all

failed=0

while IFS= read -r path; do
    if [[ ! -e "$path" ]]; then
        echo "[ERROR] filesystem-owned path is missing or dangling: $path" >&2
        failed=1
    fi
done < <(rpm -ql filesystem | grep '^/usr/local/')

if python3 -c 'import pip' 2>/dev/null; then
    echo "[ERROR] pip is still importable" >&2
    failed=1
fi

for name in pip pip3; do
    if command -v "$name" >/dev/null 2>&1; then
        echo "[ERROR] $name is still on PATH: $(command -v "$name")" >&2
        failed=1
    fi
done

leftovers=$(find /usr/lib /usr/lib64 /usr/local/lib /usr/local/lib64 \
    -type d -path '*/pip/_vendor' -print 2>/dev/null || true)
if [[ -n "$leftovers" ]]; then
    echo "[ERROR] pip vendored trees remain:" >&2
    echo "$leftovers" >&2
    failed=1
fi

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi
echo "[INFO] pip removed; no vendored copies remain" >&2
