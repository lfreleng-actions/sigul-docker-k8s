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

# uv installs the runner's tooling, mounted from this stage for that one
# RUN, as Dockerfile.client does. Pinned by digest; Dependabot's docker
# ecosystem keeps it current.
FROM ghcr.io/astral-sh/uv:0.13.6@sha256:af22a52f5eafef3d78e551599d405c02df61919d18028f0cea8eda93bc9986d0 AS uv

FROM ${SIGUL_CLIENT_IMAGE}

USER root

# The tooling the runner adds is pinned and hash-locked in
# requirements.txt, compiled by uv from requirements.in, which also
# explains each package; Dependabot bumps the lock.
#
# The client image ships no pip, and the runner adds none: uv installs
# into the client's interpreter, with the flags Dockerfile.client
# explains, and never lands in the image.
#
# --break-system-packages matches Dockerfile.client: the base is
# Fedora, whose Python may carry a PEP 668 EXTERNALLY-MANAGED marker.
# The client image carries none today, so the flag is a no-op and a
# safeguard against the base changing.
COPY requirements.txt /opt/soak/requirements.txt
RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv \
    uv pip install --system --break-system-packages --no-cache \
        --system-certs --require-hashes --only-binary :all: \
        -r /opt/soak/requirements.txt

ENV PATH="/usr/local/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY harness/ /opt/soak/harness/

WORKDIR /opt/soak

# The harness orchestrates everything: load, faults, sampling, analysis.
ENTRYPOINT ["python3", "-m", "harness"]
