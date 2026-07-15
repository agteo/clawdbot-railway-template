# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
ARG GOGCLI_VERSION=0.31.1
ARG PNPM_VERSION=10.23.0

FROM node:22-bookworm AS openclaw-build
ARG PNPM_VERSION

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable
RUN corepack prepare pnpm@${PNPM_VERSION} --activate

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Railway template settings if needed.
# Using a released tag avoids build breakage when `main` temporarily references unpublished packages.
ARG OPENCLAW_GIT_REF=v2026.7.1
RUN git clone --depth 1 https://github.com/openclaw/openclaw.git .
RUN git checkout main
RUN git branch --set-upstream-to=origin/main main
RUN git fetch --depth 1 origin "refs/tags/${OPENCLAW_GIT_REF}:refs/tags/${OPENCLAW_GIT_REF}"
RUN git checkout -B railway-template "${OPENCLAW_GIT_REF}"

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done
RUN git config user.name "OpenClaw Railway Template" \
  && git config user.email "railway-template@example.invalid" \
  && git add extensions \
  && if ! git diff --cached --quiet; then \
       git commit -m "railway: relax extension openclaw dependency constraints"; \
     fi

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build
RUN git add -A \
  && if ! git diff --cached --quiet; then \
       git commit -m "railway: record build-time openclaw tree state"; \
     fi \
  && git status --short


# Download the pinned gogcli release binary at build time. Override this version in
# Railway only after testing the new release.
FROM node:22-bookworm AS gogcli-download
ARG GOGCLI_VERSION
ARG TARGETARCH
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    tar \
  && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
  arch="${TARGETARCH:-amd64}"; \
  case "$arch" in \
    amd64|arm64) ;; \
    *) echo "Unsupported TARGETARCH for gogcli: $arch" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://github.com/openclaw/gogcli/releases/download/v${GOGCLI_VERSION}/gogcli_${GOGCLI_VERSION}_linux_${arch}.tar.gz" \
    | tar -xzO gog > /usr/local/bin/gog; \
  chmod +x /usr/local/bin/gog; \
  /usr/local/bin/gog --version

# Runtime image
FROM node:22-bookworm
ARG PNPM_VERSION
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    tini \
    python3 \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate

# Persist user-installed tools by default by targeting the Railway volume.
# - npm global installs -> /data/npm
# - pnpm global installs -> /data/pnpm (binaries) + /data/pnpm-store (store)
ENV NPM_CONFIG_PREFIX=/data/npm
ENV NPM_CONFIG_CACHE=/data/npm-cache
ENV PNPM_HOME=/data/pnpm
ENV PNPM_STORE_DIR=/data/pnpm-store
# Keep gogcli state and encrypted token storage on the Railway volume.
# Set GOG_KEYRING_PASSWORD as a Railway secret; never bake it into the image.
ENV GOG_HOME=/data/gogcli
ENV GOG_KEYRING_BACKEND=file
ENV PATH="/data/npm/bin:/data/pnpm:${PATH}"

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide gogcli as a baked-in, pinned binary. OAuth clients/tokens stay on /data.
COPY --from=gogcli-download /usr/local/bin/gog /usr/local/bin/gog
RUN gog --version

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

# The wrapper listens on $PORT.
# IMPORTANT: Do not set a default PORT here.
# Railway injects PORT at runtime and routes traffic to that port.
# If we force a different port, deployments can come up but the domain will route elsewhere.
EXPOSE 8080

# Ensure PID 1 reaps zombies and forwards signals.
ENTRYPOINT ["tini", "--"]
CMD ["node", "src/server.js"]
