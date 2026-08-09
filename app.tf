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

# The App's private key (#29) — this account's highest-value credential
# (ADR-0004/0005) — lives in SSM at /infra/gh-app-private-key (ssm.tf,
# ADR-0010), hand-populated like every /infra/* value. Its Bitwarden home
# (ADR-0008) was decommissioned by #126 — via `tofu state rm`, not a
# removed{} block: the provider live-authenticates at plan time (confirmed
# on #146's CI), so a declarative forget could never run against a
# torn-down Organization.

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
# `scripts/with-infra-secrets.sh --gh-admin env -u GH_TOKEN gh variable set
# GH_APP_CLIENT_ID --body <client id>` (ADR-0013). Not secret — GitHub's
# own guidance is the client ID is safe to expose (visible on the App's
# public settings page).
removed {
  from = github_actions_variable.app_client_id

  lifecycle {
    destroy = false
  }
}
