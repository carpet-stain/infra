# The bootstrap-only root module (ADR-0010, #121): the GitHub OIDC identity
# provider, the per-consumer IAM roles, and the two tier KMS keys — the
# trust roots every other AWS credential assumes. Own state (a second key in
# the same R2 bucket), applied only locally with the bootstrap key
# (`just tofu-iam`), never by CI: if these lived in the CI-applied state,
# infra-apply would need iam:*/kms:Put* — the exact privilege-escalation
# path the state split exists to fence off. Directory-as-boundary is
# deliberate and rare here — see #121's layout comment.

terraform {
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "tofu-state"
    key          = "iam/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    # R2 is S3-compatible, not AWS — skip every AWS-ism (same as the root module's backend).
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

# us-east-1 (docs/BOOTSTRAP.md §9). Explicit vars, never the env chain — the
# AWS_* env names carry the R2 backend creds here, not this module's (ADR-0010 §#126).
provider "aws" {
  region     = "us-east-1"
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key

  # with-infra-secrets.sh's AWS_ENDPOINT_URL_S3 (R2, for the backend above)
  # leaks into every S3 call this process makes — pin real AWS back (#234, caught live).
  endpoints {
    s3 = "https://s3.us-east-1.amazonaws.com"
  }
}
