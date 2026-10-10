# Image runner ARC untuk formae-kcd-demo: actions-runner resmi + formae CLI + pkl + jq.
# Versi formae HARUS sama dengan agent di GKE (CLI menolak agent beda versi).
FROM ghcr.io/actions/actions-runner:latest

ARG FORMAE_VERSION=0.90.5
ARG PKL_VERSION=0.31.0

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq ca-certificates git \
 && rm -rf /var/lib/apt/lists/*

# Cara install sama dengan Dockerfile resmi formae. `standard` membawa plugin auth-basic
# yang dibutuhkan profile CLI (plugins:/AuthBasic.pkl).
RUN /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes formae@${FORMAE_VERSION} \
 && /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes --channel stable standard \
 && /bin/bash -e -c "$(curl -fsSL https://hub.platform.engineering/get/setup.sh)" -- install --yes pkl@${PKL_VERSION} \
 && /opt/pel/bin/formae --version

ENV PATH=/opt/pel/bin:$PATH
USER runner
