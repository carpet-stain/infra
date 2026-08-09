# The /infra/* SSM parameters (ADR-0010, #121) — existence and metadata
# only, the same existence-never-value shape the bitwarden-secrets
# resources use. Values are hand-populated from their live BWS copies
# (docs/BOOTSTRAP.md §10) and ignored here: SSM has no value-optional
# shape, so a placeholder plus ignore_changes is the closest analog.
# The KMS key is named by its literal alias — no cross-state lookup into
# the iam/ module is needed for the reference to resolve (ADR-0010).
#
# No /runtime/* parameters on purpose: the vended-token parameter is
# created by vend-token.yml's first put-parameter (#124), keeping this
# CI-applied state — and the infra-apply role — entirely out of the
# rotating tier, so ADR-0010's role×path matrix holds exactly.

locals {
  # Parameter name under /infra/ → description. Names mirror their
  # Bitwarden `infra`-Project keys (docs/BOOTSTRAP.md §6), kebab-cased.
  infra_parameters = {
    "gh-app-private-key"     = "GitHub App private key .pem (ADR-0004/0005) — CI token minting"
    "cloudflare-api-token"   = "Cloudflare API bearer token (#7) — the cloudflare provider"
    "tf-state-passphrase"    = "OpenTofu state encryption passphrase (ADR-0002) — unrecoverable, re-import if lost"
    "r2-account-id"          = "Cloudflare account id — forms the R2 S3 endpoint"
    "r2-plan-access-key-id"  = "R2 Object-Read-only S3 access key id (plan/drift)"
    "r2-plan-storage-token"  = "R2 Object-Read-only token — consumers sha256 it into the S3 secret (ADR-0002)"
    "r2-apply-access-key-id" = "R2 Object Read & Write S3 access key id (apply)"
    "r2-apply-storage-token" = "R2 Object Read & Write token — consumers sha256 it into the S3 secret (ADR-0002)"
  }
}

resource "aws_ssm_parameter" "this" {
  for_each = local.infra_parameters

  name        = "/infra/${each.key}"
  description = each.value
  type        = "SecureString"
  key_id      = "alias/infra-secrets"
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }
}
