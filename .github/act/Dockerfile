# Minimal runner image for executing local-infra workflows with nektos/act
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    openssl \
    tar \
    gzip \
    nodejs \
    npm \
    docker.io \
    docker-compose-v2 \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @commitlint/cli @commitlint/config-conventional --prefix /usr/local

ENV NODE_PATH=/usr/local/lib/node_modules

ENTRYPOINT ["/bin/bash"]
