# 0020. Routine GitHub credential model: vended for covered repos, keyring PAT for infra

Date: 2026-08-16

## Status

Accepted

## Context

The routine (non-admin) `GITHUB_TOKEN` model is decided in practice but was
never recorded. Two separate changes settled it independently: #151 (commit
`3c122fd`) made the gh keyring dev PAT infra's routine default; dotfiles#453
made a vended, rotating token the routine source for the vended-_covered_
repos (`dotfiles`, `project-starter-template`, `template-e2e`). infra is
deliberately excluded from the vended token — `vend-token.yml`'s scope, and
issue #51's containment: a crafted PR against infra must not carry a
routine token that can act on infra. ADR-0013 records only the **admin** credential
(the fine-grained PAT gated behind SSM); the routine split has no ADR at
all. So "which routine credential, in which repo, and why" was walkable
only via issue archaeology (#151, #51, `vend-token.yml`'s own comments) —
exactly the excavation an ADR exists to prevent, and the gap that let a
recent consolidation attempt (#195) assume "vended everywhere" until plan
review caught it.

## Decision

Two routine `GITHUB_TOKEN` sources, chosen per repo:

- **Vended token** (rotating ~1h, scoped, no admin) for the vended-covered
  repos — `dotfiles`, `project-starter-template`, `template-e2e`. Minted by
  `vend-token.yml`, bridged into the shell via dotfiles' shared
  `use_github_token` direnv function (#195).
- **gh keyring dev PAT** for **infra**. `.envrc` derives `GH_TOKEN`/
  `GITHUB_TOKEN` from `gh auth token` at shell entry (#151) — no token
  literal in any repo file.

infra is the deliberate exception, not an oversight: the vended token
excludes infra by design (`vend-token.yml`'s `repositories:` CSV never
lists it, see issue #51), because a crafted PR against infra must not be
able to carry a routine token scoped to act on infra. infra also manages
itself via the github provider (`repos.tf`/`main.tf`), so its routine
token has to reach infra — the one thing the vended token can't do.

The keyring dev PAT has a second job: it's #191's self-heal fallback,
re-minting the vended token when that token is dead/expired — the vended
token can't refresh itself while expired.

The **admin** credential (gated SSM, ADR-0013) is unchanged by this
decision — it's a separate, higher-privilege tier for `tofu-apply` only.

## Alternatives considered

- **Vend infra too, drop the keyring PAT.** Rejected — `vend-token.yml`
  excludes infra specifically so a crafted PR against infra can't come with
  a routine token that can act on infra (#51). Vending infra its own token
  would reopen that hole.
- **One routine credential everywhere (fold infra into the vended model).**
  Rejected — this was #195's original framing, corrected at plan review.
  infra's self-management requirement (the github provider manages infra
  itself) is structurally incompatible with a token the vend workflow
  deliberately can't mint for infra.
- **Amend ADR-0013 in place instead of a new ADR.** Rejected — ADR-0013
  scopes to the admin credential; the routine split is a different decision
  with a different owner and lifecycle. Same "new ADR, not an in-place
  edit" pattern ADR-0013 itself used to extend ADR-0010.

## Consequences

- "Which routine credential, where, why" is now a five-minute read instead
  of issue archaeology — closes the gap that let #195 assume "vended
  everywhere."
- infra's `.envrc` keeps its own `gh auth token` derivation, now with a
  signpost comment pointing here instead of just at #51.
- Revisit if `vend-token.yml`'s scope ever changes to include infra — that
  would invalidate this decision's core premise (#51's containment) and
  needs its own ADR, not a silent edit here.
