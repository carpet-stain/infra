# GitHub App credential propagation (ADR-0004). The App itself was
# registered by hand via GitHub's UI manifest flow (#29) — there's no
# `resource "github_app"` to manage that step. Installation-repository
# membership is ALSO a manual, UI-only step: `github_app_installation_repository`
# calls `PUT /user/installations/{id}/repositories/{repo_id}`, which GitHub's
# own docs say explicitly does not work with fine-grained personal access
# tokens, GitHub App installation tokens, or GitHub App user access tokens —
# only a classic PAT with `repo` scope (confirmed against a live 403, and
# integrations/terraform-provider-github#2103 reports the same symptom). Not
# worth reintroducing a classic-scoped credential for one resource, so repo
# membership is added by hand in the App's install settings, same
# one-time-manual precedent as registration itself. See #30.

locals {
  # Non-secret identifier for the App registered under #29. The private key
  # is the one value here that's actually sensitive — it's fed via
  # variables.tf, not a local, and never appears in a committed file.
  github_app_client_id = "Iv23liSIn2lcC8vEybpD"
}

# The App's private key (#29) — this account's single highest-value
# credential (ADR-0004) — propagated to infra's own Actions secrets only,
# never to any other managed repo (ADR-0005). Already imported (its
# temporary `import` block did its job and is spent, same as any other
# adopt-then-delete import per README.md's convention) rather than created,
# so tofu never sent a value over the wire — GitHub's API can't return the
# live value for tofu to diff against anyway, and `ignore_changes` means a
# routine/CI plan (which never holds the real key, var default "") can
# never compute a "set to empty" diff against what's already live. Rotating
# the key means removing the ignore_changes line for one deliberate apply.
resource "github_actions_secret" "app_private_key" {
  repository  = github_repository.this["infra"].name
  secret_name = "GH_APP_PRIVATE_KEY"
  value       = var.github_app_private_key

  lifecycle {
    ignore_changes = [value]
  }
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
