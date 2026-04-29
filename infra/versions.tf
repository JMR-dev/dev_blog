terraform {
  required_version = ">= 1.8.0"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.21"
    }
  }

  # Cloudflare R2 is S3-compatible, so we use the s3 backend with a custom
  # endpoint. Backend values that depend on secrets/account-specific data are
  # supplied at init time via `-backend-config=backend.hcl` (see README).
  backend "s3" {
    key    = "dev_blog/terraform.tfstate"
    region = "auto"

    # R2 quirks: skip AWS-specific validations and use path-style URLs.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

provider "vultr" {
  api_key     = var.vultr_api_key
  rate_limit  = 700
  retry_limit = 3
}
