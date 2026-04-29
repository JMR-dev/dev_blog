terraform {
  required_version = ">= 1.8.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.2"
    }
  }

  # Cloudflare R2 (S3-compatible) backend, mirroring infra/versions.tf.
  # Account-specific values are supplied at init time:
  #   tofu init -backend-config=backend.hcl
  # For local-only experimentation, comment this entire block out and
  # OpenTofu will fall back to the local backend.
  backend "s3" {
    key    = "dev_blog/github.tfstate"
    region = "auto"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

provider "github" {
  owner = var.repo_owner
  # Token is read from the GITHUB_TOKEN environment variable.
  # Easiest source: `export GITHUB_TOKEN=$(gh auth token)`.
}
