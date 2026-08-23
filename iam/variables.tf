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

  validation {
    condition     = can(regex("^[0-9]+$", var.gcp_dispatch_service_account_unique_id))
    error_message = "Must be the SA's numeric uniqueId, never its email — a wrong or empty value refuses to plan rather than failing closed at runtime (#227, ADR-0010's #163 ID-pinning)."
  }
}

variable "gcp_agent_memory_service_account_unique_id" {
  type        = string
  nullable    = false
  description = <<-EOT
    Numeric unique_id of gcp/'s cloud-run-agent-memory service account —
    pins agent-memory-ssm-read's trust to that one identity, same
    discipline (and same gcloud read, docs/BOOTSTRAP.md §18) as the
    dispatch variable above (ADR-0026, #240).
  EOT

  validation {
    condition     = can(regex("^[0-9]+$", var.gcp_agent_memory_service_account_unique_id))
    error_message = "Must be the SA's numeric uniqueId, never its email — a wrong or empty value refuses to plan rather than failing closed at runtime (#227, ADR-0010's #163 ID-pinning)."
  }
}

# Revisit trigger: a 3rd federation consumer is where #257's declined
# resolver script gets reconsidered — see #257 for the hand-paste rationale.
