# syntax=docker/dockerfile:1.7

# ---------- Build stage ----------
FROM node:24-trixie-slim AS build

ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    CI=1

RUN corepack enable

WORKDIR /app

COPY package.json pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile

COPY . .
RUN pnpm run build


# ---------- Runtime stage ----------
FROM node:24-trixie-slim AS runtime

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=4321 \
    ASTRO_TELEMETRY_DISABLED=1

RUN groupadd --system --gid 1001 astro \
 && useradd  --system --uid 1001 --gid astro --shell /usr/sbin/nologin astro

WORKDIR /app

# Only what's needed to run `astro preview`
COPY --from=build --chown=astro:astro /app/package.json    ./package.json
COPY --from=build --chown=astro:astro /app/node_modules    ./node_modules
COPY --from=build --chown=astro:astro /app/dist            ./dist
COPY --from=build --chown=astro:astro /app/astro.config.mjs ./astro.config.mjs
COPY --from=build --chown=astro:astro /app/otel.js          ./otel.js

USER astro

EXPOSE 4321

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+ (process.env.PORT||4321) +'/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Invoke astro directly via node to avoid corepack/pnpm shims at runtime
# (the rootfs is read-only and corepack would try to write a cache dir).
# Use --import to load the OTEL instrumentation in ESM mode.
CMD ["node", "--import", "./otel.js", "./node_modules/astro/bin/astro.mjs", "preview", "--host", "0.0.0.0", "--port", "4321"]
