# syntax=docker/dockerfile:1
#
# The blog: Astro's static build, served by a plugin-free Caddy as a plain file
# server. TLS, the WAF and security headers are the EDGE Caddy's job
# (image/caddy/, vm/config/Caddyfile.tmpl); this one only answers HTTP on 8080
# behind it.
#
# The contract the rest of the stack is built around (vm/quadlets/blog.container):
#   1. Plain HTTP on blog:appPort (8080).
#   2. 200 on blog:healthPath (/) when it can serve.
#   3. Runs as uid:gid 1000:1000.
#   4. No state -- the container runs ReadOnly with a /tmp tmpfs.
#   5. `curl` installed, for the quadlet's healthcheck.
#
# Build from the repository root:
#   docker build -f image/app/Dockerfile --build-arg CADDY_VERSION=$(cat image/caddy.version) .

# Floats with Node 26's minor/patch releases (package.json engines: ^26), so the
# weekly rebuild picks them up. Only the build stage runs on it.
ARG NODE_TAG=26-alpine
ARG DEBIAN_TAG=13-slim
# The same Go minor as infra/go.mod's toolchain line and image/caddy/Dockerfile.
ARG GOLANG_TAG=1.27-trixie

# ---------------------------------------------------------------------------
# Stage 1: build the site.
# ---------------------------------------------------------------------------
FROM node:${NODE_TAG} AS build

ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    CI=1 \
    ASTRO_TELEMETRY_DISABLED=1

WORKDIR /app

# Dependency layer first, so a content-only change reuses the install.
COPY package.json pnpm-lock.yaml ./
# Node 25+ no longer ships corepack, so install the exact pnpm release that
# package.json's packageManager names; one version to bump, here and in CI.
# pnpm's install script fetches its native binary (musl here); npm 11 only
# warns about unlisted install scripts, so allow it before npm starts blocking.
RUN npm install -g --no-fund --no-audit --allow-scripts=pnpm \
        "$(node -p "require('./package.json').packageManager")"
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile

COPY . .
RUN pnpm run build

# ---------------------------------------------------------------------------
# Stage 2: the Caddy binary. The same release as the edge (image/caddy.version),
# so there is one Caddy version to track; no plugins here.
#
# Built from source with xcaddy, like the edge, rather than copied out of the
# official caddy image: that binary keeps the Go release and modules it was
# built with, and scripts/scan-image.sh fails this image on them. (2.11.7's
# carries Go 1.26.8's stdlib CVEs and the old x/net and go-jose below; no
# setting here can change them.) A source build takes the current Go 1.27 and
# GO_MODULE_PINS. It also has none of the official binary's
# cap_net_bind_service file capability, which the quadlet's NoNewPrivileges +
# DropCapability=ALL refuse to exec ("Operation not permitted").
# ---------------------------------------------------------------------------
FROM golang:${GOLANG_TAG} AS caddy

ARG CADDY_VERSION
ARG XCADDY_VERSION=v0.4.7
# The same list as image/caddy/Dockerfile, which says what each pin is for:
# change both.
ARG GO_MODULE_PINS="golang.org/x/net@v0.62.0 github.com/go-jose/go-jose/v4@v4.1.7"

ENV CGO_ENABLED=0 \
    GOTOOLCHAIN=local

RUN set -eux; \
    test -n "${CADDY_VERSION}" || { echo "CADDY_VERSION build-arg is required" >&2; exit 1; }; \
    go install "github.com/caddyserver/xcaddy/cmd/xcaddy@${XCADDY_VERSION}"

RUN set -eux; \
    # GO_MODULE_PINS, one --replace per pin, collected in "$@".
    set --; \
    for pin in ${GO_MODULE_PINS}; do set -- "$@" --replace "${pin%@*}=${pin}"; done; \
    xcaddy build "v${CADDY_VERSION}" "$@" --output /out/caddy; \
    /out/caddy version

# ---------------------------------------------------------------------------
# Stage 3: serve it.
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG}

ARG CADDY_VERSION

LABEL org.opencontainers.image.title="blog" \
      org.opencontainers.image.description="blog.jasonmross.dev: Astro static build served by Caddy" \
      org.opencontainers.image.version="${CADDY_VERSION}"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 1000 site; \
    useradd --uid 1000 --gid 1000 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin site; \
    # Created here, not by the COPY below: BuildKit applies COPY --chmod to
    # the parent directories it creates as well, which made /etc/caddy 0644
    # -- untraversable for uid 1000 ("open /etc/caddy/Caddyfile: permission
    # denied"). Buildah does not, so a local podman build hid it.
    install -d -m 0755 /etc/caddy

COPY --from=caddy --chown=root:root --chmod=0755 /out/caddy /usr/local/bin/caddy

# Caddy keeps autosave/ACME state under XDG dirs. Neither is wanted here (no
# admin API, no TLS), but point them at the tmpfs so a read-only root never
# turns a stray write into a crash.
ENV XDG_CONFIG_HOME=/tmp/caddy-config \
    XDG_DATA_HOME=/tmp/caddy-data

COPY --chown=root:root --chmod=0644 image/app/Caddyfile /etc/caddy/Caddyfile
COPY --from=build --chown=root:root /app/dist /srv

# Which build this is, for the pipeline's health gate: it waits until the live
# site serves this marker, not just any page. Set after the site is copied in,
# so a new value only rebuilds this layer.
ARG SITE_BUILD=dev
RUN printf '%s\n' "${SITE_BUILD}" > /srv/version.txt

USER 1000:1000
EXPOSE 8080

# Informational only -- the quadlet declares the authoritative healthcheck.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/ >/dev/null || exit 1

CMD ["/usr/local/bin/caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
