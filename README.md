# dev-blog

A personal developer blog built to be fast, secure, and resilient.

## Stack

### Site

- **[Astro v6](https://astro.build)** — static site generator.
- **Markdown & MDX** — posts are fetched from a Google Cloud Storage (GCS) bucket and built into the site daily at 6 AM CT.
- **pnpm** — package management (Node ≥ 22).

### Runtime (2 Pod Quadlet System)

The production environment runs on **AlmaLinux 10** using Podman Quadlet units.

- **App Container**: Runs the Astro site (`astro preview`). It is fully immutable and contains the static content baked in.
- **Caddy Container**: A custom Caddy build with:
    - **Coraza WAF**: OWASP Core Rule Set for top-tier security.
    - **Google Cloud DNS Plugin**: For zero-downtime ACME DNS-01 TLS issuance.
    - **Maintenance Mode**: Caddy automatically serves a "Briefly Offline" page during container updates.

## Architecture

```
[ GCS Bucket ] ──( 6 AM CT Daily )──► [ Cloud Build ] ──► [ Artifact Registry ]
      │                                                           │
      └─────────( Object Change )──► [ Cloud Function ]           ▼
                                            │        [ Astro App (AlmaLinux 10 GCE) ]
                                            ▼
                                     [ Cloudflare R2 ]

### Build & Sync Logic
1.  **Storage**: New posts are uploaded as `.md` files to a GCS bucket.
2.  **Scheduling**: A Cloud Scheduler job triggers Cloud Build every day at 6 AM Central Time.
3.  **Optimization**: Cloud Build checks for changes in the last 24 hours. If no changes exist, the build is skipped to save costs.
4.  **Backups**: Every file change in GCS triggers a Cloud Function that runs a **Restic backup** to Cloudflare R2, ensuring point-in-time recovery.
5.  **Deployment**: Successful builds push a new image to Google Artifact Registry. The AlmaLinux host pulls and restarts the container.

## Infrastructure (IaaC)

Managed via **OpenTofu** with state stored in Cloudflare R2 (S3-compatible).

| Component | Service | Details |
|---|---|---|
| Hosting | **GCE (e2-small)** | 2 vCPUs, 2 GB RAM, AlmaLinux 10 (GCP). |
| DNS | **Cloud DNS** | Managed via OpenTofu. |
| CI/CD | **Cloud Build** | Ephemeral builds triggered via Cloud Scheduler. |
| Backups | **Cloud Function** | Event-driven Restic backups to R2. |
| Secrets | **Secret Manager** | Stores R2 keys and Restic passwords securely. |
| Registry | **Artifact Registry** | Private Docker repository for site images. |
| Content | **GCS** | Source of truth for markdown files. |

| Content | **GCS** | Source of truth for markdown files. |

## Deployment Commands

### Local Development
```bash
pnpm install
pnpm dev
```

### Provisioning Infrastructure
```bash
cd infra
tofu init -backend-config=backend.hcl
tofu apply
```
