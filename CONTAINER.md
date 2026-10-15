# Containers

Two images, both built by `.gitea/workflows/pipeline.yml` and pushed to
Artifact Registry (`us-east1-docker.pkg.dev/dev-blog-494815/blog`).

```
image/
├── app/
│   ├── Dockerfile      # astro build → static files served by Caddy on :8080
│   └── Caddyfile       # the site server's config (baked in; cache headers)
├── caddy/
│   └── Dockerfile      # xcaddy: Coraza WAF + googleclouddns, module assertions
├── caddy.version       # one Caddy release for both images
└── coraza.version
```

The app image is built from the repository root:

```sh
docker build -f image/app/Dockerfile --build-arg CADDY_VERSION=$(cat image/caddy.version) .
```

## Local development

```sh
make dev
# → http://localhost:8080
# → https://localhost:8443  (self-signed via Caddy `tls internal`)
```

`make dev` runs `podman compose up --build` with the pinned versions from
`image/*.version`. `compose.yaml` is for local use only: it swaps in
`caddy/Caddyfile.dev`, which uses `tls internal` and the same WAF, so HTTPS
works without a domain or cloud credentials. Your browser will warn about the
self-signed certificate.

`HTTP_PORT` and `HTTPS_PORT` override the published ports.

For plain content work, `pnpm dev` (Astro's dev server) is faster.

## Production

The VM never sees this repository. Pulumi uploads `vm/` to a bucket, and
`vm/bootstrap.sh` renders it on the host:

- `vm/quadlets/` → `/etc/containers/systemd/` (`blog.container`,
  `caddy.container`, the `blog` network and Caddy's volumes)
- `vm/config/Caddyfile.tmpl` → `/etc/caddy/Caddyfile`

The quadlets reference the floating `:prod` tags, so `podman auto-update`
can pull a new build and roll it back if it fails its healthcheck. Every build
is also tagged with its commit (`:<short-sha>`), which is what you point
`:prod` back at to roll back (see [docs/runbook.md](docs/runbook.md)).

## Notes

- The site container is reachable only from Caddy: on the `blog` bridge,
  plus a loopback-only publish for when Caddy runs on the host network.
- The Core Rule Set ships inside the Caddy binary (`load_owasp_crs`), so
  upgrading it means bumping `image/coraza.version`.
- The WAF runs in `DetectionOnly` until its findings have been reviewed; the
  mode is `blog:wafMode` in `infra/Pulumi.prod.yaml`.
