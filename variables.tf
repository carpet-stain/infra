# Inputs fed at apply time via TF_VAR_* (never a literal in a committed
# file) — the same avoid-landing-in-source discipline ADR-0002 already
# applies to R2 credentials and TF_STATE_PASSPHRASE in .envrc.local.

variable "github_app_private_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = <<-EOT
    The GitHub App's private key (#29). The github_actions_secret resource
    this feeds (app.tf) is imported, not created, and permanently ignores
    changes to its value — so this default of "" is never actually sent
    anywhere; it exists only to satisfy the resource schema. Routine/CI
    plans (which never hold this value, per ADR-0005) evaluate fine against
    the default. Supply the real key via TF_VAR_github_app_private_key
    only if you ever deliberately rotate the key — which also means
    removing app.tf's ignore_changes line for that one apply.
  EOT
}
