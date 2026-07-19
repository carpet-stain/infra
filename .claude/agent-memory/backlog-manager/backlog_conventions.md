---
name: backlog-conventions
description: Issue-writing, template, milestone, and git-workflow conventions to mirror when filing infra issues
metadata:
  type: project
---

**Issue templates** (`.github/ISSUE_TEMPLATE/`): `bug.yml` (what happened / repro / env),
`feature.yml` (problem / proposal+alternatives / acceptance), `spike.yml` (question / timebox /
expected outcome). Blank issues enabled. Match these section shapes in issue bodies. Each template
auto-applies its base label (bug → `bug`, feature → `enhancement`, spike → `spike`).

**Title style (settled 2026-07-18):** issue titles use `type(scope): imperative lowercase
description`, matching commits. This is the standard for infra issues.

**Commit/issue scopes (now formalized in AGENTS.md):** AGENTS.md exists on `origin/main` and its
team-convention table defines scopes — `repos` (repos.tf map), `tofu` (providers/backend/versions),
`ci` (.github/workflows), `docs` (README/ADRs), `scripts`, `deps` (dependabot). Scope is optional
and pr-guards.yml validates only its charset, not the set — but use this table. AGENTS.md wins over
generic git rules; read `git show origin/main:AGENTS.md` for the full workflow.

**Git workflow** (from global rules, LOCAL-WINS if a repo doc appears): short-lived feature
branches off protected `main`, open a draft PR at first commit (`git pr --draft`), squash to one
Conventional Commit, rebase-merge only (enforced by `single commit` + `conventional commit` +
`adr guard` status checks). Reference issues from PRs with `Closes #NNN`.

**Milestones:** none — decision (2026-07-18) is a flat backlog ordered by `priority:` labels only,
no milestones. **needs-info state** = `blocked` label + an explaining comment, no separate label.
The same `blocked` label also covers dependency-blocked (not just needs-info) — e.g. #25/#26 pair
it with a native `--blocked-by` link (see below) plus a "Blocked on #N, don't start before it
resolves" line in the body; the label always needs a reason somewhere, comment or native link, per
[[label-taxonomy]]. No project board (`has_projects = false`). Workflow state lives in labels, not
a board.

**Epic↔child linking:** `gh issue create --parent <N>` sets the sub-issue relationship directly at
creation (no separate attach step needed — simpler than the GraphQL `addSubIssue` mutation this
note originally described by hand). Confirmed 2026-07-18 that the routine scoped `GH_TOKEN` (no
Admin) can do this — no elevation needed. Don't duplicate with a manual `- [ ] #N` checklist in the
epic body; GitHub renders the live sub-issue list. Same pattern for dependency links: `gh issue
create --blocked-by <N>` (or `gh issue edit --add-blocked-by <N>` / `--remove-blocked-by <N>` after
the fact) sets the native `blocked-by`/`blocking` relationship GitHub now renders in
`gh issue view`.

**Plan-review finding vs. an already-accepted ADR — confirmed pattern (2026-07-19, epic #28).**
If a plan-review pass surfaces a real gap in an ADR that's already accepted, mid-implementation:
don't let the implementation issue silently diverge from what the ADR says. Revert the issue's
body to match the ADR's literal text, then file a *separate* spike issue to gate the
reconsideration deliberately (`architecture` + `spike` labels, priority reflecting how load-bearing
the gap is) rather than deciding it inline in the implementation issue. If the spike lands on a
different model, resolve it with a **new ADR that amends/supersedes the original** — never edit
the accepted ADR's text in place (`docs/adr/README.md`'s own rule: a later decision gets its own
ADR so the rejected path stays visible in the record instead of being edited out). Once the new
ADR lands: close the spike with a comment that reads as a deliberate resolution (rationale, not
just a link), correct every implementation issue that referenced the old model, and drop the
native `blocked-by` link to the now-closed spike (leave any *other* still-open blockers in place).
Confirmed end to end: ADR-0004 (blanket key propagation) → plan review on epic #28 caught the
raw-key-holder gap → #31 reverted + spike #34 filed → ADR-0005 amends ADR-0004 (infra-only
propagation) → #34 closed with rationale, #31/#32/#28 corrected. See [[open-work]]'s epic #28
entry for the specifics of this instance.

**Backlog state:** first issues filed 2026-07-18 — Epic #6 (cloudflare) with children #7-#10, Epic
#11 (ci/cd apply pipeline). #11's spike #12 decided 2026-07-19 (ADR-0003); its children are now
#24-#26, see [[open-work]] for the split and #19 blocker. Epic #28 (GitHub App PAT provisioning,
ADR-0004/ADR-0005) is the other major thread — see [[open-work]]. See [[open-work]] for the
pending `theme: cloudflare` label follow-up.

See [[label-taxonomy]], [[repo-overview]], and [[open-work]].
