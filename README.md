# dev-blog

A personal developer blog built to be fast, secure, and entirely self-hosted — no platform lock-in, no third-party runtime dependencies.

## Stack

### Site

- **[Astro v7](https://astro.build)** — generates static HTML at build time, served as plain files. Zero client-side JavaScript by default.
- **Markdown & MDX** — posts live in `src/content/blog/` as typed Content Collections with frontmatter validation.
- **RSS feed + sitemap** — auto-generated via `@astrojs/rss` and `@astrojs/sitemap`.
- **Local fonts** — Atkinson Hyperlegible served from `src/assets/fonts/`, no external font requests.
- **pnpm** — fast, disk-efficient package management. Requires Node 26.

### Testing

- **Vitest** — unit and integration tests with v8 coverage.
- **Playwright** — end-to-end tests against the running site.

## Containers

Two containers on one VM, both run by systemd through podman [quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html):

```
Internet ──► VPC firewall ──► nftables ──► Caddy :443 (TLS, WAF, headers) ──► site :8080 (static files)
```

- **Site** (`image/app/`) — `astro build` in a Node 26 (Alpine) stage, then the output served by a stock Caddy file server on Debian slim. Runs as uid 1000 with a read-only root, all capabilities dropped and `no-new-privileges`.
- **Edge** (`image/caddy/`) — Caddy built with [`xcaddy`](https://github.com/caddyserver/xcaddy) and two plugins:
  - **[coraza-caddy](https://github.com/corazawaf/coraza-caddy)** — the Coraza WAF with the OWASP Core Rule Set embedded in the binary.
  - **[caddy-dns/googleclouddns](https://github.com/caddy-dns/googleclouddns)** — ACME DNS-01, so certificates are issued and renewed without inbound port 80. It authenticates as the VM's own service account; there is no key on the box.

  It also sets HSTS, `X-Frame-Options`, `X-Content-Type-Options` and `Referrer-Policy`, strips `Server`, and compresses with zstd/gzip. The production Caddyfile is `vm/config/Caddyfile.tmpl`, rendered on the VM.

`make dev` runs the same two images locally with `podman compose` (see [CONTAINER.md](CONTAINER.md)).

A third container, **Grafana Alloy** (`vm/quadlets/alloy.container`), is not part of the site: it ships the host's journal and metrics to watchtower, the owner's Loki/Mimir/Grafana, through a split WireGuard tunnel (`wg-watchtower`, 10.8.0.0/24 only). Logs are scrubbed on the host first (`vm/config/config.alloy.tmpl`; `make check-alloy` tests the rules). See [Telemetry](docs/runbook.md#telemetry-watchtower) in the runbook.

## Infrastructure

Everything is code, and nothing is configured by hand on the host.

| Layer | Tool | Details |
|---|---|---|
| Hosting | **Google Compute Engine** | One AlmaLinux 10 Shielded VM (`blog-vm`, e2-micro, `us-east1-b`) in project `dev-blog-494815`, with a static IP and daily snapshots. Admin access is IAP + OS Login only; port 22 is closed to the internet. |
| DNS | **Google Cloud DNS** | `blog.jasonmross.dev` has its own zone (`blog`), delegated from the `jasonmross.dev` zone. The VM can write challenge records in that zone only. |
| Provisioning | **[Pulumi](https://www.pulumi.com) (Go)** | `infra/` — network, firewall, VM, service accounts and per-resource IAM, Artifact Registry, the config bucket, DNS records. State in `gs://dev-blog-494815-pulumi-state`. |
| Host configuration | **`vm/`** | Uploaded to a bucket by Pulumi and applied by `vm/bootstrap.sh` on every boot and every sync: packages, nftables, fail2ban, dnf-automatic with a weekly reboot window, podman quadlets, Artifact Registry auth, the persistent journal, the watchtower tunnel and Alloy. |
| Updates | **podman auto-update** | The quadlets track floating `:prod` tags; a new image is pulled and health-gated, and a failed start rolls back. |
| Telemetry | **Grafana Alloy + WireGuard** | Logs and metrics to watchtower over its VPN, as agent peer `blog-vm`. The peer config is a secret in `watchtower-observe` that only `blog-vm@` reads, on the VM. Alloy is pinned by digest and never auto-updated. |
| CI/CD | **Gitea Actions** | `.gitea/workflows/pipeline.yml`, on the GKE runners. Tests every push and PR, runs `pulumi preview` on PRs, and on `main` runs `pulumi up`, builds and pushes the images, rolls them out and waits for the site to answer. A weekly run rebuilds the images to pick up base-image fixes. |

Operating it — first-time setup, deploys, rollbacks, drills — is in [docs/runbook.md](docs/runbook.md). The network path is described in [docs/networking.md](docs/networking.md).
