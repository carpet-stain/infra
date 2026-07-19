# 0003. CI apply pipeline: saved-plan-on-merge model

Date: 2026-07-19

## Status

Accepted

## Context

`tofu apply` runs today from a human's elevated local session (`just tofu-apply`),
never in CI — ADR-0002's stance, adopted because there was no code-managed way to
hand CI an elevated (Administration-scope) credential. Epic #11 asks for a
`tofu plan` shown on the PR for review, then `tofu apply` against `main` on merge.
Spike #12 scoped the model decision: apply the exact saved plan (Option 1,
the Atlantis/HCP-Terraform-remote-run shape) vs. re-plan fresh at merge time
(Option 2). #12 recorded a leaning toward Option 2 for this repo's low-velocity,
single-account scale, explicitly as "a leaning to validate, not a foregone
conclusion."

Two things changed that leaning:

- **#12's stated blocker against Option 1 is already resolved.** It lists "a
  saved plan file contains secrets in plaintext" as a hard constraint requiring
  OpenTofu ≥1.10 plan-file encryption. `.envrc`'s `TF_ENCRYPTION` block already
  sets `plan { method = aes_gcm.state; enforced = true }` (ADR-0002) — plan
  encryption has been enforced since the state-encryption decision, just unused
  until now because no CI plan step exists yet.
- **Industry precedent leans the other way at this repo's scale.** Atlantis
  locks state at plan time and applies that exact locked plan — never re-plans.
  DIY GitHub Actions guides (the closest analog to a hand-rolled pipeline, no
  TACO server) converge on saved-plan-artifact as the safer default, because
  OpenTofu's own stale-plan check (state serial mismatch) makes a saved plan
  fail _safely_ if state moved underneath it — re-plan-on-merge has no
  equivalent backstop. HCP Terraform is the one counterexample (its PR-time
  speculative plan is read-only/informational, and merging triggers a fresh
  plan+apply run) — but it's a managed platform with lock/queue machinery this
  repo doesn't have and isn't building.

The usual cost of the saved-plan pattern — stashing an artifact across separate
CI runs, keying it, cleaning it up — is unusually cheap here:

1. This repo's branch workflow (AGENTS.md) already requires rebasing onto
   `main` before finalizing, and GitHub's rebase-merge on an already-rebased
   branch is a fast-forward. The commit SHA that lands on `main` is therefore
   bit-identical to the PR's last commit SHA — the merge-triggered apply job
   can deterministically fetch "the plan artifact from the run that already
   planned this exact SHA" via the GitHub API. No `workflow_run` indirection,
   no separate keying scheme.
2. GitHub Actions artifacts have native `retention-days` expiry — a short
   retention (1–2 days) auto-cleans abandoned or superseded plans. No custom
   R2 object lifecycle to build.

Adopting a TACO (Atlantis, Spacelift, Digger) instead of hand-rolling this in
GitHub Actions was also considered. Rejected for the same reason ADR-0002
rejected Scalr and Terragrunt: disproportionate machinery — a server to run
(Atlantis) or a paid platform (Spacelift) — for a solo, single-account repo
already small enough to fit one root module.

One consequence holds regardless of which option was chosen: no CI job reads
state today (`tofu.yml` only runs fmt/tflint/trivy). Adding a plan step means
`TF_STATE_PASSPHRASE` and an R2 read credential become new GitHub Actions
secrets — today only a human's `.envrc.local` has them. That secret surface
is a fact of building this pipeline at all, not a consequence of Option 1
specifically.

## Decision

**Option 1 — apply the exact saved plan.**

- **Plan (on every PR push):** a workflow runs `tofu plan -out=tfplan`
  under the routine scoped token (read-only) plus a new plan-scoped R2
  read credential and `TF_STATE_PASSPHRASE`. The resulting `tfplan` file
  — already encrypted by the enforced `TF_ENCRYPTION` block — uploads as a
  GitHub Actions artifact named after the commit SHA
  (`tfplan-${{ github.sha }}`), `retention-days: 2`. A second step renders
  `tofu show -no-color tfplan` and **updates** (not appends) a single PR
  comment, so repeated pushes replace the comment rather than accumulating
  one per push.
- **Merge (push to `main`):** a workflow in a `tofu-apply-main` concurrency
  group (`cancel-in-progress: false` — applies queue, they don't cancel)
  looks up the most recent successful plan-workflow run for `github.sha`
  via the GitHub API and downloads its `tfplan-${{ github.sha }}` artifact.
  If no matching artifact exists (retention expired, or the plan job never
  ran for this SHA), the job fails loudly rather than silently re-planning
  — that gap is what the escape hatch below is for. Otherwise it runs
  `tofu apply tfplan` under the elevated credential
  (`env -u GH_TOKEN -u GITHUB_TOKEN gh auth token`, mirroring
  `justfile.lang`'s `tofu-apply` locally; the CI equivalent is #19's concern,
  not decided here).
- **Staleness backstop:** OpenTofu itself refuses to apply a plan whose
  state serial has moved since the plan was generated. Combined with the R2
  backend's `use_lockfile` locking (already enforced by ADR-0002), a
  concurrent manual `just tofu-apply` or another PR's merge can't corrupt
  state — worst case the automated apply fails and needs a re-plan, not a
  bad apply.
- **Failure/retry runbook:** apply is not transactional but is idempotent.
  A partial failure leaves state at whatever succeeded; fix forward with a
  new PR (the next plan shows only the remaining delta) rather than
  reverting — merge already landed the code on `main`, so a revert makes
  OpenTofu try to _destroy_ what partially applied. For a case that needs an
  apply outside the normal PR flow (retry after a fix-forward merge without
  new code changes, or recovering from the "no matching artifact" failure
  above), a `workflow_dispatch` "apply main" job runs a fresh plan+apply
  pair directly against `main`, gated on the same elevated credential and
  concurrency group. A crashed apply that leaves a stale R2 lockfile is
  cleared with `tofu force-unlock <id>`, done deliberately and by hand — not
  automated, since an automated unlock defeats the lock's purpose. Apply
  logs are CI job output, retained by GitHub's normal workflow-run
  retention; no separate log shipping.

This ADR decides the model; it does not implement it. Follow-up
implementation issues (the plan workflow, the apply workflow, the
comment-update step, the `workflow_dispatch` escape hatch) are filed under
epic #11 per its stated scope. The apply workflow is blocked on #19 (PAT
provisioning spike) resolving how CI obtains an elevated, Administration-scope
credential at all — ADR-0002's "never in CI" was adopted specifically because
that mechanism didn't exist yet. The plan workflow has no such blocker: it
only needs read-scoped credentials, which the routine scoped token plus a new
read-only R2 credential already cover.

## Alternatives considered

- **Option 2 — re-plan on merge.** Simpler (no artifact upload/download,
  no SHA-keyed lookup), and what HCP Terraform itself does. Rejected because
  it drops the one thing OpenTofu gives for free: a stale saved plan fails
  the apply outright, while a stale re-plan just silently applies a
  different diff than what was reviewed. #12's original leaning toward this
  option didn't have the fast-forward-SHA and native-artifact-retention
  points above, which remove most of Option 1's usual implementation cost —
  the tradeoff isn't as close as originally scoped.
- **Adopt a TACO (Atlantis, Spacelift, Digger).** Rejected for
  disproportionate machinery at solo, single-account scale — same reasoning
  ADR-0002 applied to Scalr and Terragrunt. Revisit if this account ever
  manages multiple repos' applies concurrently enough that comment-driven
  locking and drift detection earn their operational cost.
- **`workflow_run`-triggered artifact hand-off** instead of SHA-keyed
  lookup. Rejected as unnecessary indirection here — it exists mainly to
  let a privileged workflow safely consume an artifact from an unprivileged
  fork-PR workflow, and this repo doesn't accept fork PRs. A direct API
  lookup by `github.sha` is simpler and sufficient.

## Consequences

CI gains a new secret surface — `TF_STATE_PASSPHRASE` and an R2 read
credential for the plan job, plus whatever #19 decides for the apply job's
elevated credential — where previously only a human's `.envrc.local` held
these. The plan job must stay read-only (no risk from a compromised
routine-scoped-token PR run, consistent with the two-tier auth model
ADR-0002 already established). Every PR now carries a live, auto-updating
plan comment instead of requiring a human to run `just tofu plan` locally
before review. Losing the fast-forward property (e.g. someone merges without
rebasing first) breaks the SHA-keyed artifact lookup — that failure mode is
caught by the "no matching artifact" hard-fail, not by a silent fallback to
re-planning. This ADR does not change ADR-0002's stance that the _elevated
credential itself_ stays out of a human's hands only once #19 lands; until
then, epic #11's apply workflow is filed but not runnable.
