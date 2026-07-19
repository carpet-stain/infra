# GitHub App installation wiring (ADR-0004). The App itself was registered
# by hand via GitHub's UI manifest flow (#29) — there's no `resource
# "github_app"` to manage that step; this file only manages which repos the
# resulting installation can reach.

locals {
  # Non-secret identifiers for the App registered under #29. The private
  # key is the one value here that's actually sensitive — it's fed via
  # variables.tf, not a local, and never appears in a committed file.
  github_app_installation_id = "147615180"
  github_app_client_id       = "Iv23liSIn2lcC8vEybpD"
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

# The App's private key (#29) — this account's single highest-value
# credential (ADR-0004) — propagated to infra's own Actions secrets only,
# never to any other managed repo (ADR-0005). Already set manually via
# `gh secret set` as part of #29's handoff; imported here rather than
# created, so tofu adopts it into state without ever sending a value over
# the wire — GitHub's API can't return the live value for tofu to diff
# against anyway, and `ignore_changes` means a routine/CI plan (which never
# holds the real key, var default "") can never compute a "set to empty"
# diff against what's already live. Rotating the key means removing the
# ignore_changes line for one deliberate apply, not editing this resource.
resource "github_actions_secret" "app_private_key" {
  repository  = github_repository.this["infra"].name
  secret_name = "GH_APP_PRIVATE_KEY"
  value       = var.github_app_private_key

  lifecycle {
    ignore_changes = [value]
  }
}

import {
  to = github_actions_secret.app_private_key
  id = "infra:GH_APP_PRIVATE_KEY"
}

# Not secret — GitHub's own guidance is this is safe to expose (visible on
# the App's public settings page) and, since 2024, the recommended
# identifier for actions/create-github-app-token's client-id input (#32),
# superseding the numeric App ID for that purpose.
resource "github_actions_variable" "app_client_id" {
  repository    = github_repository.this["infra"].name
  variable_name = "GH_APP_CLIENT_ID"
  value         = local.github_app_client_id
}
