# dev-blog

A personal developer blog built to be fast, secure, and entirely self-hosted — no platform lock-in, no third-party runtime dependencies.

## Stack

### Site

- **[Astro v6](https://astro.build)** — generates static HTML at build time, served via `astro preview`. Zero client-side JavaScript by default.
- **Markdown & MDX** — posts live in `src/content/blog/` as typed Content Collections with frontmatter validation.
- **RSS feed + sitemap** — auto-generated via `@astrojs/rss` and `@astrojs/sitemap`.
- **Local fonts** — Atkinson Hyperlegible served from `src/assets/fonts/`, no external font requests.
- **pnpm** — fast, disk-efficient package management. Requires Node ≥ 22.

### Testing

- **Vitest** — unit and integration tests with v8 coverage.
- **Playwright** — end-to-end tests against the running site.

## Containers

The entire runtime is two containers communicating over a private bridge network.

```
Internet ──► Caddy :443 ──► Astro app :4321
```

### App container

A two-stage `Containerfile` (Node 24 on Debian slim):

1. **Build stage** — installs deps and runs `astro build`.
2. **Runtime stage** — copies only `dist/`, `node_modules`, and config. Runs as a non-root `astro` user (UID 1001) with a read-only filesystem, all Linux capabilities dropped, and `no-new-privileges` enforced.

### Caddy container

A custom Caddy build compiled with [`xcaddy`](https://github.com/caddyserver/xcaddy), adding two plugins on top of the official image:

- **[coraza-caddy](https://github.com/corazawaf/coraza-caddy)** — the Coraza WAF with the OWASP Core Rule Set (CRS v4.7.0) baked into the image. All traffic is inspected before it reaches the app.
- **[caddy-dns/googleclouddns](https://github.com/caddy-dns/googleclouddns)** — ACME DNS-01 challenge provider, so TLS certificates are issued and renewed without opening port 80 or requiring a webroot.

Caddy also sets hardened response headers (HSTS, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`) and compresses responses with zstd and gzip.

### Compose vs. production

- **Local / CI**: `compose.yaml` (+ `compose.override.yaml`) spins up the full stack with `podman compose up --build`.
- **Production**: [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) units in `quadlet/` integrate the containers directly with systemd — no compose daemon required.

## Infrastructure

All infrastructure is version-controlled and reproducible.

| Layer | Tool | Details |
|---|---|---|
| Hosting | **[Vultr](https://www.vultr.com)** | VPS — 1 vCPU / 2 GB RAM, AlmaLinux 10, Seattle (`sea`) region. Reserved IPv4 and IPv6 addresses survive instance replacement. Daily automated backups. |
| DNS | **[Google Cloud DNS](https://cloud.google.com/dns)** | Authoritative DNS for the site's domain. A service-account key is also used by Caddy's `caddy-dns/googleclouddns` plugin to complete ACME DNS-01 challenges for automatic TLS certificate issuance and renewal. |
| Cloud provisioning | **OpenTofu** | Manages the Vultr instance and reserved IPs as code. State stored remotely via a Cloudflare R2 backend. |
| Host configuration | **Ansible** | Roles: `common`, `nftables` (firewall), `fail2ban` (intrusion prevention), `registry` (private container registry), `container_host` (Quadlet + Podman setup). |
