# infra's first GCP resource (ADR-0024, #191). Bootstrap-only, mirroring
# iam/versions.tf's isolation: own state (a third key in the same R2
# bucket), applied only locally via `just tofu-gcp` — never by CI, since no
# GCP-authenticated CI identity exists yet (see the ADR's Consequences).
# Backend endpoint/credentials still come from the environment exactly like
# the root and iam/ modules (AWS_ENDPOINT_URL_S3 etc., derived in .envrc) —
# R2 backs state regardless of which cloud the described resources live in.

terraform {
  required_version = "~> 1.12"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "tofu-state"
    key          = "gcp/terraform.tfstate"
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

# Auth rides gcloud's ADC, not a Tofu variable — no AWS-bootstrap-key
# equivalent exists for GCP yet (docs/BOOTSTRAP.md §17).
provider "google" {
  project = var.google_project_id
  region  = var.google_region
}
