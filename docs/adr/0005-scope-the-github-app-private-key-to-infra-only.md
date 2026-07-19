# 0005. Scope the GitHub App private key to infra only

Date: 2026-07-19

## Status

Accepted

## Context

ADR-0004's Decision section calls for the GitHub App's private key to be
propagated to every repo in `local.repos` (a blanket `github_actions_secret`
`for_each`), on the reasoning that per-mint `permissions`/`repositories`
narrowing on the token-creation endpoint already gets least-privilege per
consumer — "nobody ever holds the App's full grant as a standing credential."

That reasoning has a hole, caught during epic #28's plan review before any
of it shipped: per-mint narrowing constrains what an _honest_ caller of the
token-creation endpoint requests. It does nothing to constrain a caller
holding the _raw private key_ — that key signs the JWT used to authenticate
to the token-creation endpoint in the first place, so anyone holding it can
request a token with any permission the App is registered for, against any
repo it's installed on, including `administration: write` against `infra`
itself. Blanket propagation means every managed repo — including a future
lower-trust public or experimental project — holds a working copy of what
ADR-0004 itself calls "this account's single highest-value credential." A
single compromised repo's CI compromises every repo the App can reach. The
per-mint narrowing this repo built the whole model around only protects
against a caller playing by the rules; it was never a security boundary
against a caller holding the signing key.

Re-examining why ADR-0004 reached for blanket propagation in the first
place: `carpet-stain` is a personal account, not an organization, so
GitHub's native "org secret restricted to N repos" feature — which would
have given one access-controlled secret store instead of N raw copies —
doesn't exist here. Blanket per-repo propagation was the fallback once that
option was off the table, not a deliberate choice on its own merits.

The actual motivating use cases for the App don't need every repo to hold
the key:

- **Cross-repo/elevated governance** — `infra`'s own `tofu apply` (epic
  #11's #25/#26) needs an `administration`-scoped token to manage _other_
  repos' settings, labels, and rulesets. This only ever runs from `infra`'s
  own CI.
- **Routine same-repo CI work** (a repo's own release automation, its own
  issue/PR touches from within its own workflows) needs no App at all —
  every GitHub Actions job already gets a `GITHUB_TOKEN` scoped to that one
  repo, for free, with permissions set directly in the workflow's
  `permissions:` block. ADR-0004's own worked example ("a repo's agent
  session, e.g. backlog-manager, mints `{issues, pull_requests,
contents}: write` scoped to that one repo") conflated this case with a
  different one — see below.
- **Local/agent-shell sessions** (a human or an agent like backlog-manager
  running `gh` from a laptop, not from within a GitHub Actions run) are a
  separate problem `GITHUB_TOKEN` can't touch, since it only exists inside
  an Actions job. This is dotfiles#160's problem and is already tracked as
  its own open spike (#33) — not resolved by this ADR either way.

## Decision

**The App's private key is held only by `infra`**, stored as a single
`github_actions_secret` in `infra`'s own repo — not propagated to any other
managed repo. `infra`'s CI is the sole minting authority: it's the only
place that ever signs a JWT with this key and requests an installation
token, narrowly scoped via `permissions`/`repositories` to whatever that
job actually needs (feeding #11's #25/#26 directly).

Other repos' own routine CI work uses their own `GITHUB_TOKEN`, not an
App-minted token — the App was never actually necessary there, and this
removes the need to distribute the key at all for that case.

Local/agent-shell bootstrap (backlog-manager or any other agent session
driving `gh` outside of CI) is explicitly **not** resolved here — that
question stays open in spike issue #33. Whatever #33 decides, it does not
require reversing this ADR: #33 could mean a human securely holds their own
copy of the key, or a call-out to `infra` as a vending authority, or
something else; either shape is compatible with "the key isn't broadcast to
every repo's CI."

## Alternatives considered

- **Keep ADR-0004's blanket propagation, accept the risk.** Rejected — not
  a deliberate risk acceptance, an unexamined default reached for because
  the org-secret-sharing feature this account lacks would have been the
  obvious fix. The blast radius (every repo's CI can mint an
  administration-scoped token against `infra`) is disproportionate to the
  benefit (saving a `GITHUB_TOKEN` permissions-block edit in each repo's
  own workflows).
- **A cross-repo reusable-workflow token broker** (other repos call an
  `infra`-owned `workflow_call` workflow that holds the key privately and
  returns a minted token as an output). Rejected for now as unneeded
  complexity — no identified consumer actually needs a cross-repo App token
  once same-repo work is covered by `GITHUB_TOKEN` and cross-repo governance
  stays inside `infra`'s own CI. Revisit if a real cross-repo (non-`infra`,
  non-local) consumer shows up.
- **Editing ADR-0004 in place** instead of a new ADR. Rejected per
  `docs/adr/README.md`'s own rule: a later decision that replaces an
  earlier one gets its own ADR, so the rejected path stays visible instead
  of being edited out of the record.

## Consequences

Epic #28's #31 (private-key propagation) and #32 (CI-side token minting)
scope down to `infra` only, not `for_each` over `local.repos` — cheaper to
build than the original design, not more expensive. Other repos' workflows
need their own `permissions:` blocks reviewed for what their `GITHUB_TOKEN`
actually needs, same as any GitHub Actions repo already does; nothing new
to provision. `infra` remains the account's highest-value single point of
compromise for this credential, same as the elevated keyring session
already is today — that concentration is the point, not a new risk this ADR
introduces. #33 (local/agent-shell bootstrap) stays open and unaffected by
this change either way.
