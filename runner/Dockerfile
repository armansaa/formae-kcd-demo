# ARC runner image for formae-kcd-demo: official actions-runner + formae CLI + pkl + jq + gh
# (gh is used by the taufik-formae-* workflows for PR comments and reviews).
# The formae version MUST match the agent in GKE (the CLI refuses an agent on another version).
FROM ghcr.io/actions/actions-runner:latest

ARG FORMAE_VERSION=0.90.5
ARG PKL_VERSION=0.31.0

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq ca-certificates git \
 && mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && gh --version \
 && rm -rf /var/lib/apt/lists/*

# Same install method as the official formae Dockerfile. `standard` brings the auth-basic
# plugin that the CLI profile needs (plugins:/AuthBasic.pkl).
RUN /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes formae@${FORMAE_VERSION} \
 && /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes --channel stable standard \
 && /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes pkl@${PKL_VERSION} \
 && /opt/pel/bin/formae --version

ENV PATH=/opt/pel/bin:$PATH
USER runner
