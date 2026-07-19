# GitHub App installation wiring (ADR-0004). The App itself was registered
# by hand via GitHub's UI manifest flow (#29) — there's no `resource
# "github_app"` to manage that step; this file only manages which repos the
# resulting installation can reach.

locals {
  # Non-secret identifiers for the App registered under #29. The App's
  # private key and client ID (for CI token minting, #32) live in infra's
  # own Actions secrets/variables, not here — see #31.
  github_app_installation_id = "147615180"
}

# Installs the App on every managed repo — the same for_each-over-the-map
# shape main.tf's other per-repo resources already use (github_repository.this,
# github_issue_label.this). A new local.repos entry gets the App installed
# on its next apply, no manual step.
#
# Not compatible with app_auth provider authentication (the resource's own
# docs say so explicitly — managing an installation's own membership can't
# be done with that installation's own token). Runs under the elevated
# session, same as every other Administration-scope apply.
resource "github_app_installation_repository" "this" {
  for_each = local.repos

  installation_id = local.github_app_installation_id
  repository      = github_repository.this[each.key].name
}
