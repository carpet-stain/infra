# Core + provider pins; tenv resolves the runtime from required_version
# (claude/rules/tools/terraform.md). Backend endpoint and credentials come
# from the environment (AWS_ENDPOINT_URL_S3, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY — derived in .envrc) so no account identifier lands
# in this public repo; client-side encryption is enforced via TF_ENCRYPTION,
# also built by .envrc. See ADR-0022.

terraform {
  required_version = "~> 1.12"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "tofu-state"
    key          = "repos/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    # R2 is S3-compatible, not AWS — skip every AWS-ism.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

provider "github" {
  owner = "carpet-stain"
}

# Bitwarden Secrets Manager, the account's secret store (ADR-0008). Secret
# material is environment-sourced — the machine account's token via
# BW_ACCESS_TOKEN and the org UUID via BW_ORGANIZATION_ID (both Sensitive,
# both from .envrc.local, same never-a-literal-in-source discipline ADR-0002
# applies to R2 credentials). The endpoints are the opposite: public,
# region-fixed Bitwarden-cloud URLs — not account identifiers, not secret —
# and the provider has NO defaults for them (it errors at configure/plan
# without them), so they're pinned here rather than env-sourced. US cloud;
# EU would be api.bitwarden.eu / identity.bitwarden.eu. NOTE the prefix: the
# provider reads BW_*; the `bws` CLI the vend workflow uses for writes reads
# BWS_* — different tokens for different machine accounts, don't cross them.
provider "bitwarden-secrets" {
  api_url      = "https://api.bitwarden.com"
  identity_url = "https://identity.bitwarden.com"
}

# Cloudflare account governance (#7, epic #6): the provider that the R2
# state bucket (#8) and DNS (#9) will be managed through. Auth is a
# least-privilege API token via the CLOUDFLARE_API_TOKEN env var (from
# .envrc.local, same never-a-literal discipline as everything else) — the
# v5 provider reads it directly, so this block stays empty. Auth is lazy:
# with no cloudflare resources yet this plans clean without the token, so
# CI needs nothing until #8 lands a resource. NOTE this is a Cloudflare
# API *bearer* token (Zone:Read, DNS:Edit, Workers R2 Storage:Edit) — a
# different credential from the R2 *S3* token the state backend uses
# (R2_STORAGE_TOKEN, ADR-0002), which is R2's separate access-key flow.
provider "cloudflare" {}
