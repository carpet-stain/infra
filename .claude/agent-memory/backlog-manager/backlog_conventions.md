---
name: backlog-conventions
description: Issue-writing, template, milestone, and git-workflow conventions to mirror when filing infra issues
metadata:
  type: reference
---

**Issue templates** (`.github/ISSUE_TEMPLATE/`): `bug.yml` (what happened / repro / env),
`feature.yml` (problem / proposal+alternatives / acceptance), `spike.yml` (question / timebox /
expected outcome). Blank issues enabled. Match these section shapes in issue bodies. Each template
auto-applies its base label (bug → `bug`, feature → `enhancement`, spike → `spike`).

**Title style (settled 2026-07-18):** issue titles use `type(scope): imperative lowercase
description`, matching commits. This is the standard for infra issues.

**Commit/issue scopes:** AGENTS.md's Commits table is the source — scope is optional and
pr-guards.yml validates only its charset, not the set, but use that table. AGENTS.md wins over
generic git rules.

**Git workflow:** AGENTS.md's Branch & PR model owns the mechanics — don't restate them here.
Backlog-specific addition: reference issues from PRs with `Closes #NNN`.

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

**Cross-repo blocking links work (confirmed 2026-07-25, infra#76 → dotfiles#377):**
`--add-blocked-by`/`--add-blocking` accept a full issue URL, not just a same-repo number —
`gh issue edit 76 --repo carpet-stain/infra --add-blocking
"https://github.com/carpet-stain/dotfiles/issues/377"` set a real `blocking:
carpet-stain/dotfiles#377` link, no elevation needed, same routine scoped token. Don't assume
same-repo-only and default to a comment-only cross-ref — try the native link first for any
dependency crossing infra↔dotfiles.

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
Confirmed working end to end via epic #28 (ADR-0004 amended by ADR-0005) — see [[open-work]]'s
epic #28 entry for that instance, not restated here.

**Credential-scoping check for CI/App-token issues:** every Actions job already gets a free
repo-scoped `GITHUB_TOKEN`; that covers same-repo CI work. Before scoping an issue toward an
App-minted token, check whether `GITHUB_TOKEN` already covers it — the App is only for cross-repo
or elevated (`administration`-scope) work.

See [[label-taxonomy]], [[repo-overview]], and [[open-work]].
