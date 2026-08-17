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
    neon = {
      source  = "kislerdm/neon"
      version = "~> 0.15.0"
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

# Manages the R2 state bucket (ADR-0012) and DNS (#9). CLOUDFLARE_API_TOKEN env
# var — a different credential from the R2 S3 token the state backend uses (ADR-0002).
provider "cloudflare" {}

# The versioned backup satellite (ADR-0017, b2.tf/#159/ADR-0018).
# B2_APPLICATION_KEY_ID/KEY env vars, sourced from SSM — never ambient (ADR-0010).
provider "b2" {}

# Bootstrap only — no Neon project/database/role, so this stays empty and
# lazy like b2/cloudflare above (ADR-0023, #204).
provider "neon" {}

# AWS SSM Parameter Store (ADR-0010, #121), us-east-1 (docs/BOOTSTRAP.md §9). CI
# rides the OIDC env chain, never Tofu variables (#164); local uses explicit vars (AGENTS.md).
provider "aws" {
  region     = "us-east-1"
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}
