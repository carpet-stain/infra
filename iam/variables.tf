# Fed by scripts/with-infra-secrets.sh from the `infra-aws-bootstrap`
# Keychain item (docs/BOOTSTRAP.md §9) — never a literal in a committed
# file, never a GitHub secret. This module is local-only, so unlike the
# root module's copies of these variables, null is not meaningful here.

variable "aws_access_key_id" {
  type        = string
  nullable    = false
  description = <<-EOT
    Access key id of the `infra-bootstrap` IAM user — the only credential
    that may apply this module (ADR-0010). The id is the non-secret half;
    it rides the Keychain item's account attribute.
  EOT
}

variable "aws_secret_access_key" {
  type        = string
  nullable    = false
  sensitive   = true
  description = <<-EOT
    Secret access key of the `infra-bootstrap` IAM user, Keychain-gated
    (docs/BOOTSTRAP.md §9). Demoted to break-glass once CI runs on OIDC.
  EOT
}

variable "gcp_dispatch_service_account_unique_id" {
  type        = string
  nullable    = false
  description = <<-EOT
    Numeric unique_id (not email) of gcp/'s cloud-run-dispatch service
    account — pins infra-dispatch-read's trust condition to this one
    identity, never a wildcard (ADR-0010's #163 ID-pinning discipline,
    ADR-0024). Read it with `gcloud iam service-accounts describe
    cloud-run-dispatch@<project>.iam.gserviceaccount.com
    --format='value(uniqueId)'` after gcp/'s first apply creates the SA
    (docs/BOOTSTRAP.md §17) — a real chicken-and-egg step, same shape as
    ADR-0010's own bootstrap sequence.
  EOT
}
