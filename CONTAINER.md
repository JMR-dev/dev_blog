# Container deployment

This stack runs the Astro blog behind a Caddy reverse proxy with the
[Coraza](https://coraza.io/) WAF (loaded with the OWASP Core Rule Set) and the
Google Cloud DNS plugin for ACME DNS-01 certificates.

## Layout

```
.
├── Containerfile               # App image (node:24-trixie-slim → astro preview)
├── caddy/
│   ├── Containerfile           # xcaddy build: Coraza + googleclouddns
│   ├── Caddyfile               # Reverse proxy + WAF + TLS config
│   └── coraza.conf             # Local Coraza overrides
├── compose.yaml                # podman compose / docker compose entrypoint
└── quadlet/                    # Systemd Quadlet units (production)
    ├── dev-blog.network
    ├── dev-blog-app.container
    ├── dev-blog-caddy.container
    ├── caddy-data.volume
    └── caddy-config.volume
```

## Quick start (compose)

`compose.override.yaml` is auto-loaded by `podman compose`, so the default
invocation is **dev mode** (high ports, rootless-friendly, self-signed HTTPS):

```sh
podman compose up --build
# → http://localhost:8080
# → https://localhost:8443  (self-signed via Caddy `tls internal`)
```

The dev override bind-mounts `caddy/Caddyfile.dev` into the Caddy container
which uses `tls internal` instead of ACME, so HTTPS works locally without
needing a real domain or GCP credentials. Your browser will warn about the
self-signed cert; trust it for `localhost` if you want a clean page.

For **production** (privileged ports 80/443, ACME via Cloud DNS) skip the
override file with an explicit `-f`:

```sh
# Provide a Google Cloud service-account key with Cloud DNS admin on your zone:
mkdir -p secrets && cp /path/to/key.json secrets/gcp-dns.json

# Override the public hostname / project:
export SITE_ADDRESS=https://blog.example.com
export ACME_EMAIL=you@example.com
export GCP_PROJECT=my-gcp-project

podman compose -f compose.yaml up -d --build
```

Either mode also accepts ad-hoc port overrides via `HTTP_PORT`/`HTTPS_PORT`
environment variables.

## Production (Quadlet)

Copy the unit files into a Quadlet search path and reload systemd:

```sh
# rootful
sudo cp quadlet/* /etc/containers/systemd/
sudo systemctl daemon-reload
sudo systemctl start dev-blog-caddy.service     # pulls in app + network

# rootless
mkdir -p ~/.config/containers/systemd
cp quadlet/* ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user start dev-blog-caddy.service
```

Build the images first so the Quadlet units can find them locally:

```sh
podman build -t localhost/dev-blog-app:latest .
podman build -t localhost/dev-blog-caddy:latest ./caddy
podman secret create gcp-dns-sa /path/to/key.json
```

## Notes

- The app container is *not* published to the host – Caddy reaches it on the
  internal `dev-blog` network at `app:4321`.
- The OWASP CRS (v4.7.0 by default) is baked into the Caddy image; bump
  `CRS_VERSION` in `caddy/Containerfile` to upgrade.
- Coraza's `load_owasp_crs` directive in the Caddyfile enables the CRS rules
  that cover the OWASP Top 10 (injection, XSS, RCE, LFI/RFI, scanner detection,
  protocol violations, session fixation, etc.).
