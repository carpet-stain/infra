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
- A local `tofu plan`/`apply` also reads the App-key and Cloudflare-token
  secrets from Bitwarden, so `.envrc.local` carries the `infra` machine
  account's `BW_ACCESS_TOKEN`, the org UUID (`BW_ORGANIZATION_ID`), and the
  `infra` Project UUID (`TF_VAR_bws_infra_project_id`) — see the Bitwarden
  bootstrap below and `.envrc.local.example`.
- Elevate explicitly only for the one action that needs admin:
  `env -u GH_TOKEN -u GITHUB_TOKEN gh ...` — both vars, since `.envrc` aliases
  `GITHUB_TOKEN` to the same scoped token, so dropping `GH_TOKEN` alone is a no-op.
- `just tofu plan` uses the routine scoped token (read-only); `just tofu-apply`
  needs the elevated session token (Administration scope).
- R2 backend credentials + `TF_STATE_PASSPHRASE` live in `.envrc.local`
  (gitignored), never committed. Losing the passphrase means re-importing, not
  recovering (ADR-0002).
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

### CI secrets (`tofu-plan.yml`)

> Concrete realization of ADR-0003's saved-plan-on-merge model for this repo.

The plan-on-PR workflow (#24) needs its own mostly-read-only credential
surface — no Administration-scoped GitHub secret reaches it. The one
non-read-only credential is `BWS_ACCESS_TOKEN`: the CI machine account is
read/write on `infra` (a plan only reads the two Bitwarden secrets, but the
free-tier three-account cap means the same account does the apply-side
writes — ADR-0008). It still can't reach `vended-tokens` at all.

| Secret                  | Purpose                                                                                                                                                                                                                 |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GH_TOKEN`              | The same routine scoped PAT from `.envrc.local` (Contents/PR/Actions read-write, not Administration) — the `github` provider's credential for reading live repo/label/ruleset state across every repo in `local.repos`. |
| `TF_STATE_PASSPHRASE`   | Same value as `.envrc.local` — decrypts the R2-backed state (ADR-0002) to compute a diff.                                                                                                                               |
| `R2_PLAN_ACCESS_KEY_ID` | Access key ID for a **new**, separate R2 API token scoped to **Object Read only** on the `tofu-state` bucket — not the human's own Read & Write token.                                                                  |
| `R2_PLAN_STORAGE_TOKEN` | The read-only R2 token's raw value; the workflow derives the S3 secret from it the same way `.envrc` does (`sha256`).                                                                                                   |
| `R2_ACCOUNT_ID`         | Same value as `.envrc.local` — builds the R2 S3 endpoint URL.                                                                                                                                                           |
| `BWS_ACCESS_TOKEN`      | The `infra` CI machine account's access token — configures the `bitwarden-secrets` provider (`BW_ACCESS_TOKEN`) so a plan can refresh the App-key and Cloudflare-token secrets (ADR-0008).                              |
| `BWS_ORGANIZATION_ID`   | The Bitwarden Organization UUID (`BW_ORGANIZATION_ID`) — Sensitive, so a secret, not a variable.                                                                                                                        |

The `infra` Project UUID rides along as the **variable** `BWS_INFRA_PROJECT_ID`
(`TF_VAR_bws_infra_project_id`) — not secret, just which Project to file
under. These can't be tofu-managed (a repo can't provision its own CI's first
credentials via its own CI) — seed them once via the elevated session:

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set GH_TOKEN
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set TF_STATE_PASSPHRASE
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_PLAN_ACCESS_KEY_ID
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_PLAN_STORAGE_TOKEN
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_ACCOUNT_ID
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set BWS_ACCESS_TOKEN
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set BWS_ORGANIZATION_ID
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_INFRA_PROJECT_ID
```

### CI secrets (`tofu-apply.yml`)

> Concrete realization of ADR-0003's saved-plan-on-merge model, apply half,
> and ADR-0004's App-token delegation, for this repo.

The apply-on-merge workflow (#25) writes state, so its R2 credential is
Read & Write, unlike the plan job's deliberately read-only one — but the
`github` provider's own write access comes from a per-job App-minted token
(#32's `mint-app-token`), not a standing secret:

| Secret                   | Purpose                                                                                                                                                   |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `R2_APPLY_ACCESS_KEY_ID` | Access key ID for the same Read & Write R2 API token already in `.envrc.local` — apply genuinely needs write, no further scoping down is meaningful here. |
| `R2_APPLY_STORAGE_TOKEN` | That token's raw value; derives the S3 secret the same way `.envrc` does (`sha256`).                                                                      |

`TF_STATE_PASSPHRASE`, `R2_ACCOUNT_ID`, `BWS_ACCESS_TOKEN`,
`BWS_ORGANIZATION_ID`, and the `BWS_INFRA_PROJECT_ID` variable are shared with
the plan job's secrets above, not duplicated — apply reuses the CI machine
account both to configure the provider and to read the App key via
`bitwarden/sm-action` (the private key is `vars.BWS_APP_KEY_SECRET_ID`) before
minting. Seed only the two R2 apply secrets here:

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_APPLY_ACCESS_KEY_ID
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_APPLY_STORAGE_TOKEN
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_APP_KEY_SECRET_ID
```

### CI secrets (`vend-token.yml`)

> Concrete realization of ADR-0008's token-vending half (#51) for this repo.

The scheduled vend workflow uses the **Vending** machine account (read on
`infra` for the App key, read/write on `vended-tokens` to publish), never the
CI account — the two must stay distinct so the vended path can't reach the CI
account's write grant on `infra`. It needs zero `GITHUB_TOKEN` permissions
(`permissions: {}`), so no GitHub-scoped secret at all:

| Secret / variable             | Purpose                                                                                                                 |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `BWS_VENDING_ACCESS_TOKEN`    | The Vending machine account's token — `access_token` for `sm-action`'s read and `BWS_ACCESS_TOKEN` for the `bws` write. |
| `BWS_VENDED_SECRET_ID` (var)  | UUID of the `vended-tokens` JSON secret the workflow overwrites each run.                                               |
| `BWS_APP_KEY_SECRET_ID` (var) | Shared with the apply job above — the App-key secret's UUID in `infra`.                                                 |
| `GH_APP_CLIENT_ID` (var)      | Shared with the apply job — the App's client ID (not secret).                                                           |

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set BWS_VENDING_ACCESS_TOKEN
env -u GH_TOKEN -u GITHUB_TOKEN gh variable set BWS_VENDED_SECRET_ID
```

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
  `.envrc` builds from `TF_STATE_PASSPHRASE`, key material in the environment
  only. Never commit state, plans, or `.terraform/` (all gitignored); the
  lockfile _is_ committed.
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
