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

# The App's private key (#29) — this account's single highest-value
# credential (ADR-0004/0005) — now lives in Bitwarden's `infra` Project
# (ADR-0008), migrated off the native GitHub Actions secret #31 first put
# it in (#47) so every secret this account holds has one source of truth.
# Dynamic secret: no `value` in config. The real key is set by hand in
# Bitwarden's UI during the one-time bootstrap and adopted with a temporary
# `import` block (README's adopt-then-delete convention) — so tofu never
# holds or sends the key, and the provider's dynamic-secrets tracking picks
# up the UI value with no config diff. The value still lands in state, but
# state is already R2-backed and client-side encrypted under ADR-0002's
# enforced TF_ENCRYPTION, so no new encryption step (ADR-0008). infra's CI
# reads it via bitwarden/sm-action at mint time (tofu-apply.yml,
# vend-token.yml), never from a native secret.
resource "bitwarden-secrets_secret" "app_private_key" {
  key        = "GH_APP_PRIVATE_KEY"
  project_id = var.bws_infra_project_id
  note       = "GitHub App RSA private key (#29, ADR-0008). Rotate by setting the new value in the Bitwarden UI — dynamic-secrets tracking imports it, no apply needed."
}

# Drop the native GitHub Actions secret #31 created from tofu's state — #47
# supersedes its mechanism, and leaving it managed would be a second source
# of truth for the key alongside Bitwarden. `destroy = false` (same as the
# client-id removal below): tofu forgets it without an API call, and the
# native secret is deleted by hand during the migration
# (`gh secret delete GH_APP_PRIVATE_KEY`, AGENTS.md's runbook) — so the CI
# apply token never needs Secrets: write for a one-time destruction. Bootstrap
# sequencing matters: the key must already be in Bitwarden and the mint path
# switched to sm-action (tofu-apply.yml) before the native secret is deleted,
# or CI apply loses its key mid-transition.
removed {
  from = github_actions_secret.app_private_key

  lifecycle {
    destroy = false
  }
}

# GH_APP_CLIENT_ID (infra repo variable) is NOT tofu-managed, even though
# it was originally created that way. actions/create-github-app-token has
# no `permission-variables` input at all — confirmed against a live 422,
# and actions/create-github-app-token#231 is the open upstream issue — so
# no App-minted token can ever refresh a github_actions_variable resource,
# which `tofu plan` needs to do for every resource in state, not just
# changed ones. The value is static and essentially never changes, so
# losing tofu management costs little; set by hand if it's ever missing:
# `gh variable set GH_APP_CLIENT_ID --body <client id>` under the elevated
# session. Not secret — GitHub's own guidance is the client ID is safe to
# expose (visible on the App's public settings page).
removed {
  from = github_actions_variable.app_client_id

  lifecycle {
    destroy = false
  }
}
