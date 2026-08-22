# 0029. Adopt a Neon organization with project-scoped keys for consumer isolation

Date: 2026-08-22

## Status

Accepted

Supersedes [0023. Adopt Neon as the managed Postgres provider](0023-adopt-neon-as-the-managed-postgres-provider.md)
in status only — its provider pin, bootstrap-only scope, and management-key
residency in `/infra` all carry forward unchanged. What changes is one
boundary claim: `0023` said project/role/`connection_uri` are "a consumer
concern, created in the consumer's own state, never this one" — `neon_project`
now moves the other way (see Decision).

## Context

Issue #272 (agent-memory-server's CI-apply seam) gave its consumer CI a second,
account-global Neon key, and named the residual explicitly: any key on a
personal Neon account can manage or destroy every project on that account,
incl. the memory store — containment/rotation-independence, not isolation.
finding-7 flagged that blast radius as worth closing.

This issue (#284) opened to decide between two options: accept the
shared-account blast radius, or pay for a second Neon account per trust
boundary. Both assumed Neon API keys are account/org-global with no
narrower scope — that premise turned out to be **false**. Neon documents a
third key type, available only under a Neon **Organization** (not a
personal account): a **project-scoped** key, Editor-role, readable/writable
only within one named project.

Plan review (round 1) blocked the initial recommendation on five points:
who provisions `neon_project` if the consumer key can't reach outside its
own project (B1/B2), whether a read-only project-scoped role exists (B3),
and that every load-bearing fact was doc-read, not exercised (B4/B5). A
required PoC against a live free Neon org resolved all of them
(2026-08-22, full results in the issue thread):

| Criterion                                                                                                               | Result                                                                                  |
| ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Free org mints a working project-scoped key                                                                             | Pass                                                                                    |
| Scoped key manages its own project's roles/databases/branches, and the `kislerdm/neon` provider (v0.15.0) auths with it | Pass                                                                                    |
| Scoped key cannot enumerate or reach any other project                                                                  | Pass — `404 "not allowed to perform actions outside the project this key is scoped to"` |
| Scoped key cannot create a project                                                                                      | Pass — denied                                                                           |
| Scoped key cannot delete its own project                                                                                | Pass — denied                                                                           |
| A read-only project-scoped role exists                                                                                  | **Fail** — the scope is Editor/writer only, no read-only variant                        |

## Decision

**Convert to a Neon free Organization; each consumer's CI holds a
project-scoped key instead of an account-global one.**

- **`neon_project` create/delete is an org-admin-key operation.** A
  project-scoped key can't provision or tear down its own project (proven
  above), so project lifecycle stays with the org-admin key — the same
  crown-jewel credential `/infra/neon-api-key` already is. The
  `neon_project` resource itself lives in **infra's** Terraform state, not
  the consumer's — this is the piece that reverses `0023`'s original
  boundary.
- **Consumer CI holds a project-scoped key**, Editor on its own project
  only, managing roles/databases/branches inside it — the resources `0023`
  already assigned to the consumer's own state stay there.
- Net blast radius of the lowest-trust credential (agent-memory-server's
  PR-triggered plan-read CI) drops from _every project on the account,
  incl. the memory store_ to _its own, recoverable project_.

### Accepted residual — no read-only project-scoped role (B3)

The scoped key is a writer. `tofu plan` refreshes `neon_*` resources
against the live API, so a PR-triggered plan-read credential holding a
project-scoped key can write or destroy **its own** project's data (drop a
database, delete a branch) — but never another project's, and never the
memory store. **Accepted**: solo repo, no untrusted fork PRs, harm confined
to one recoverable project. **Revisit trigger:** untrusted fork PRs become
real — then move to no-Neon-key-for-fork-plans, or `-refresh=false` on
`neon_*` resources for that plan path.

### Residency-model impact

`0010`'s role×path matrix and its `#272` amendment recorded the consumer
Neon key as a **second, account-global** key in `/cicd`, chosen for
"containment/rotation independence... not isolation, since Neon keys
aren't project-scopable." That premise is now known false — see the
amendment appended there. The shape doesn't change (org-admin key in
`/infra`, consumer key in `/cicd`), only what the consumer key can reach.

This supersedes `0010`'s `#272` amendment's "not isolation" framing, not
its tier placement — `/cicd` stays the right residency for a
break-glass-provisioned, consumer-CI-read Neon key either way.

### Migration — maintainer step, out of routine CI scope

Personal-account to org is **create-org, then transfer projects in** — no
in-place conversion. The memory-store and agent-memory-server projects move
only after a throwaway transfer confirms connection strings survive it;
this is a manual, account-level action, not something CI or an agent runs.

## Alternatives considered

- **Status quo — shared personal account, one account-global key.** Zero
  cost, but finding-7's blast radius stands: any key holder, incl. a
  PR-triggered plan-read credential, can manage or destroy every project on
  the account. Rejected once a free-cost alternative closing that gap
  turned out to exist.
- **Separate Neon account per trust boundary.** Real isolation, but the
  heaviest option: a second account, a second provider auth in the
  residency model, project migration, human-managed cross-account
  boundaries — priced for a problem the free-org project-scoped key solves
  on one account. Kept as the named fallback if the PoC had failed on B4/B5
  (a free org couldn't mint a working scoped key); it didn't.

## Consequences

- Unblocks the reshape of #272 (CI-apply seam: org-admin key provisions
  the project, consumer CI gets a project-scoped key instead of an
  account-global one) and agent-memory-server#11's Neon slice.
- `neon_project` resources move out of consumer Terraform state into
  infra's — a state migration (`state rm` in the consumer, `import` here),
  not a credential swap, when #272's reshape lands.
- The memory-store project gets its own project-scoped key too —
  isolation is bidirectional, not just protecting the memory store from
  other consumers.
- **Revisit if** untrusted fork PRs against a consumer repo become real
  (the accepted residual above), or if Neon ships a read-only
  project-scoped role (removes the residual entirely).
