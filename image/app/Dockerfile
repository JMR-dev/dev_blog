# syntax=docker/dockerfile:1
#
# The blog: Astro's static build, served by a stock Caddy as a plain file
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

ARG NODE_TAG=24-trixie-slim
ARG DEBIAN_TAG=13-slim
# Used in a FROM line, so it has to be declared here, before the first FROM.
ARG CADDY_VERSION

# ---------------------------------------------------------------------------
# Stage 1: build the site.
# ---------------------------------------------------------------------------
FROM node:${NODE_TAG} AS build

ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    CI=1 \
    ASTRO_TELEMETRY_DISABLED=1

RUN corepack enable

WORKDIR /app

# Dependency layer first, so a content-only change reuses the install.
COPY package.json pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile

COPY . .
RUN pnpm run build

# ---------------------------------------------------------------------------
# Stage 2: the Caddy binary. The same release as the edge (image/caddy.version),
# so there is one Caddy version to track; the stock binary is enough here --
# no plugins.
#
# The official image ships it with a cap_net_bind_service FILE capability. Under
# the quadlet's NoNewPrivileges + DropCapability=ALL, exec'ing a binary that
# carries file capabilities fails outright ("Operation not permitted"), and
# this server only binds 8080, so strip it rather than loosen the container.
# ---------------------------------------------------------------------------
FROM docker.io/library/caddy:${CADDY_VERSION}-alpine AS caddy

RUN apk add --no-cache libcap-utils && setcap -r /usr/bin/caddy

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

COPY --from=caddy --chown=root:root --chmod=0755 /usr/bin/caddy /usr/local/bin/caddy

# Caddy keeps autosave/ACME state under XDG dirs. Neither is wanted here (no
# admin API, no TLS), but point them at the tmpfs so a read-only root never
# turns a stray write into a crash.
ENV XDG_CONFIG_HOME=/tmp/caddy-config \
    XDG_DATA_HOME=/tmp/caddy-data

COPY --chown=root:root --chmod=0644 image/app/Caddyfile /etc/caddy/Caddyfile
COPY --from=build --chown=root:root /app/dist /srv

USER 1000:1000
EXPOSE 8080

# Informational only -- the quadlet declares the authoritative healthcheck.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/ >/dev/null || exit 1

CMD ["/usr/local/bin/caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
