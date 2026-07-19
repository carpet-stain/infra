---
name: repo-overview
description: What the infra repo is, what it governs, and its docs/ADR structure — orient here before filing issues
metadata:
  type: project
---

`carpet-stain/infra` (public) is GitHub account governance-as-code via OpenTofu: it manages
repository settings, the canonical label set, and `protect main` rulesets for every repo listed
in `repos.tf`'s `local.repos` map (today: `dotfiles` and `infra` itself). Working-tree files of
each managed repo stay that repo's own; this repo only manages GitHub API-level governance.

**Why:** config originated in the dotfiles repo and was migrated here (ADR-0002 records the
stack: OpenTofu + R2-backed client-encrypted state + config-as-data; dotfiles' ADR-0022/0024
record the founding + move).

**How to apply:** issues here are about the governance stack (terraform, labels, rulesets, CI
guards, credentials, agent-config), NOT about the contents of managed repos. An issue about
dotfiles' shell config belongs on the dotfiles repo, not here.

Key layout: `main.tf` (repo/label/ruleset resources), `repos.tf` (config-as-data: repo map +
canonical `local.labels` map), `versions.tf`, `docs/adr/` (ADRs; created only via
`just adr "title"` → `scripts/new-adr.sh`, never hand-numbered), `.github/workflows/`
(pr-guards, lint, tofu, adr-guard). CI status checks enforced by the ruleset: `single commit`,
`conventional commit`, `adr guard`.

Apply model: `just tofu plan` uses a routine read-only scoped token; `just tofu-apply` needs an
elevated session token with Administration scope. See [[label-taxonomy]] and [[backlog-conventions]].
