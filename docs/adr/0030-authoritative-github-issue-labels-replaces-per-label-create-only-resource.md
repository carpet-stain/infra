# 0030. Authoritative github_issue_labels replaces per-label create-only resource

Date: 2026-08-23

## Status

Accepted

## Context

`github_issue_label` (singular) is create-only: it blind-POSTs and 422s on
any label GitHub already seeded. Six of the nine default labels (`bug`,
`documentation`, `duplicate`, `enhancement`, `good first issue`, `wontfix`)
collide with the canonical set every new-repo standup applies. The
workaround was a temporary `imports.tf` adopting the colliders, a
follow-up PR deleting it, and hand-deleting the three non-colliding seeds
(`help wanted`, `invalid`, `question`). Account-level default-label
customization is org-only, unavailable on this personal account, so the
fix has to be the resource shape, not repo creation.

## Decision

Manage labels with the provider's `github_issue_labels` (plural, one
resource per repo) instead of `github_issue_label` (singular, per-label).
Its create/update path lists the repo's live labels first, PATCHes any
that match by name and drifted, deletes any live label absent from the
managed set, then creates whatever's still missing (confirmed against
`integrations/terraform-provider-github` v6.13.0 source, not assumed from
docs) — so first apply reconciles GitHub's seeded defaults in place, no
422, no `import` block, no follow-up delete PR.

## Alternatives considered

- **Keep `github_issue_label` + `imports.tf` per standup** — the status
  quo; a manual two-PR dance every time a repo is added, and the exact
  thing this ADR exists to remove.
- **Account-level default-label customization** — GitHub only exposes
  this at the organization level; unavailable on a personal account.

## Consequences

A new repo standup needs no `imports.tf` and no follow-up delete PR —
`github_issue_labels` adopts GitHub's seeded defaults on first apply.
The tradeoff is that the resource is now authoritative: any label present
on a managed repo but absent from `local.repo_label_sets` gets deleted on
apply, including labels a runtime Action creates without a matching
config entry. `tofu-drift.yml` (#87) now flags any hand-added label as a
pending delete — confirmed live, several managed repos carry Dependabot's
auto-created `dependencies`/`github_actions` labels (no `labels:` override
in their `dependabot.yml`) that this resource will delete on apply and
Dependabot will silently recreate on its next PR, a standing churn until a
follow-up either adds them to the canonical set or gives Dependabot an
explicit `labels:` override per repo.
