---
name: dotfiles-repo
description: carpet-stain/dotfiles backlog conventions — labels, templates, epic/ADR structure — distinct from infra's
metadata:
  type: project
---

`carpet-stain/dotfiles` is a separate repo from `infra` but shares the same **terraform-governed
canonical label set** (infra's `repos.tf` `local.labels`, applied to both via `setproduct` — see
infra's [[label-taxonomy]]). Same rule applies here: never `gh label create` directly, propose
additions via infra's `repos.tf`.

**Labels actually used here** (2026-07-18 snapshot): `bug`, `enhancement` (covers `feat`-titled
issues too — no separate `feature` label), `documentation`, `spike`, `epic`, `architecture`
(ADR-required), `priority: high/medium/low`, `theme: agent-config`, `theme: testing`, `theme:
tool-review`, `theme: xdg-hygiene`, `theme: credentials`, `blocked`, `agent-ready`, `good first
issue`, `release-watch` (dependency watcher), `upstream-review` (z0rc/dotfiles fork ideas),
`duplicate`, `wontfix`. Dotfiles-specific themes (`tool-review`, `xdg-hygiene`, `upstream-review`,
`release-watch`) rarely fit infra issues and vice versa.

**Issue templates** (`.github/ISSUE_TEMPLATE/`): `bug.md`, `feature.md` (Problem / Acceptance /
Non-goals), `spike.md` (Question / Time box / Deliverable). Title prefills `feat(<scope>): ` /
`spike(<scope>): `. Declared scopes in AGENTS.md: `zsh, zellij, git, nvim, macos, theme, python`
— but this list has drifted from actual usage (tracked by open issue #262); in practice `claude`
(agent-config work) and `terraform` also appear as scopes, and CI/workflow issues often use type
`ci:` with **no scope** (e.g. #304, PR #329) even though they still carry the `enhancement` label
(no dedicated `ci` label exists — type-label mapping only covers bug/feature/spike).

**Epic-child linking:** same native GitHub sub-issues mechanism as infra (GraphQL `addSubIssue`),
confirmed working here too (attached #330 under #302 2026-07-18). Epic bodies list children as
prose + the native sub-issue panel, not a manual checklist.

**Advisory-review-pipeline epic (#302, ADR-0025):** issue-stage plan gate (#305, entirely a
backlog-manager change, no CI) + PR-stage non-Anthropic code review (#304, PR #329, `ci:`
workflow using `anc95/ChatGPT-CodeReview`, SHA-pinned, `architecture`-label-gated, advisory-only
— never a required check). Known limitation surfaced during #304's verification: that action
batches comments per-file with no suggestion-block support, so \`\`\`suggestion\`\`\` blocks post
as copy-pasteable text, not GitHub one-click-applyable suggestions. Filed as the explicit upgrade
path, #330 (sub-issue of #302): a DIY workflow step using `pulls.createReview` with a per-line
`comments` array, gated on #304 "proving its keep" first — `priority: low`, not spike (the design
is already spelled out in ADR-0025's alternatives + PR #329's comment, so it's a build task, not
an open research question).

See infra's [[label-taxonomy]] and [[backlog-conventions]] for the shared governance model.
