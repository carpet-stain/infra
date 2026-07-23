# AGENTS.md

How to work in this repo. This is the contributor guide the README points at:
workflow, commit rules, tooling, credentials, Terraform conventions.

> **Precedence:** this file wins over the generic agent-config rules. Sections
> with a lineage blockquote are instantiated from those rules for this repo;
> where this repo deliberately departs, the section says so and is authoritative.

## What this is

OpenTofu that manages GitHub account governance as config-as-data — see
README.md for what it covers and ADR-0002 for the stack. The boundary an agent
needs to hold: only account/API-level settings live here (each repo's own
working-tree files stay its own), and state is R2-backed and client-side
encrypted because the GitHub provider writes secret-shaped attributes into it
verbatim.

## Structure

- `repos.tf` — config-as-data map (`local.repos`, `local.labels`): one entry per
  governed repo. Routine changes happen here.
- `main.tf` — the resources (`github_repository.this`, `github_issue_label.this`,
  `github_repository_ruleset.this`); governance invariants that hold for every
  repo live here, not in per-repo data.
- `versions.tf` — core + provider pins (`github`, `bitwarden-secrets`), R2
  backend.
- `app.tf` — GitHub App credential wiring (ADR-0004/0005): the private key,
  now a `bitwarden-secrets_secret` in the `infra` Project (ADR-0008), not a
  native GH Actions secret. The client ID variable isn't here — set by hand
  (`gh variable set GH_APP_CLIENT_ID`), since no App-minted token can refresh
  a `github_actions_variable` resource (`actions/create-github-app-token` has
  no permission for it at all).
- `cloudflare.tf` — the Cloudflare API token (#7) as a dynamic Bitwarden
  secret (ADR-0008), value set in Bitwarden's UI, no consumer wired yet.
- `variables.tf` — apply-time inputs fed via `TF_VAR_*`, never a literal in
  a committed file (currently the `infra` Bitwarden Project UUID).
- `.github/actions/mint-app-token/` — composite action minting scoped
  App-installation tokens for CI (#32), used by `tofu-apply.yml`,
  `tofu-apply-dispatch.yml`, and `vend-token.yml`.
- `.github/workflows/` — `tofu-plan.yml`/`tofu-apply.yml` are the
  saved-plan-on-merge pipeline (ADR-0003); `vend-token.yml` publishes a
  scoped, rotating token into Bitwarden's `vended-tokens` Project for
  local/agent shells (#51, ADR-0008).
- `docs/adr/` — architecture decisions (`.adr-dir` points here).
- `scripts/` — `new-adr.sh`, `check-envrc-local-example.sh`.
- `justfile` / `lefthook*.yml` — base-owned composition root; a language overlay
  adds verbs/jobs in `*.lang` / `*-lang.yml`, never edits the base.

## Commits

> Concrete realization of **git.md** (Conventional Commits) for this repo.

`type(scope): description` — imperative, lowercase subject ≤50 chars (hard limit
72). `type` is a Conventional Commit type (enforced by
`.github/workflows/pr-guards.yml`; see it for the exact list). That check is
**CI-only — no local mirror**, so a bad subject fails late on the PR, not at
commit time; check it yourself before pushing. Blank line, then a body wrapped at
72 explaining _what_ and _why_, never _how_. Breaking change: `type!:` or a
`BREAKING CHANGE:` footer. `Co-authored-by:` per human contributor; never AI
attribution. One logical change per commit.

`scope` is **optional**. `pr-guards.yml` validates that a scope, when present, is
lowercase `[a-z0-9._-]`, but does **not** restrict the set. The table below is
team convention, not a CI-enforced allow-list:

| scope     | covers                       |
| --------- | ---------------------------- |
| `repos`   | `repos.tf` governance map    |
| `tofu`    | providers, backend, versions |
| `ci`      | `.github/workflows`          |
| `docs`    | README, ADRs                 |
| `scripts` | `scripts/`                   |
| `deps`    | dependabot bumps             |

## Branch & PR model

> Concrete realization of **git.md** (short-lived feature branches + protected
> `main`, rebase-merged) and **github.md** for this repo. Enforced by
> `.github/workflows/pr-guards.yml` (single-commit + Conventional-Commit checks).

1. Fetch and check `origin/main` before branching — a stale base means painful
   divergence. Branch off it per change; the branch is single-use, short-lived.
2. Open the PR as a **draft as soon as the first commit exists** — `git pr
--draft`, never the plain path, even for already-done work. Journal decisions,
   gotchas, and retractions as comments on the draft as work proceeds.
3. Commit freely on the branch — WIP commits needn't follow commit style; only
   the final squashed commit reaches `main`.
4. One logical change per PR. Never bundle unrelated changes.
5. When ready and tested, squash to exactly one Conventional Commit
   (`git reset --soft origin/main && git commit`), then `git pr` to finalize
   (mark ready). CI gates on the PR being exactly one commit with a
   Conventional-Commit subject — the two checks rebase-merge relies on.
6. Once green, **rebase-merge**: the single commit lands on `main` verbatim and
   the branch auto-deletes. Next change starts fresh off `main`.
7. `main` stays releasable, never committed to directly. Rebase-merge only.

Draft-at-handoff is the explicit exception: stay in draft only when a human must
test something _before_ code review, and say so in the handoff.

**Merging a PR whose tofu-apply fails with "no matching plan artifact":**
expected, not broken — see ADR-0003's runbook. Either the PR's plan (a
`tfplan-<sha>` artifact, `tofu-plan.yml`) aged past its retention window, or
the merge landed a different SHA than the one last planned. Push a fresh
commit to re-plan before merging, or run `tofu-apply-dispatch.yml` ("Tofu
apply (manual)" in the Actions tab — a fresh plan+apply pair against
current `main`, no saved artifact needed) after the fact — never revert
the merge.

**A crashed apply leaving a stale R2 lockfile**: cleared by hand with
`tofu force-unlock <id>` (the id is in the error message) under the
elevated session — deliberately not automated, since an automated unlock
defeats the lock's purpose.

## Local tooling

> Concrete realization of **git.md** (shift-left tooling) and **github.md**
> (local tooling) for this repo.

- **Mirror CI locally with lefthook.** `lefthook install` once; then every
  layer's checks run on commit/push. `just lint` wraps
  `lefthook run pre-commit --all-files` — the same entry point CI uses (`lint.yml`
  runs `just lint --tag base`, `tofu.yml` runs `--tag lang`). Local runs the full
  union, unfiltered.
- **The commit-format and single-commit gates have no local mirror** — they live
  only in `pr-guards.yml`. Squash and check the subject before finalizing.
- `git pr --draft` opens the early draft; `git pr` finalizes it (`gh pr ready`).
  There's no direct-to-ready path.
- `act` runs the Actions workflows locally via Docker for testing without pushing.
- **`comment-concision`** (`scripts/check-comment-concision.sh`, ADR-0006) is
  advisory only, unlike every other job here — it always exits 0 and only
  nudges toward re-reading an outlier-length (15+ line) comment block on one
  declaration, mirroring `dotfiles`' reference implementation
  (`dotfiles` ADR-0031) rather than an independently-derived design.

## Credentials

> Concrete realization of **git.md** (credential scope) and **github.md**
> (scoped PAT, explicit elevation) for this repo. See `.envrc.local.example`.

- Routine work uses a **direnv-scoped fine-grained PAT** (Contents / Pull
  requests / Actions / Issues read-write, **not** Administration) via
  `.envrc.local` — never a full `gh auth login` session. So an agent driving
  `gh` can't touch repo settings or branch protection. Secrets/Variables:
  Read-only used to be needed so `tofu plan` could refresh the App-key
  `github_actions_secret`, but that key moved to Bitwarden (#47, ADR-0008)
  and no `github_actions_secret`/`_variable` resource is tofu-managed
  anymore, so neither category is required now.
- Run local `tofu` through `just tofu` / `just tofu-apply` only, never bare.
  The elevated backend secrets (state passphrase, R2 read/write creds) are
  fetched from Bitwarden at invocation by `scripts/with-infra-secrets.sh`,
  gated behind a macOS Keychain prompt — not exported ambiently by direnv
  (#59, ADR-0009), so a stray agent shell in this repo no longer holds them.
  `.envrc.local` keeps only the routine `GH_TOKEN` (the github provider's
  local read credential) and the non-secret Bitwarden identifiers
  (`BW_ORGANIZATION_ID`, `TF_VAR_bws_infra_project_id`); the `infra`
  machine-account token lives in the login Keychain (item `infra-bws`), added
  without an app ACL so each read prompts. See `.envrc.local.example`.
- Elevate explicitly only for the one action that needs admin:
  `env -u GH_TOKEN -u GITHUB_TOKEN gh ...` — both vars, since `.envrc` aliases
  `GITHUB_TOKEN` to the same scoped token, so dropping `GH_TOKEN` alone is a no-op.
- `just tofu plan` uses the routine `GH_TOKEN` for the github provider (read);
  `just tofu-apply` swaps in the elevated session token (Administration) — both
  wrapped by the Keychain-gated backend-secret fetch. Losing the passphrase
  means re-importing, not recovering (ADR-0002); it lives in Bitwarden now.
- A GitHub App (ADR-0004, `app.tf`) is registered and installed on every
  repo in `local.repos` for future CI-side credential delegation — both by
  hand, not tofu-managed. Installation-repository membership specifically
  can't be: GitHub's API rejects fine-grained PATs (and App-issued tokens)
  on that endpoint entirely, so adding a new `local.repos` entry to the
  App's install stays a manual step in the App's settings, not something
  `tofu apply` picks up automatically (see `app.tf`'s top comment). The App
  also **cannot** create a brand-new repo on this personal (non-org)
  account — GitHub rejects App installation tokens on the repo-creation
  endpoint for user accounts (ADR-0004's Consequences). Adding a genuinely
  new repo to `local.repos` always needs one human-run `just tofu-apply`;
  don't design automation that assumes otherwise.

### Bitwarden Secrets Manager

> Concrete realization of ADR-0008 for this repo. Secrets live in Bitwarden
> Secrets Manager. The store's scaffolding — the Organization, both Projects,
> all three Machine Accounts, and the grants between them — has no Terraform
> resource (the provider only manages `secret`), so it's a one-time manual
> bootstrap, same shape as the App's own registration; the from-zero sequence
> is `docs/BOOTSTRAP.md`. This section is the ongoing reviewable spec.

The **Machine-Account-to-Project grants are the actual security boundary**
(ADR-0008), and the provider can't manage them — so audit the live Bitwarden
state against this table, since nothing else can. The two-Project split only
holds while the grants stay exactly as below: no account a local shell holds
can reach `infra`, and the CI and Local accounts share no Project.

| Machine Account | `infra`    | `vended-tokens` | Token held by                                     |
| --------------- | ---------- | --------------- | ------------------------------------------------- |
| CI              | read/write | —               | `BWS_ACCESS_TOKEN` (tofu plan/apply, #32 minting) |
| Vending         | read       | read/write      | `BWS_VENDING_ACCESS_TOKEN` (`vend-token.yml`)     |
| Local           | —          | read            | a local/agent shell (`dotfiles`#377)              |

The free tier caps at **three** Machine Accounts, so this uses the entire
budget — no headroom. A fourth consumer means merging the two CI-side
accounts (grants on both Projects); the boundary that must stay real is
CI-vs-local, not the split between CI consumers (ADR-0008).

**If vending stops:** scheduled workflows auto-disable after 60 days of repo
inactivity (ADR-0008). Local shells then loud-fail on a stale token — the
designed degradation. Re-enable `vend-token.yml` from the Actions tab (or run
it once via `workflow_dispatch`) to resume.

### CI secrets and variables

> Realizes #59/ADR-0009 on top of ADR-0003's saved-plan model: after the
> migration CI holds almost nothing native — it authenticates to Bitwarden and
> fetches the rest at runtime via `bitwarden/sm-action`.

The **complete native GitHub-secret footprint** across all workflows:

| Native secret              | Used by             | Purpose                                                                                                                                                                                                              |
| -------------------------- | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BWS_ACCESS_TOKEN`         | plan/apply/dispatch | The `infra` CI machine account — configures the `bitwarden-secrets` provider (`BW_ACCESS_TOKEN`) and is `access_token` for every `sm-action` fetch. The one root that can't live in the store it unlocks (ADR-0008). |
| `BWS_ORGANIZATION_ID`      | plan/apply/dispatch | Bitwarden Org UUID (`BW_ORGANIZATION_ID`) — Sensitive, so a secret.                                                                                                                                                  |
| `BWS_VENDING_ACCESS_TOKEN` | vend                | The distinct Vending machine account (read `infra`, read/write `vended-tokens`) — never the CI account, so the vended path can't reach CI's write grant on `infra`.                                                  |

Everything else is **fetched from the `infra` Project at runtime**, keyed by a
non-secret **variable** holding its Bitwarden UUID:

- Fetched by `sm-action`: `TF_STATE_PASSPHRASE`, `R2_ACCOUNT_ID`, the R2 pair
  (plan reads `R2_PLAN_*` — a separate **Object Read only** token; apply and
  dispatch read the read/write `R2_APPLY_*`), and `GH_APP_PRIVATE_KEY`. Apply
  and dispatch mint an elevated App token from the key; the plan job mints an
  `administration:read`+`issues:read` token for the provider (the routine PAT
  is retired, #59) and posts its PR comment via the ephemeral `github.token`.
- UUID **variables** (not secret): `BWS_INFRA_PROJECT_ID`,
  `BWS_APP_KEY_SECRET_ID`, `BWS_PASSPHRASE_SECRET_ID`, `BWS_R2_ACCOUNT_SECRET_ID`,
  `BWS_R2_{PLAN,APPLY}_{KEY,TOKEN}_SECRET_ID`, `BWS_VENDED_SECRET_ID`, and
  `GH_APP_CLIENT_ID`.

Seed the three native secrets and the variables once via the elevated session
(`gh secret set` / `gh variable set`); the Bitwarden secrets they reference and
the from-zero order live in `docs/BOOTSTRAP.md`. These can't be tofu-managed —
a repo can't provision its own CI's first credentials via its own CI.

## Terraform / OpenTofu conventions

> Concrete realization of **terraform.md** for this repo, **inlined here**
> instead of a separate `docs/CODING.md` (terraform.md's COMPOSE default) — a
> deliberate choice while the repo is small. Split to `docs/CODING.md` if this
> grows; until then this section is authoritative over the generic Terraform
> conventions. The _why_ behind the stack is ADR-0002.

- **OpenTofu (`tofu`), not Terraform** (ADR-0002). Write `.tf`, never `.tofu` —
  tflint/terraform-docs parse only `.tf`, and OpenTofu-encrypted state is a
  one-way door (not readable by Terraform; deliberate, not to be backed into).
  `tenv` resolves and pins the runtime from `versions.tf`'s `required_version`
  (`~> 1.12`) — direnv locally, `TENV_AUTO_INSTALL` in CI.
- **Config-as-data.** HCL is declarative config, not a program — model variation
  as data. The repo is one `for_each` over `local.repos`: routine change = edit a
  map entry (`repos.tf`); per-repo invariants (rebase-merge only,
  `archive_on_destroy`, `vulnerability_alerts`) are fixed in `main.tf`, not data.
  `.this` names the single instance of a type; names stay singular under
  `for_each`.
- **Flat root, no Terragrunt.** `versions.tf` / `main.tf` / `repos.tf`; no child
  modules. At single-account scale the `for_each`-over-a-map is the DRY story. Add
  `variables.tf` / `outputs.tf` only at a real module API — and then every var and
  output carries `type` + `description`, `sensitive` on secret-shaped values,
  `nullable = false` unless null is meaningful.
- **Pins.** `required_version` on the core, `~>` provider pins
  (`integrations/github ~> 6.13`), committed `.terraform.lock.hcl` as the
  reproducibility gate. Upgrades are a deliberate `tofu init -upgrade` in their
  own diff.
- **State is a secret store.** The GitHub provider writes attribute values into
  state verbatim, so state is secret material (ADR-0002): remote R2 backend with
  locking; **client-side encryption enforced** via the `TF_ENCRYPTION` block
  `scripts/with-infra-secrets.sh` builds at invocation from the
  Bitwarden-fetched `TF_STATE_PASSPHRASE` (#59, ADR-0009), key material in the
  environment only. Never commit state, plans, or `.terraform/` (all
  gitignored); the lockfile _is_ committed.
- **Refactor declaratively.** `moved {}` / `removed {}` / `import {}` blocks,
  reviewable in the plan; adopting a repo or resolving a label collision uses a
  temporary `import` block (see README's "Adding a repo"), deleted once applied.
  `tofu state mv`/`rm` is the last resort.
- **Enforced checks** (via `just lint --tag lang` locally and `tofu.yml` in CI):
  `tofu fmt -check` + `validate` as the floor, `tflint` (recommended preset),
  `trivy` for misconfigurations. Deliberate exceptions are inline and justified —
  e.g. `#trivy:ignore:GIT-0001` on `github_repository.this`, since public
  visibility is intentional per-repo data.

## How to verify changes

- `just lint` — the full local pre-commit union: actionlint, markdownlint,
  prettier, yamlfmt, envrc-sync, comment-concision, plus the OpenTofu `lang`
  slice (`tofu fmt -check`, `tflint`, `trivy config`). Scope to one slice
  with `just lint --tag base` or `--tag lang` — the exact slices `lint.yml`
  and `tofu.yml` run in CI.
- `just tofu init` (once per checkout), then `just tofu plan` — the real
  end-to-end check; review the plan before any `just tofu-apply`. See
  Credentials for the token scope each verb needs.
- No module tests yet — there are no `.tftest.hcl` files. If a child module is
  extracted, `tofu test` is the path; until then `plan` is the behavioral check.
- CI mirrors all of this on the PR: `lint.yml` (base slice), `tofu.yml` (lang
  slice), `pr-guards.yml` (single commit + Conventional Commit), `adr-guard.yml`
  (an ADR when the PR is labeled `architecture`).

## Architecture decisions

Record a major, cross-cutting, or expensive-to-reverse decision as an ADR in
[`docs/adr/`](docs/adr/README.md) — `just adr "Short decision title"` scaffolds
one. A PR labeled `architecture` must touch `docs/adr/` or `adr-guard.yml` fails.
Cite ADRs (`see ADR-0002`) rather than re-explaining them.

## Releases

Not applicable — no version scheme or release automation (no `CHANGELOG.md`, no
`cliff.toml`). `main` is the deployable state. If versioned releases are added
later, instantiate git.md's git-cliff flow then.
