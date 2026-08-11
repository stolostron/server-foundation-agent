# Server Foundation Agent - Container Image
#
# All runtime dependencies for the server-foundation-agent, managed as code.
# Based on the devbox pattern from kubeopencode, tailored to SFA requirements.
#
# USE CASES this image must support:
#   1. Jira/GitHub/Slack automation (curl, jq, gh, python3)
#   2. Go code development: build, test, lint all SF repos (go, make, gcc, golangci-lint)
#   3. OpenShift/K8s cluster operations (oc, kubectl)
#   4. AWS resource management (aws CLI)
#   5. Bug reproduction on OCP clusters (oc, kubectl, go test)
#   6. GitHub App authentication for autonomous mode (openssl, gh-wrapper)
#   7. Konflux image verification for toolchain CVEs (skopeo + go version -m)
#
# NOT included (not used by any SFA skill):
#   - Node.js, Google Cloud CLI, Docker CLI
#
# Reference: docs/dependencies.md
#
FROM debian:bookworm-20260316-slim

# === Core Utilities ===
# Standard unix tools used across all shell scripts.
# openssl: required by github-app-iat.sh for JWT/RS256 signing
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    jq \
    ca-certificates \
    curl \
    wget \
    gnupg \
    openssh-client \
    openssl \
    unzip \
    zip \
    make \
    gcc \
    g++ \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# === Python 3 (stdlib only, no pip packages needed) ===
# Used by: 7 skills (jira-inbox, bug-analyze, bug-reproduce, cve-analysis,
#          jira-search, jira-sprint-report) and 3 workflows
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3 /usr/bin/python

# === Go ===
# All SF repos are Go projects — required for build, test, vet, mod tidy
ARG GO_VERSION=1.24.4
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

# === golangci-lint ===
# Most SF repos use golangci-lint for CI linting
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b /usr/local/bin

# === LSP Servers ===
# Language Server Protocol servers for AI agent code intelligence.
# Provides go-to-definition, find-references, diagnostics, and hover info.

# gopls (Go LSP) — all SF repos are Go
RUN GOBIN=/usr/local/bin go install golang.org/x/tools/gopls@latest \
    && rm -rf /root/.cache/go-build /root/go

# pylsp (Python LSP) — SFA skills and workflows use Python scripts
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    && pip install --break-system-packages --no-cache-dir python-lsp-server \
    && apt-get purge -y python3-pip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# === GitHub CLI ===
# Used by: fetch-prs, workspace-clone, workspace-cleanup, jira-inbox
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
       gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# === skopeo ===
# Used by: sfa-cve-toolchain-verify (inspect/copy Konflux images for go version -m)
RUN apt-get update && apt-get install -y --no-install-recommends skopeo \
    && rm -rf /var/lib/apt/lists/*

# === yq (YAML processor) ===
# Used for YAML validation (per CLAUDE.md global rules) and config manipulation
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# === kubectl ===
# Used by: install-acm, uninstall-acm, bug-reproduce
RUN ARCH=$(dpkg --print-architecture | sed 's/aarch64/arm64/' | sed 's/x86_64/amd64/') \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# === OpenShift CLI (oc) ===
# Used by: cluster-pools, install-acm, uninstall-acm, bug-reproduce
# Note: oc bundles its own kubectl, but we install kubectl separately above
# to ensure latest stable version for non-OCP clusters
ARG OC_VERSION=stable
RUN ARCH=$(dpkg --print-architecture | sed 's/amd64/x86_64/' | sed 's/arm64/aarch64/') \
    && curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux-${ARCH}.tar.gz" \
    -o /tmp/oc.tar.gz \
    && tar -C /usr/local/bin -xzf /tmp/oc.tar.gz oc \
    && rm /tmp/oc.tar.gz \
    && chmod +x /usr/local/bin/oc

# === Helm ===
# Used for chart operations in SF repos (e.g., registration-operator, cluster-manager)
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# === hiveutil ===
# Used by: cluster-pools skill for AWS orphan resource cleanup
# Built from openshift/hive source — requires Go toolchain (installed above)
RUN GOBIN=/usr/local/bin go install github.com/openshift/hive/contrib/cmd/hiveutil@latest \
    && rm -rf /tmp/.cache/go-build /tmp/.go/pkg

# === AWS CLI v2 ===
# Used by: cluster-pools skill (EC2, ELB, S3 access, orphan resource cleanup)
RUN ARCH=$(dpkg --print-architecture | sed 's/amd64/x86_64/' | sed 's/arm64/aarch64/') \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# === GitHub App Authentication Scripts ===
# Transparent GitHub authentication for gh CLI and git in autonomous mode.
# When GitHub App credentials are mounted to /etc/github-app/, the scripts
# automatically generate and cache Installation Access Tokens.
#
# Scripts:
#   - github-app-iat.sh: Generate IAT from GitHub App credentials (uses openssl for JWT)
#   - github-token-manager.sh: Cache and refresh tokens automatically
#   - gh-wrapper.sh: Inject GH_TOKEN transparently for gh CLI
#   - git-credential-github-app.sh: Git credential helper for transparent auth
COPY --chmod=755 scripts/github-app-iat.sh /usr/local/bin/
COPY --chmod=755 scripts/github-token-manager.sh /usr/local/bin/
COPY --chmod=755 scripts/gh-wrapper.sh /usr/local/bin/
COPY --chmod=755 scripts/git-credential-github-app.sh /usr/local/bin/

# Setup gh wrapper: gh command transparently gets token from GitHub App
# Move real gh to gh-real, then link wrapper as gh
RUN mv /usr/bin/gh /usr/bin/gh-real \
    && ln -sf /usr/local/bin/gh-wrapper.sh /usr/bin/gh

# Setup git credential helper: git push/pull transparently authenticated
RUN git config --system credential.helper /usr/local/bin/git-credential-github-app.sh

# === Workspace Setup ===
ARG WORKSPACE_DIR=/workspace
ENV WORKSPACE_DIR=${WORKSPACE_DIR}

RUN mkdir -p ${WORKSPACE_DIR} && chmod 777 ${WORKSPACE_DIR}

# === Environment Variables ===
# Use /tmp as HOME for OpenShift arbitrary UID compatibility
# (OpenShift runs containers with random UIDs from project-specific ranges)
ENV HOME="/tmp"
ENV SHELL="/bin/bash"
ENV XDG_CONFIG_HOME="/tmp/.config"
ENV XDG_CACHE_HOME="/tmp/.cache"
ENV XDG_DATA_HOME="/tmp/.local/share"

# Go environment — use /tmp for OpenShift UID compatibility
# /tmp is world-writable, avoids permission issues with arbitrary UIDs
ENV GOPATH="/tmp/.go"
ENV GOMODCACHE="/tmp/.gomodcache"
ENV GOCACHE="/tmp/.cache/go-build"
ENV PATH="/tmp/.go/bin:${PATH}"

# Pre-create config and cache directories with proper permissions
RUN mkdir -p /tmp/.config /tmp/.cache /tmp/.local/share \
    /tmp/.go /tmp/.gomodcache /tmp/.cache/go-build \
    && chmod -R 777 /tmp/.config /tmp/.cache /tmp/.local /tmp/.go /tmp/.gomodcache

# Non-root user (OpenShift compatible - any UID works with /tmp as HOME)
USER 1000:0

WORKDIR ${WORKSPACE_DIR}

CMD ["/bin/bash"]
