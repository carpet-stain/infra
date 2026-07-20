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
- `versions.tf` — core + provider pins, R2 backend.
- `app.tf` — GitHub App credential propagation (ADR-0004): the private key
  and client ID, scoped to infra's own repo only (ADR-0005).
- `variables.tf` — apply-time inputs fed via `TF_VAR_*`, never a literal in
  a committed file (currently just the App's private key).
- `.github/actions/mint-app-token/` — composite action minting scoped
  App-installation tokens for CI (#32); `.github/workflows/tofu-plan.yml`
  and `tofu-apply.yml` are the saved-plan-on-merge pipeline (ADR-0003).
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

## Credentials

> Concrete realization of **git.md** (credential scope) and **github.md**
> (scoped PAT, explicit elevation) for this repo. See `.envrc.local.example`.

- Routine work uses a **direnv-scoped fine-grained PAT** (Contents / Pull
  requests / Actions / Issues read-write, plus **Secrets: Read-only** and
  **Variables: Read-only**, **not** Administration) via `.envrc.local` —
  never a full `gh auth login` session. So an agent driving `gh` can't
  touch repo settings or branch protection. Secrets/Variables: Read-only
  exist so `tofu plan` can refresh `github_actions_secret`/
  `github_actions_variable` resources (app.tf) without elevating — two
  separate fine-grained permission categories from each other and from
  Actions, each needed individually. GitHub never returns a secret's
  actual value at any permission level (only name/timestamps), so this
  doesn't expose anything the value-write path (Administration-adjacent,
  still elevated-only) doesn't already guard.
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

### CI secrets (`tofu-plan.yml`)

> Concrete realization of ADR-0003's saved-plan-on-merge model for this repo.

The plan-on-PR workflow (#24) needs its own read-only credential surface —
no write- or Administration-scoped secret ever reaches it:

| Secret                  | Purpose                                                                                                                                                                                                                 |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GH_TOKEN`              | The same routine scoped PAT from `.envrc.local` (Contents/PR/Actions read-write, not Administration) — the `github` provider's credential for reading live repo/label/ruleset state across every repo in `local.repos`. |
| `TF_STATE_PASSPHRASE`   | Same value as `.envrc.local` — decrypts the R2-backed state (ADR-0002) to compute a diff.                                                                                                                               |
| `R2_PLAN_ACCESS_KEY_ID` | Access key ID for a **new**, separate R2 API token scoped to **Object Read only** on the `tofu-state` bucket — not the human's own Read & Write token.                                                                  |
| `R2_PLAN_STORAGE_TOKEN` | The read-only R2 token's raw value; the workflow derives the S3 secret from it the same way `.envrc` does (`sha256`).                                                                                                   |
| `R2_ACCOUNT_ID`         | Same value as `.envrc.local` — builds the R2 S3 endpoint URL.                                                                                                                                                           |

These can't be tofu-managed (a repo can't provision its own CI's first
credentials via its own CI) — seed them once via the elevated session:

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set GH_TOKEN
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set TF_STATE_PASSPHRASE
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_PLAN_ACCESS_KEY_ID
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_PLAN_STORAGE_TOKEN
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_ACCOUNT_ID
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

`TF_STATE_PASSPHRASE` and `R2_ACCOUNT_ID` are shared with the plan job's
secrets above, not duplicated. Seed the two new ones the same way:

```sh
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_APPLY_ACCESS_KEY_ID
env -u GH_TOKEN -u GITHUB_TOKEN gh secret set R2_APPLY_STORAGE_TOKEN
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
  prettier, yamlfmt, envrc-sync, plus the OpenTofu `lang` slice (`tofu fmt
-check`, `tflint`, `trivy config`). Scope to one slice with `just lint --tag
base` or `--tag lang` — the exact slices `lint.yml` and `tofu.yml` run in CI.
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
