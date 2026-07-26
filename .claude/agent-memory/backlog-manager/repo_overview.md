---
name: repo-overview
description: Where infra's docs/ADR homes live and the triage boundary for what belongs on this repo's backlog
metadata:
  type: reference
---

What infra is, its stack (ADR-0002), and its file layout are README.md's and AGENTS.md's job —
read those; don't restate them here.

**Backlog triage boundary:** issues here are about the governance stack itself (terraform, labels,
rulesets, CI guards, credentials, agent-config) — never about a managed repo's own working-tree
contents. An issue about dotfiles' shell config belongs on the dotfiles repo, not here.

See [[label-taxonomy]] and [[backlog-conventions]].
