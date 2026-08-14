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
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.13"
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

# Backblaze B2, the versioned backup satellite (ADR-0017, #189): the
# provider the agent-memory backup bucket (#159) will be managed through.
# Auth is the B2 management key via B2_APPLICATION_KEY_ID /
# B2_APPLICATION_KEY env vars — the provider reads them directly, so this
# block stays empty. Auth is lazy, same as cloudflare's above: with no b2
# resources yet this plans clean without the key, so neither CI nor the
# local wrapper fetches /infra/b2-management-key* until #159 lands a
# resource (that PR inherits the wiring — see #189's plan thread).
provider "b2" {}

# AWS SSM Parameter Store, the machine-secret store (ADR-0010, #121).
# us-east-1 is the recorded region choice (docs/BOOTSTRAP.md §9). Credential
# paths differ by caller and neither may ride the other's lane:
#  - CI: the env chain — short-lived OIDC creds exported by
#    configure-aws-credentials. Never Tofu variables: a saved-plan apply
#    (ADR-0003) replays variable values baked at plan time, which would
#    resurrect the plan job's expired read-only creds at apply. The R2
#    backend cedes the AWS_* env names to this (its creds ride the
#    runner-local r2-backend profile — see tofu-plan.yml's init comment
#    and #164 for why raw keys must stay out of -backend-config).
#  - Local: explicit vars from the Keychain-fetched infra-local-apply key
#    (with-infra-secrets.sh; ADR-0010's #126 amendment) — explicit config
#    outranks env, which locally still carries the R2 backend credentials.
#    Local applies are always fresh plan+apply, so baking is moot there.
provider "aws" {
  region     = "us-east-1"
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}
