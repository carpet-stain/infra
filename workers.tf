# The edge fronting agent-memory (ADR-0031, #323): a Worker mints a
# Google ID token for gcp/main.tf's agent_memory_edge_invoker SA and
# forwards it as X-Serverless-Authorization — see
# workers/agent-memory-edge/worker.js for the mint+forward logic.
#
# UNVERIFIED (#323's gate): this Worker has never run against a live
# Cloud Run origin. Checkpoint 2 (a real fetch() carrying both headers)
# and checkpoint 3 (the deny-path flood) are unchecked in the issue —
# don't treat this resource as reachable-safe until they pass.
#
# No route or custom domain here on purpose — dns.tf's custom hostname
# and the edge rate-limit are #250's scope, handed a working origin.

resource "cloudflare_workers_script" "agent_memory_edge" {
  account_id         = var.cloudflare_account_id
  script_name        = "agent-memory-edge"
  content            = file("${path.module}/workers/agent-memory-edge/worker.js")
  main_module        = "worker.js"
  compatibility_date = "2024-09-23"

  bindings = [
    {
      name = "ORIGIN_URL"
      type = "plain_text"
      text = var.agent_memory_edge_origin_url
    },
    # Hand-populated out-of-band, never in Tofu state (ADR-0031's
    # Decision) — ignore_changes below freezes this whole bindings list, so bumping ORIGIN_URL needs docs/BOOTSTRAP.md §20's temporary-removal dance.
    {
      name = "GCP_SA_KEY_JSON"
      type = "secret_text"
      text = "PLACEHOLDER"
    },
  ]

  lifecycle {
    ignore_changes = [bindings]
  }
}
