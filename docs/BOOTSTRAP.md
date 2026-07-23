# Bootstrapping this repo from zero

The one-time sequence to get from "nothing exists" to a working
tofu-managed GitHub account with automated plan-on-PR and apply-on-merge.
Assumes a personal GitHub account (not an organization) and a Cloudflare
account for the state backend. Ongoing day-to-day workflow, once this is
done, is AGENTS.md's job — this doc only covers getting there once.

Follow it in order; later steps depend on earlier ones.

## 1. Tools and a Cloudflare R2 bucket

Install from Homebrew: `tenv`, `tflint`, `trivy`, `lefthook`, `just`,
`direnv`. In Cloudflare's dashboard, create the state backend by hand —
this isn't tofu-managed yet (tracked as a known gap, see AGENTS.md):

- An R2 bucket named `tofu-state`.
- An R2 API token scoped to **Object Read & Write** on that bucket. The
  access key ID is the token's ID (shown at creation, or
  `GET /user/tokens/verify`); the secret is derived from the token value
  (`.envrc` does this — see ADR-0002).
- A state encryption passphrase: `openssl rand -hex 32`, saved in a
  password manager. Losing it means every resource has to be re-imported,
  not recovered.

Clone this repo (or start a fresh one from it), copy
`.envrc.local.example` to `.envrc.local`, fill in the R2 values and
passphrase above, then `direnv allow` and `lefthook install`.

## 2. Two GitHub credentials, minted up front

Both are described in full in AGENTS.md's Credentials section — this is
just the bootstrap-time checklist for creating them the first time.

- **Routine PAT** (fine-grained, github.com/settings/personal-access-tokens):
  Contents / Pull requests / Actions / Issues read-write, **not**
  Administration. (No Secrets/Variables scope — the App key lives in
  Bitwarden, not a `github_actions_secret`, so no plan refresh needs it;
  ADR-0008.) Put the value in `.envrc.local`'s `GH_TOKEN`.
- **Elevated session**: `gh auth login` with the full default scopes (or a
  classic PAT with `repo` + `delete_repo`), used only via
  `env -u GH_TOKEN -u GITHUB_TOKEN gh ...` / `just tofu-apply`. This is
  what creates repos, applies rulesets, and handles anything the routine
  PAT or a GitHub App can't reach (see AGENTS.md's Credentials section and
  ADR-0004's Consequences for exactly what those are).

## 3. First apply — the actual governed repos

Populate `repos.tf`'s `local.repos`/`local.labels` with whatever repos and
labels you're bringing under management, then:

```sh
just tofu init
just tofu-apply
```

This creates/adopts `github_repository.this`, `github_issue_label.this`,
and `github_repository_ruleset.this` for every repo in the map. Set
`strict_required_status_checks_policy = true` on the ruleset **from this
first apply**, not later — it costs nothing this early (no apply-on-merge
pipeline exists yet to care about SHA drift), and retrofitting it after
CI automation is live means an extra manual round-trip.

## 4. Register the GitHub App — with the full permission set at once

App registration has no tofu resource; it's a one-time manifest-flow
step at github.com/settings/apps/new. The important part: **grant every
permission category this setup will ever need in one pass**, since
adding one later means every existing installation has to separately
accept the update — a second manual step this bootstrap skips entirely
by front-loading it.

Repository permissions, all set to **write**:

- Issues, Pull requests, Contents, Actions, Administration

Leave Secrets and Variables alone — don't grant either. The App key lives in
Bitwarden now (ADR-0008), so no minted token ever refreshes a
`github_actions_secret`, and `github_actions_variable` is deliberately not
tofu-managed at all (step 6 explains why) — the App never needs to touch
either category.

Uncheck **Active** under Webhooks (nothing here is event-driven), and set
**Where can this GitHub App be installed?** to **Only on this account**.

Capture all three outputs before moving on: the **App ID**, the
**Client ID** (what CI will actually use — see AGENTS.md's App bullet for
why Client ID over App ID), and the **private key** (`.pem`, shown once).

## 5. Install the App, then propagate its credentials

- **Install it** on every repo from step 3
  (github.com/settings/installations → the App → Repository access →
  Only select repositories). Manual, permanently — the installation-repository
  API rejects fine-grained PATs and App tokens outright (confirmed against
  GitHub's own docs and a live 403; see `app.tf`'s top comment). A future
  new repo needs this same manual step, every time.
- **Set the client ID** as a plain repo variable — also manual, also
  permanent: `gh variable set GH_APP_CLIENT_ID --body <client id>`.
  `actions/create-github-app-token` has no permission input that could
  ever let a minted token refresh a `github_actions_variable` resource
  (confirmed against a live 422 and the tool's own open issue #231), so
  there's no path to making this tofu-managed today.

Keep the `.pem` in a password manager for now — step 6 puts it in Bitwarden,
not a native GitHub secret.

## 6. Set up Bitwarden Secrets Manager

Secrets live in Bitwarden Secrets Manager (ADR-0008), whose scaffolding has
no Terraform resource — this is the one-time manual part. Do it in Bitwarden's
web UI unless noted; AGENTS.md's grant table is the spec to match and to audit
against later.

- **Enable Secrets Manager** on a free Organization under the existing paid
  personal account (it can't host SM directly — ADR-0008).
- **Create two Projects:** `infra` and `vended-tokens`.
- **Create three Machine Accounts** and set each one's Project grants
  **exactly** as AGENTS.md's grant table shows. These grants are the security
  boundary; the free tier caps at three, so there's no headroom. Capture each
  account's access token.
- **In `infra`, create the secrets** and note each UUID: `GH_APP_PRIVATE_KEY`
  (paste the `.pem` from step 4), `CLOUDFLARE_API_TOKEN` (leave empty until #7
  issues it), and the backend credentials CI and local fetch at runtime (#59,
  ADR-0009) — `TF_STATE_PASSPHRASE`, `R2_ACCOUNT_ID`, the **Object Read only**
  pair `R2_PLAN_ACCESS_KEY_ID`/`R2_PLAN_STORAGE_TOKEN`, and the read/write pair
  `R2_APPLY_ACCESS_KEY_ID`/`R2_APPLY_STORAGE_TOKEN`. ⚠ An R2 token _value_ is
  the raw token, not Cloudflare's pre-hashed Secret Access Key — the consumers
  `sha256` it (ADR-0002); a key id and its token must come from the same R2
  token.
- **In `vended-tokens`, create one secret** (e.g. `LOCAL_GH_TOKEN`) with a
  throwaway placeholder value — `vend-token.yml` overwrites it each run. Note
  its UUID.
- **Store the CI account's token in the login Keychain, gated** (#59) — this is
  what local `just tofu` / `tofu-apply` fetch the backend secrets with:
  `security add-generic-password -s infra-bws -a "$USER" -w` (paste the token;
  omitting `-A` is deliberate, so each read prompts). Put the two non-secret
  identifiers in `.envrc.local`: `BW_ORGANIZATION_ID` and
  `TF_VAR_bws_infra_project_id` (the routine `GH_TOKEN` from step 2 stays there
  too). Needs the `bws` CLI installed locally.
- **Adopt the two `infra` secrets into tofu** (existence, never value): add a
  temporary `import` block for each (`bitwarden-secrets_secret.app_private_key`
  and `.cloudflare_api_token`, id = the UUID), `just tofu-apply` once, then
  delete the spent `import` blocks (the repo's adopt-then-delete convention).
  The values are dynamic — set in Bitwarden's UI, never in config.

## 7. Seed CI's native credentials

CI holds almost nothing native (#59, ADR-0009): three machine-account secrets,
then variables holding the Bitwarden UUIDs it fetches everything else by. All
under the elevated session; AGENTS.md's "CI secrets and variables" section has
the full purpose of each.

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set BWS_ACCESS_TOKEN            # CI machine account token (step 6)
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set BWS_ORGANIZATION_ID         # Bitwarden Org UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set BWS_VENDING_ACCESS_TOKEN    # Vending machine account token

env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_INFRA_PROJECT_ID          # infra Project UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_APP_KEY_SECRET_ID         # GH_APP_PRIVATE_KEY secret UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_PASSPHRASE_SECRET_ID      # TF_STATE_PASSPHRASE secret UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_R2_ACCOUNT_SECRET_ID      # R2_ACCOUNT_ID secret UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_R2_PLAN_KEY_SECRET_ID     # R2_PLAN_ACCESS_KEY_ID secret UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_R2_PLAN_TOKEN_SECRET_ID   # R2_PLAN_STORAGE_TOKEN secret UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_R2_APPLY_KEY_SECRET_ID    # R2_APPLY_ACCESS_KEY_ID secret UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_R2_APPLY_TOKEN_SECRET_ID  # R2_APPLY_STORAGE_TOKEN secret UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_VENDED_SECRET_ID          # vended-tokens secret UUID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set GH_APP_CLIENT_ID              # App client id (step 5, if not already set)
```

Only the three machine-account tokens are secret; the UUIDs are variables —
they identify a Project or secret, they grant nothing on their own. There's no
native `GH_TOKEN` here: the plan job mints a read-scoped App token for the
provider instead (#59), and the routine PAT stays local-only.

## 8. Bring in the CI workflows

Add `.github/actions/mint-app-token/` and the `.github/workflows/tofu-*.yml`
files. Open a PR touching only these, confirm `tofu plan` posts a comment
showing no unexpected drift, merge, and confirm `tofu-apply.yml` completes
automatically.

Then add `.github/workflows/vend-token.yml` and trigger it once via
`workflow_dispatch` — confirm it publishes a fresh `{token, expires_at}` to
the `vended-tokens` secret and that the minted token never appears unmasked in
the run log. Local shells (`dotfiles`#377) read from there. From here on,
AGENTS.md's Branch & PR model and Credentials sections are the operating
manual, not this doc.

## What's still manual, permanently

Not a bootstrap-only list — these stay manual forever, for reasons
verified against GitHub's own docs and live behavior, not just today's
tooling gaps:

- Creating a **new** repo (App tokens can't call the repo-creation
  endpoint on a personal account).
- Installing the App on a new repo (the installation-repository API
  rejects every non-classic token type).
- Setting `GH_APP_CLIENT_ID` if it's ever lost (no App-minted token can
  refresh a `github_actions_variable` resource).
- Every CI secret's first seeding, and any App-manifest permission
  change plus its separate per-installation approval step.
- The entire Bitwarden scaffolding — Organization, Projects, Machine
  Accounts, and their Project grants (the provider only manages `secret`).
  The grants are the security boundary; audit the live state against
  AGENTS.md's grant table, since nothing enforces it.

See AGENTS.md's Credentials section for the day-to-day version of this
list, and ADR-0004/ADR-0005 for the full reasoning behind the model.
