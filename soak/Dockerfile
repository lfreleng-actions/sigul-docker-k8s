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

# locust       - load generation, percentile stats, CSV history
# gevent       - cooperative concurrency; gevent.subprocess lets many
#                real `sigul` invocations run in one process
# docker       - Docker SDK, used for container stats and process-level
#                faults (pause/restart). Avoids needing a docker CLI.
# matplotlib   - report charts
# --break-system-packages matches Dockerfile.client: the base is
# Fedora, whose Python may carry a PEP 668 EXTERNALLY-MANAGED marker.
# The client image's own pip upgrade currently leaves none behind, so
# the flag is a no-op today and a safeguard against the base changing.
COPY requirements.txt /opt/soak/requirements.txt
RUN pip3 install --no-cache-dir --only-binary=:all: --break-system-packages \
        -r /opt/soak/requirements.txt \
    && rm -rf /root/.cache

ENV PATH="/usr/local/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY harness/ /opt/soak/harness/

WORKDIR /opt/soak

# The harness orchestrates everything: load, faults, sampling, analysis.
ENTRYPOINT ["python3", "-m", "harness"]
