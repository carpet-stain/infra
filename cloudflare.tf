# The Cloudflare API token (#7) — the first fully-new-pattern secret in
# Bitwarden's `infra` Project (ADR-0008): declared here, value never in
# config. It's an externally-issued token (minted in Cloudflare's dashboard),
# so its value is set by hand in Bitwarden's UI and adopted with a temporary
# `import` block (README's adopt-then-delete convention). `ignore_changes =
# [value]` is required, same as the App key (app.tf): without `value` in
# config the provider would otherwise plan to overwrite it with a generated
# random one, wrong for an externally-issued token. No consumer wires it yet;
# #7 owns that. This declaration gives the token one managed home now so it
# isn't a stray hand-set secret later.
resource "bitwarden-secrets_secret" "cloudflare_api_token" {
  key        = "CLOUDFLARE_API_TOKEN"
  project_id = var.bws_infra_project_id
  note       = "Cloudflare API token (#7, ADR-0008). Externally issued — set/rotate the value in the Bitwarden UI, never here."

  lifecycle {
    ignore_changes = [value]
  }
}
