# 0007. Key saved-plan artifacts by tree hash, not commit SHA

Date: 2026-07-20

## Status

Accepted — amends ADR-0003's artifact-keying mechanism; the saved-plan
model itself (apply the exact plan reviewed on the PR, never re-plan at
merge) is unchanged.

## Context

ADR-0003 keys the plan artifact `tofu-plan.yml` produces by
`${{ github.sha }}` — the PR's head commit — and `tofu-apply.yml` looks it
up the same way at merge time, on the assumption that "GitHub's rebase-merge
on an already-rebased branch is a fast-forward," so the merge SHA would
equal the SHA the plan ran for.

That assumption was wrong, unconditionally — verified empirically, not
just re-read from docs. Checked across every merged PR to date:

| PR  | head SHA (what `tofu-plan.yml` ran for) | merge SHA (what `tofu-apply.yml` looked up) |
| --- | --------------------------------------- | ------------------------------------------- |
| #53 | `3f7c045`                               | `9d93c38`                                   |
| #54 | `027e237`                               | `250619b`                                   |
| #55 | `e8b08d0`                               | `55ba038`                                   |

Never equal, on any of them — including merges where the branch was fully
up to date and strict branch protection (`main.tf`'s
`strict_required_status_checks_policy = true`) was already active. GitHub's
rebase-merge always rewrites the commit's committer info (a new timestamp,
stamped at merge time) when it lands a PR, even when no actual rebasing
was needed to make the branch current. That rewrite changes the commit
SHA regardless. Strict mode closes a real gap (content drift when `main`
moves between a PR's last push and its merge) but was never going to fix
this — it's a different problem, one that exists on every merge, not just
ones where `main` moved.

Practical impact: `tofu-apply.yml`'s artifact lookup has failed on every
run to date. The failure mode is the designed-safe one (loud error, no
silent re-plan, per ADR-0003) — nothing was ever applied incorrectly —
but the automatic merge-triggered path has never actually completed
successfully; every real apply so far has gone through the
`workflow_dispatch` escape hatch instead.

What does survive the rewrite: the commit's **tree** — the actual file
content — is byte-identical between the PR's last commit and the merge
commit, confirmed directly (`git rev-parse HEAD^{tree}` matches on both
sides of every pair above). This makes sense: `tofu plan`'s output only
ever depends on file content, never on commit metadata, so the tree hash
was always the semantically correct identifier — the commit SHA was
convenient, not correct.

## Decision

Key the plan artifact by tree hash (`git rev-parse 'HEAD^{tree}'`), not
commit SHA, in both directions:

- `tofu-plan.yml` computes the tree hash after running `tofu plan` and
  uploads `tfplan-<tree-hash>` instead of `tfplan-<commit-sha>`.
- `tofu-apply.yml` computes its own tree hash after checkout and looks up
  an artifact by that name directly via the artifacts-list API
  (`GET /repos/{owner}/{repo}/actions/artifacts?name=tfplan-<tree-hash>`),
  taking the most recent non-expired match. This replaces the old
  "find the `tofu-plan.yml` run for this commit SHA, then download its
  artifact" two-step — an artifact's own `workflow_run.id` (part of the
  artifacts-list response) is enough to download it directly, no separate
  run lookup needed.

The "no matching artifact" failure path, the escape hatch, and everything
else ADR-0003 decided are unchanged — only the key changed.

## Alternatives considered

- **Resolve merge SHA → PR → head SHA at apply time**, via GitHub's
  commit↔PR association API. Works, but adds an API round-trip and a
  layer of indirection the tree hash gets for free — content identity is
  the property that actually matters, PR association is one more hop away
  from it.
- **Abandon saved-plan, re-plan on merge** — reopens ADR-0003's original
  Option 2, which it already weighed and rejected (loses the stale-plan
  safety net; see ADR-0003's Alternatives). Nothing about this bug is a
  flaw in the saved-plan model itself — the model's guarantee (apply
  exactly what was reviewed) still holds, cryptographically, once the key
  is content-based instead of commit-based. Not worth reopening a
  settled, still-correct decision to fix a keying bug.

## Consequences

No secret-surface or credential change — this is a lookup-mechanism fix,
not a model change. The PR comment now also shows the tree hash alongside
the commit SHA, for anyone debugging a future lookup mismatch. The
artifacts-list API call is a small addition to `tofu-apply.yml`'s
credential surface (still the default ephemeral token, `actions: read` —
already granted, nothing new). Verification for this fix specifically
means watching an actual merge-triggered `tofu-apply.yml` run go green —
the epic's original acceptance was checked against plan and
`workflow_dispatch` runs, and the merge path's success case had never
actually executed, which is how this shipped unnoticed.
