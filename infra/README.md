# Infra (OpenTofu → Vultr)

Provisions a single Vultr instance for the dev_blog:

| Setting        | Value                              |
| -------------- | ---------------------------------- |
| Region         | `sea` (Seattle)                    |
| Plan           | `vc2-1c-2gb`                       |
| OS             | AlmaLinux 10 (looked up via `data "vultr_os"`) |
| Backups        | Automated, daily                   |
| IPv6           | Enabled                            |

State is stored in **Cloudflare R2** via OpenTofu's S3-compatible backend.

## One-time setup

### 1. R2 bucket

In the Cloudflare dashboard:

1. Create an R2 bucket, e.g. `dev-blog-tfstate`.
2. Create an R2 API token (Account → R2 → Manage API tokens) with **Object Read & Write** scoped to that bucket. Note the access key ID + secret.
3. Note your Cloudflare **Account ID** (R2 endpoint host).

### 2. GitHub repository secrets

Add these in *Settings → Secrets and variables → Actions*:

| Secret                  | Value                                |
| ----------------------- | ------------------------------------ |
| `VULTR_API_KEY`         | Vultr API key                        |
| `R2_ACCESS_KEY_ID`      | R2 token access key ID               |
| `R2_SECRET_ACCESS_KEY`  | R2 token secret access key           |
| `R2_ACCOUNT_ID`         | Cloudflare account ID                |
| `R2_BUCKET`             | `dev-blog-tfstate`                   |

## Running locally

```sh
cd infra
cp backend.hcl.example backend.hcl   # fill in bucket + endpoint
cp terraform.tfvars.example terraform.tfvars

export AWS_ACCESS_KEY_ID=<r2-key-id>
export AWS_SECRET_ACCESS_KEY=<r2-secret>
export TF_VAR_vultr_api_key=<vultr-key>

tofu init -backend-config=backend.hcl
tofu plan
tofu apply
```

## CI/CD

The workflow [`.github/workflows/infra.yml`](../.github/workflows/infra.yml) runs:

- **`pull_request`** touching `infra/**` → `tofu plan` (read-only).
- **`workflow_dispatch`** → choose `plan`, `apply`, or `destroy`.

Backend init uses `-backend-config` flags so the bucket and R2 endpoint are
injected from secrets at runtime — no account-specific values are committed.

## Notes

- The Vultr provider's `vultr_instance` resource enables daily backups via
  `backups = "enabled"` and a `backups_schedule { type = "daily" }` block.
- AlmaLinux 10 is resolved by name through `data "vultr_os"` so we don't have
  to hard-code an OS ID that may change. Adjust `os_name_filter` in
  `variables.tf` if Vultr renames it.
- The R2 backend uses `region = "auto"` and skips AWS-specific validations,
  which is the standard configuration for R2 as an OpenTofu/Terraform S3 backend.
