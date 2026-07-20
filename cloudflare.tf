# The Cloudflare API token (#7) — the first fully-new-pattern secret in
# Bitwarden's `infra` Project (ADR-0008): declared here, value never in
# config. It's an externally-issued token (minted in Cloudflare's dashboard),
# so unlike a generated secret its value is set by hand in Bitwarden's UI and
# adopted with a temporary `import` block (README's adopt-then-delete
# convention) — omitting `value` makes the provider track that UI value via
# dynamic secrets rather than generate a random one, which for an
# externally-issued token would be wrong. No consumer wires it yet; #7 owns
# that. This declaration gives the token one managed home now so it isn't a
# stray hand-set secret later.
resource "bitwarden-secrets_secret" "cloudflare_api_token" {
  key        = "CLOUDFLARE_API_TOKEN"
  project_id = var.bws_infra_project_id
  note       = "Cloudflare API token (#7, ADR-0008). Externally issued — set/rotate the value in the Bitwarden UI, never here."
}
