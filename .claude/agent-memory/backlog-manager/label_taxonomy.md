---
name: label-taxonomy
description: The infra repo's label scheme, its terraform source-of-truth, and when each label applies
metadata:
  type: project
---

Labels are **terraform-governed**: the source of truth is `local.labels` in `repos.tf`, applied
to every managed repo by `github_issue_label.this` in `main.tf`. The live label set on the infra
repo matches that map exactly (21 labels).

**Why it matters:** the same canonical set is applied to ALL managed repos (dotfiles + infra), so
some labels are dotfiles-oriented and rarely apply to infra. Creating a label only via `gh label
create` would drift from terraform and get reverted on the next apply — **new labels must be added
to `repos.tf`'s `local.labels` and applied**, not created ad hoc. Propose label additions to the
user; don't `gh label create` behind terraform's back.

**How to apply — classify every issue with a type + a priority:**

- Type: `bug`, `enhancement`, `documentation`, `spike` (time-boxed research), `architecture`
  (significant → requires an ADR; also drives `adr-guard.yml`), `epic` (large multi-part).
- Priority (3-level): `priority: high` (act soon), `priority: medium` (normal queue),
  `priority: low` (someday).
- Modifiers: `agent-ready` (mechanical + verifiable, no human judgment needed), `good first
  issue`, `blocked` (reason in a comment / native blocked-by), `duplicate`, `wontfix`,
  `release-watch` (from the dependency release watcher), `upstream-review` (ideas from z0rc/dotfiles
  fork — dotfiles-oriented).
- Themes (`theme:` prefix): `agent-config` (Claude rules/skills/AGENTS.md), `credentials`
  (token/credential scoping), `testing` (CI/e2e/workflow-run infra) — these three are the
  infra-relevant ones. `tool-review`, `xdg-hygiene`, `upstream-review` are dotfiles-oriented and
  rarely fit an infra issue.

See [[repo-overview]] and [[backlog-conventions]].
