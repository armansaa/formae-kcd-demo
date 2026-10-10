# ARC runner image for formae-kcd-demo: official actions-runner + formae CLI + pkl + jq.
# The formae version MUST match the agent in GKE (the CLI refuses an agent on another version).
FROM ghcr.io/actions/actions-runner:latest

ARG FORMAE_VERSION=0.90.5
ARG PKL_VERSION=0.31.0

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

# Same install method as the official formae Dockerfile. `standard` brings the auth-basic
# plugin that the CLI profile needs (plugins:/AuthBasic.pkl).
RUN /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes formae@${FORMAE_VERSION} \
 && /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes --channel stable standard \
 && /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes pkl@${PKL_VERSION} \
 && /opt/pel/bin/formae --version

ENV PATH=/opt/pel/bin:$PATH
USER runner
