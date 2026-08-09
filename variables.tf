# Inputs fed at apply time via TF_VAR_* (never a literal in a committed
# file) — the same avoid-landing-in-source discipline ADR-0002 already
# applies to R2 credentials and TF_STATE_PASSPHRASE in .envrc.local.

variable "bws_infra_project_id" {
  type        = string
  nullable    = false
  description = <<-EOT
    UUID of the Bitwarden `infra` Project (ADR-0008) that the
    bitwarden-secrets_secret resources live in (the App private key, the
    Cloudflare API token). A one-time manual bootstrap creates the Project,
    so this is an account-identifying id, not a literal in this public
    repo — fed via TF_VAR_bws_infra_project_id from .envrc.local (locally)
    and vars.BWS_INFRA_PROJECT_ID (CI). Not the secret itself, just which
    Project to file it under; the secret values are dynamic (set in
    Bitwarden's UI), never here.
  EOT
}

variable "aws_access_key_id" {
  type        = string
  default     = null
  description = <<-EOT
    Access key id of the AWS bootstrap/break-glass key (docs/BOOTSTRAP.md
    §9), fed by scripts/with-infra-secrets.sh for local runs. Null in CI —
    there the aws provider falls back to the env chain and picks up the
    OIDC credentials (see the provider block for why CI credentials must
    never ride variables).
  EOT
}

variable "aws_secret_access_key" {
  type        = string
  default     = null
  sensitive   = true
  description = <<-EOT
    Secret half of the AWS bootstrap key, Keychain-fetched at invocation
    by scripts/with-infra-secrets.sh (never ambient, never committed).
    Null in CI, same as aws_access_key_id.
  EOT
}

variable "cloudflare_account_id" {
  type        = string
  nullable    = false
  description = <<-EOT
    Cloudflare account id that filmitinc.com and leppez.com's zones (#9,
    epic #6) belong to. Not secret, but an account-identifying id, so it
    stays out of this public repo the same way R2_ACCOUNT_ID does (ADR-0002)
    — fed via TF_VAR_cloudflare_account_id from .envrc.local (locally) and
    vars.CLOUDFLARE_ACCOUNT_ID (CI).
  EOT
}
