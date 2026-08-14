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
- `versions.tf` — core + provider pins (`github`, `cloudflare`, `aws`), R2
  backend.
- `app.tf` — GitHub App credential wiring (ADR-0004/0005): the manual
  registration/installation record and the retired credential homes'
  `removed{}` blocks. The key itself lives in SSM
  (`/infra/gh-app-private-key`, ssm.tf). The client ID variable isn't here —
  set by hand (`gh variable set GH_APP_CLIENT_ID`), since no App-minted
  token can refresh a `github_actions_variable` resource
  (`actions/create-github-app-token` has no permission for it at all).
- `dns.tf` — Cloudflare zones and DNS records as config-as-data (#9).
- `variables.tf` — apply-time inputs fed via `TF_VAR_*`, never a literal in
  a committed file (the aws provider's local key halves, the Cloudflare
  account id).
- `ssm.tf` — the `/infra/*` SSM parameters (ADR-0010, #121): existence and
  metadata only, values hand-populated and `ignore_changes`-ignored. No
  `/runtime/*` parameters by design — the vend workflow creates its own.
- `iam/` — the bootstrap-only root module (ADR-0010): OIDC provider, the
  per-consumer IAM roles, the two tier KMS keys. Own state (second key in
  the same R2 bucket), applied only via `just tofu-iam` with the bootstrap
  key — never by CI, so no CI role ever holds `iam:*`/`kms:Put*`. The one
  legitimate directory (see #121's layout comment); AWS resources otherwise
  land as root-level files.
- `.github/actions/mint-app-token/` — composite action minting scoped
  App-installation tokens for CI (#32), used by `tofu-plan.yml`,
  `tofu-apply.yml`, `tofu-apply-dispatch.yml`, `tofu-drift.yml`, and
  `vend-token.yml` (a separate, narrower repo list — see Credentials).
- `.github/actions/read-ssm-params/` — composite action reading `/infra/*`
  SSM parameters through the job's OIDC-assumed role (#122, ADR-0010),
  used by the four tofu workflows in place of `bitwarden/sm-action`.
- `.github/workflows/` — `tofu-plan.yml`/`tofu-apply.yml` are the
  saved-plan-on-merge pipeline (ADR-0003); `vend-token.yml` publishes a
  scoped, rotating token to SSM's `/runtime/vended-token` for local/agent
  shells (#51/ADR-0008 for the vending model, #124/ADR-0010 for the store).
- `docs/adr/` — architecture decisions (`.adr-dir` points here).
- `scripts/` — `with-infra-secrets.sh` (the Keychain-gated SSM fetch every
  local tofu run rides), `new-adr.sh`, `check-envrc-local-example.sh`,
  `check-workflow-secrets.sh` (ADR-0011's Secrets guard).
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
`just tofu force-unlock <id>` (the id is in the error message; only the
Keychain-gated backend creds are needed) — deliberately not automated,
since an automated unlock defeats the lock's purpose.

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

Where does a secret go → ADR-0016's decision tree (SSM / iCloud /
Bitwarden vault / Keychain).

- Routine work uses the **fine-grained dev PAT** (Contents / Pull requests /
  Actions / Issues read-write, **not** Administration) — gh's default
  keyring credential (#151), user-global, so the ambient posture in every
  repo and bare shell is the minimal token. `.envrc` derives
  `GH_TOKEN`/`GITHUB_TOKEN` from `gh auth token` for the tofu github
  provider and git-cliff; no token literal lives in any repo file. An agent
  driving `gh` still can't touch repo settings or branch protection.
  Secrets/Variables: Read-only used to be needed so `tofu plan` could
  refresh the App-key `github_actions_secret`, but that key left native
  secrets long ago (#47; it lives in SSM now, ADR-0010) and no
  `github_actions_secret`/`_variable` resource is tofu-managed anymore, so
  neither category is required now.
- Run local `tofu` through `just tofu` / `just tofu-apply` only, never bare.
  The elevated backend secrets (state passphrase, R2 read/write creds) are
  fetched from SSM at invocation by `scripts/with-infra-secrets.sh` (#126,
  ADR-0010), gated behind a macOS Keychain prompt — not exported ambiently
  by direnv (#59, ADR-0009), so a stray agent shell in this repo never
  holds them. The `infra-local-apply` IAM user's access key lives in the
  login Keychain (item `infra-aws-local-apply`), added without an app ACL
  so each read prompts; the same key rides explicit `TF_VAR`s into the aws
  provider (the `AWS_*` env names locally carry the R2 backend
  credentials). `.envrc.local` keeps only the routine `GH_TOKEN` and the
  Cloudflare identifiers. See `.envrc.local.example`.
- `just tofu-iam` (the trust-roots module) runs the wrapper in
  `--bootstrap` mode instead: the `infra-aws-bootstrap` break-glass key
  (docs/BOOTSTRAP.md), reactivated in the console for the run and
  deactivated after — routine work never touches it. CI holds no AWS
  secret at all: each workflow assumes its OIDC role
  (`vars.AWS_PLAN_ROLE_ARN` / `vars.AWS_APPLY_ROLE_ARN` /
  `vars.AWS_VEND_ROLE_ARN`) per job, creds ride the env chain (never Tofu
  variables — a saved-plan apply would replay them stale), and the R2
  backend creds ride a runner-local `r2-backend` AWS profile referenced
  via `-backend-config` — never raw keys there, which embed in the saved
  plan and put the plan job's read-only pair on the merge apply's state
  write (#164).
- Elevate explicitly only for the one action that needs admin:
  `scripts/with-infra-secrets.sh --gh-admin env -u GH_TOKEN <cmd>` fetches the
  fine-grained admin PAT from `/infra/gh-admin-token` behind the same Keychain
  gate and exports it as `GITHUB_TOKEN` (ADR-0013). Drop `GH_TOKEN` for
  gh-driving commands — gh prefers it over `GITHUB_TOKEN`; the tofu provider
  reads only `GITHUB_TOKEN`, so `just tofu-apply` needs no unset.
- `just tofu plan` uses the routine `GH_TOKEN` for the github provider (read);
  `just tofu-apply` rides `--gh-admin` for the Administration-scoped token —
  both wrapped by the Keychain-gated backend-secret fetch, one prompt. Losing
  the passphrase means re-importing, not recovering (ADR-0002); it lives in
  SSM now (`/infra/tf-state-passphrase`).
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
- CI's own App-token minting (`.github/actions/mint-app-token/`, consumed by
  `tofu-plan.yml`/`tofu-apply.yml`/`tofu-apply-dispatch.yml`/`tofu-drift.yml`)
  scopes each token to a hardcoded `repositories:` CSV, separate from
  `local.repos` itself — a new repo needs adding to that CSV in all four
  workflows too, or CI can read it (plan/drift) but never write to it (apply
  403s: confirmed live when #22 adopted `golden-ratio-dual-gate` before this
  step was done).

### Machine secrets — AWS SSM + IAM

> Concrete realization of ADR-0010 for this repo (superseding ADR-0008/0009's
> Bitwarden store, decommissioned at #126). Values live in SSM Parameter
> Store; the role×path matrix is code (`iam/main.tf`), applied only via
> `just tofu-iam` with the bootstrap key.

Two tiers, two KMS keys, path as the boundary: `/infra/*` (crown jewels —
App key, admin PAT, state passphrase, R2 pairs, Cloudflare token, B2
management key (ADR-0017 — unconsumed until #159's wiring);
`alias/infra-secrets`)
and `/runtime/*` (the rotating vended token; `alias/runtime-secrets`). Every
identity needs both the SSM path grant and `kms:Decrypt` on that tier's key —
two independent fences. The audit invariant (ADR-0010 as amended by #126):
**no silently-readable local identity resolves `kms:Decrypt` on
`alias/infra-secrets`**, and local and CI identities share no credential.

| Identity                            | Kind      | Surface                          | Held as                                                                                       |
| ----------------------------------- | --------- | -------------------------------- | --------------------------------------------------------------------------------------------- |
| `infra-plan-read`                   | OIDC role | `/infra/*` read                  | no credential — assumed per job (plan/drift)                                                  |
| `infra-apply`                       | OIDC role | `/infra/*` read/write            | no credential — assumed per job (apply/dispatch)                                              |
| `infra-vend-write`                  | OIDC role | App-key read, vended-token write | no credential — assumed per job (vend)                                                        |
| `infra-local-apply`                 | IAM user  | `/infra/*` read/write            | Keychain `infra-aws-local-apply`, prompt-gated (no `-A`)                                      |
| `infra-local-read`                  | IAM user  | `/runtime/*` read                | Keychain (dotfiles' `infra-aws-local-read`), silent (`-A`)                                    |
| `infra-bootstrap`                   | IAM user  | IAM/KMS/SSM trust roots          | Keychain `infra-aws-bootstrap`, prompt-gated, deactivated                                     |
| `infra-console-admin`               | IAM user  | console `*:*`, MFA-enforced      | no access key — console password + MFA in iCloud, recovery codes in Bitwarden (ADR-0015/0016) |
| `project-starter-template-e2e-read` | OIDC role | vended-token read (single param) | no credential — assumed per job, cross-repo consumer (#147)                                   |

Daily console work runs as `infra-console-admin` (console-only `*:*`
admin, MFA enforced by policy, no programmatic key — ADR-0015); root is
break-glass-only (billing, close-account, root-only IAM). It sits in the
escalation class with `infra-bootstrap` — fenced by human ceremony, not
the path/key boundary (`iam/main.tf`'s header fence (b)).

Parameter existence/metadata is tofu-managed (`ssm.tf`); values are
hand-populated and `ignore_changes`-ignored. Periodic audit items: the
bootstrap key still deactivated and still needed; `infra-vend-write`'s
unattended crown-jewel read; the two fences above; root still
break-glass-only; the elevated Keychain
items still prompting on every read (`audit-keychain-gate`, dotfiles-
deployed since the items are machine state, #167 — the gate was found
silently disabled once).

**If vending stops:** scheduled workflows auto-disable after 60 days of repo
inactivity. Local shells then loud-fail on a stale token — the designed
degradation. Re-enable `vend-token.yml` from the Actions tab (or run it once
via `workflow_dispatch`) to resume.

### CI secrets and variables

> Realizes ADR-0010 on top of ADR-0003's saved-plan model: CI holds **no
> native GitHub secret at all** — each workflow assumes its OIDC role per
> job and fetches secret values from SSM at runtime (`read-ssm-params`;
> vend reads its one parameter inline). Enforced by the `workflow-secrets`
> lefthook job (`scripts/check-workflow-secrets.sh`, #143): any
> `secrets.<name>` reference beyond `GITHUB_TOKEN` fails lint. See ADR-0011.

- Fetched from SSM: `TF_STATE_PASSPHRASE`, `R2_ACCOUNT_ID`, the R2 pair
  (plan/drift read `R2_PLAN_*` — a separate **Object Read only** token;
  apply and dispatch read the read/write `R2_APPLY_*`),
  `GH_APP_PRIVATE_KEY`, and the Cloudflare token — split the same way
  (#144): plan/drift read the read-only `cloudflare-api-token-ro`, apply
  and dispatch the edit-scoped `cloudflare-api-token` (#9, the same token
  `dns.tf`'s provider reads locally). Apply and dispatch mint an elevated
  App token from the key; the plan job mints an
  `administration:read`+`issues:read` token for the provider (the routine
  PAT is retired, #59) and posts its PR comment via the ephemeral
  `github.token`. vend-token.yml reads only the App key, inline (#124) —
  its role's grant is the singular GetParameter on that one ARN.
- **Variables** (not secret): `GH_APP_CLIENT_ID`, `CLOUDFLARE_ACCOUNT_ID`
  (#9 — account-identifying, fed straight to
  `TF_VAR_cloudflare_account_id`), and the AWS role ARNs (ADR-0010, the
  trust policy's sub conditions are the gate): `AWS_PLAN_ROLE_ARN`,
  `AWS_APPLY_ROLE_ARN`, `AWS_VEND_ROLE_ARN`.

Seed the variables once with the admin token
(`scripts/with-infra-secrets.sh --gh-admin env -u GH_TOKEN gh variable set …`,
ADR-0013 — its Variables write exists for exactly this); the from-zero order
lives in `docs/BOOTSTRAP.md`. None of this can be
tofu-managed — a repo can't provision its own CI's first credentials via
its own CI. No Dependabot secrets mirror remains: #89's exposure was the
plan job reading `secrets.*` on a Dependabot-actored run, and no workflow
reads `secrets.*` anymore.

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
  `scripts/with-infra-secrets.sh` builds at invocation from the SSM-fetched
  `TF_STATE_PASSPHRASE` (#59/ADR-0009, #126/ADR-0010), key material in the
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
  prettier, yamlfmt, gitleaks, shfmt, shellcheck, justfile-format,
  editorconfig-checker, envrc-sync, comment-concision, workflow-secrets, plus the OpenTofu
  `lang` slice (`tofu fmt -check`, `tflint`, `trivy config`). Scope to one
  slice with `just lint --tag base` or `--tag lang` — the exact slices
  `lint.yml` and `tofu.yml` run in CI.
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
