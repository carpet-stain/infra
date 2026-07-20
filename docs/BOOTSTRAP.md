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
  Contents / Pull requests / Actions / Issues read-write, plus
  **Secrets: Read-only**, **not** Administration. Grant this now even
  though nothing needs Secrets yet — step 5 below will. Put the value in
  `.envrc.local`'s `GH_TOKEN`.
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

Repository permissions, all set to **write** except where noted:

- Issues, Pull requests, Contents, Actions, Administration
- **Secrets: Read-only** (not write — a fresh `tofu plan` needs to refresh
  `github_actions_secret`, nothing here ever writes one)

Leave Variables alone — don't grant it. `github_actions_variable` is
deliberately not tofu-managed at all (step 6 explains why), so the App
never needs to touch it.

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
- **Seed the private key** as this repo's own Actions secret:
  `env -u GH_TOKEN -u GITHUB_TOKEN gh secret set GH_APP_PRIVATE_KEY` under
  the elevated session, pasting the `.pem` contents. Then delete the local
  file (or keep one copy in a password manager if you might need to
  re-seed later).
- **Set the client ID** as a plain repo variable — also manual, also
  permanent: `gh variable set GH_APP_CLIENT_ID --body <client id>`.
  `actions/create-github-app-token` has no permission input that could
  ever let a minted token refresh a `github_actions_variable` resource
  (confirmed against a live 422 and the tool's own open issue #231), so
  there's no path to making this tofu-managed today.
- **Bring the key under tofu** (existence only, never its value): add
  `app.tf`'s `github_actions_secret.app_private_key` resource with an
  `import` block pointed at `infra:GH_APP_PRIVATE_KEY` and
  `lifecycle { ignore_changes = [value] }`, then `just tofu-apply` once to
  adopt it. After that apply, delete the now-spent `import` block (same
  convention as any other adopt-then-delete import in this repo).

## 6. Seed the remaining CI secrets

Five more, all under the elevated session — AGENTS.md's two "CI secrets"
tables have the full purpose of each:

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set GH_TOKEN               # copy of the routine PAT
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set TF_STATE_PASSPHRASE     # same value as .envrc.local
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_ACCOUNT_ID           # same value as .envrc.local
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_PLAN_ACCESS_KEY_ID   # NEW token, Object Read only
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_PLAN_STORAGE_TOKEN   # same NEW read-only token
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_APPLY_ACCESS_KEY_ID  # copy of .envrc.local's R2 token
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_APPLY_STORAGE_TOKEN  # copy of .envrc.local's R2 token
```

The plan job's R2 token is the only genuinely new credential here — mint
it separately, scoped to Object Read only, rather than reusing the
Read & Write one. Everything else is a value you already have.

## 7. Bring in the CI workflows

Add `.github/actions/mint-app-token/` and the three
`.github/workflows/tofu-*.yml` files. Open a PR touching only these files,
confirm `tofu plan` posts a comment showing no unexpected drift, merge,
and confirm `tofu-apply.yml` completes automatically. From here on,
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

See AGENTS.md's Credentials section for the day-to-day version of this
list, and ADR-0004/ADR-0005 for the full reasoning behind the model.
