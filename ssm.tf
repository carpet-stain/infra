# The /infra/* SSM parameters (ADR-0010, #121) — existence and metadata
# only. Values are hand-populated (docs/BOOTSTRAP.md §4) and ignored here:
# SSM has no value-optional shape, so a placeholder plus ignore_changes is
# the closest analog to declaring existence without the value.
# The KMS key is named by its literal alias — no cross-state lookup into
# the iam/ module is needed for the reference to resolve (ADR-0010).
#
# No /runtime/* parameters on purpose: the vended-token parameter is
# created by vend-token.yml's first put-parameter (#124), keeping this
# CI-applied state — and the infra-apply role — entirely out of the
# rotating tier, so ADR-0010's role×path matrix holds exactly.
# /runtime/agent-memory/* (connection-uri, per-role bearers) is the same
# pattern: consumer-created by agent-memory-server, never here (ADR-0026).

locals {
  # Parameter name under /infra/ → description — kebab-cased versions of
  # the env names their consumers export (docs/BOOTSTRAP.md §4).
  infra_parameters = {
    "gh-admin-token"          = "GitHub fine-grained admin PAT (#150's spec, ADR-0013) — just tofu-apply + branch-protection bootstrap"
    "gh-app-private-key"      = "GitHub App private key .pem (ADR-0004/0005) — CI token minting"
    "cloudflare-api-token"    = "Cloudflare API bearer token, edit-scoped (#7) — the cloudflare provider (apply/dispatch, local)"
    "cloudflare-api-token-ro" = "Cloudflare API bearer token, read-only (#144) — the cloudflare provider (plan/drift)"
    "tf-state-passphrase"     = "OpenTofu state encryption passphrase (ADR-0002) — unrecoverable, re-import if lost"
    "r2-account-id"           = "Cloudflare account id — forms the R2 S3 endpoint"
    "r2-plan-access-key-id"   = "R2 Object-Read-only S3 access key id (plan/drift)"
    "r2-plan-storage-token"   = "R2 Object-Read-only token — consumers sha256 it into the S3 secret (ADR-0002)"
    "r2-apply-access-key-id"  = "R2 Object Read & Write S3 access key id (apply)"
    "r2-apply-storage-token"  = "R2 Object Read & Write token — consumers sha256 it into the S3 secret (ADR-0002)"
    "b2-management-key-id"    = "Backblaze B2 management application key id (#189, ADR-0017) — the b2 provider"
    "b2-management-key"       = "Backblaze B2 management application key (#189, ADR-0017) — the b2 provider"
    "neon-api-key"            = "Neon Postgres management API key (#204, ADR-0023) — the neon provider"
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
