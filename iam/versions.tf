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

    # R2 is S3-compatible, not AWS — skip every AWS-ism (same as the root
    # module's backend; the R2 credentials arrive via AWS_* env from
    # scripts/with-infra-secrets.sh, untouched by the aws provider below).
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

# us-east-1 is the recorded region choice (docs/BOOTSTRAP.md §9). Explicit
# access_key/secret_key — never the env chain: AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY in this process are the R2 backend credentials, and
# explicit provider config is the one slot that outranks them. The values
# are the bootstrap key, Keychain-fetched by scripts/with-infra-secrets.sh.
provider "aws" {
  region     = "us-east-1"
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
}
