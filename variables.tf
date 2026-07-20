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
