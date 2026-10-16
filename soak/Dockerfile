# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Soak-test runner.
#
# Built FROM the Sigul client image under test, so the load generator
# drives the real `sigul` CLI against the real double-TLS stack rather
# than a reimplementation of the protocol. Only test tooling is added;
# nothing here changes the client being exercised.

ARG SIGUL_CLIENT_IMAGE=sigul-client:latest
FROM ${SIGUL_CLIENT_IMAGE}

USER root

# The tooling the runner adds is pinned and hash-locked in
# requirements.txt, compiled by uv from requirements.in, which also
# explains each package; Dependabot bumps the lock.
#
# The client image ships no pip (build-scripts/remove-pip.sh), so the
# runner bootstraps its own from the wheel python3-libs bundles for
# ensurepip. The lock includes pip itself, so the one hash-checked
# transaction below upgrades it past the advisories
# build-scripts/requirements/advisories.in lists and installs the
# tooling. It stays in this test-only image, which is never published.
#
# --break-system-packages matches Dockerfile.client: the base is
# Fedora, whose Python may carry a PEP 668 EXTERNALLY-MANAGED marker.
# The client image carries none today, so the flag is a no-op and a
# safeguard against the base changing.
COPY requirements.txt /opt/soak/requirements.txt
RUN python3 -m ensurepip \
    && python3 -m pip install --no-cache-dir --require-hashes \
        --only-binary=:all: --break-system-packages \
        -r /opt/soak/requirements.txt \
    && rm -rf /root/.cache

ENV PATH="/usr/local/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY harness/ /opt/soak/harness/

WORKDIR /opt/soak

# The harness orchestrates everything: load, faults, sampling, analysis.
ENTRYPOINT ["python3", "-m", "harness"]
