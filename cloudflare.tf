# The tofu-state R2 bucket (#8, epic #6) as code — the last hand-managed
# piece of the backend, adopted rather than recreated (recreating would
# destroy the state it holds: a genuine self-reference, this resource's own
# record lives inside the bucket it describes). See ADR-0012.
#
# name must stay "tofu-state" — matches versions.tf's backend `bucket`
# literal verbatim; a rename has to touch both, and backend blocks can't
# interpolate a resource attribute to enforce that at the language level.
#
# location is deliberately omitted, not just left to a guess: the provider's
# own plan modifiers (r2_bucket schema, v5.22) make an omitted location the
# zero-diff path (Computed, no RequiresReplace fires when unconfigured) and
# an explicit-but-wrong one the risky path (RequiresReplaceIfConfigured
# fires on any mismatch, before the ignore-drift modifier can normalize it
# away) — the inverse of the general Terraform ForceNew intuition. jurisdiction
# and storage_class carry no such asymmetry, so they're pinned to the
# schema's own defaults, matching what a console-created bucket already is.
resource "cloudflare_r2_bucket" "tofu_state" {
  account_id    = var.cloudflare_account_id
  name          = "tofu-state"
  jurisdiction  = "default"
  storage_class = "Standard"

  lifecycle {
    prevent_destroy = true
  }
}

# Backup target for dotfiles' agent-memory store (#159, ADR-0017): the
# client appends timestamped keys, never overwrites — append-only is a
# client convention, R2 has no versioning/object-lock. location omitted:
# for a fresh create the Computed attribute is the zero-diff path (same
# v5.22 plan-modifier asymmetry tofu_state's comment records).
resource "cloudflare_r2_bucket" "agent_memory_backups" {
  account_id    = var.cloudflare_account_id
  name          = "agent-memory-backups"
  jurisdiction  = "default"
  storage_class = "Standard"

  lifecycle {
    prevent_destroy = true
  }
}

# Expire aged-out backups so the append-only history stays bounded.
# 365d — tunable once the client's cadence lands (dotfiles#542).
resource "cloudflare_r2_bucket_lifecycle" "agent_memory_backups" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.agent_memory_backups.name

  rules = [{
    id      = "expire-old-backups"
    enabled = true
    # empty prefix = whole bucket
    conditions = { prefix = "" }
    delete_objects_transition = {
      condition = {
        type    = "Age"
        max_age = 31536000 # the schema's unit is seconds: 365 days
      }
    }
  }]
}
