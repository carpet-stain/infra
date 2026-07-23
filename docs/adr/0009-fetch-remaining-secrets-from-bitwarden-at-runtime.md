# 0009. Fetch remaining secrets from Bitwarden at runtime

Date: 2026-07-22

## Status

Accepted

## Context

ADR-0008 moved the GitHub App private key and the Cloudflare API token into
Bitwarden, but deliberately scoped out the rest of the standing-secret
inventory — which is the majority of what exists. #59 covers that remainder:

- **CI** still held the state passphrase, both R2 credential pairs, the R2
  account id, and a routine `GH_TOKEN` PAT as native GitHub Actions secrets.
- **Local** (`.envrc.local`) held the same passphrase + R2 read/write token,
  _plus_ `BW_ACCESS_TOKEN` — the CI machine account's read/write-on-`infra`
  token — all exported ambiently by direnv to every shell that entered the
  repo, agent shells included. That is the exact `dotfiles`#160 exposure the
  epic exists to close, and it already contradicted ADR-0008's own invariants
  ("this account's [CI] token is never exported to a local shell"; "no Machine
  Account a local shell ever holds has a grant on `infra`").

The state passphrase is the crown jewel: it decrypts all state, and state
holds every secret value the providers write (the App key included). It
therefore _must_ live in the `infra` Project — which the local ambient
machine account for cross-repo work (`vended-tokens` only, `dotfiles`#377)
deliberately cannot read. So "everything in Bitwarden" cannot mean "everything
ambiently fetchable by any local shell"; the elevated local path needs its own
answer.

## Decision

Fetch every remaining secret from Bitwarden at the moment it's needed, so
nothing standing lives natively or ambiently beyond the one root that unlocks
the store.

**CI** (`tofu-plan`/`apply`/`apply-dispatch`): the passphrase, R2 pairs, and
account id are read at runtime via `bitwarden/sm-action` from the `infra`
Project; the routine `GH_TOKEN` PAT is replaced by an App-minted **read** token
for the provider, with the plan's PR comment posting via the workflow's own
ephemeral `github.token`. End state: the only native GitHub _secrets_ are
`BWS_ACCESS_TOKEN` and `BWS_ORGANIZATION_ID` — the irreducible root that can't
live in the store it unlocks (ADR-0008) — plus non-secret `BWS_*` UUID
variables.

**Local**: the elevated backend secrets are fetched at invocation by
`scripts/with-infra-secrets.sh` (wrapped by the `just tofu` / `tofu-apply`
recipes), never exported ambiently by direnv. The infra-read machine-account
token — reusing the CI account, not a fourth one (the free tier caps at three,
all used; ADR-0008) — lives in the macOS login Keychain **gated**: added
_without_ an app ACL entry, so each read raises a Keychain prompt. An
interactive human clicks Allow; a non-interactive or agent shell fails closed.
The routine `GH_TOKEN` stays ambient in `.envrc.local` — it's non-elevated and
is retired later by the vending path (`dotfiles`#377); relocating it into
Bitwarden would preserve a credential the roadmap eliminates.

**This refines ADR-0008's local invariant, it does not silently break it.**
`infra`'s own local `tofu` legitimately needs an infra-read credential — a
local `plan` refreshes the `bitwarden-secrets_secret` resources in `app.tf` /
`cloudflare.tf`, so _some_ infra-read token must be reachable while those are
managed; no option avoids it. The invariant is revised from "never held
locally" to **"never _ambiently_ exported — fetched only at invocation, gated
by the Keychain ACL."** The boundary is now ACL-based (a prompt), weaker than
the vend path's Project-disjointness but strictly stronger than the ambient
plaintext it replaces. The two local credential stories stay distinct: general
agent/human shells get the vended, `infra`-**excluded** token for cross-repo
work; `infra`'s own local `tofu` gets the Keychain-gated infra-read token, only
when a human runs `just`.

## Alternatives considered

- **Leave the elevated secrets ambient in `.envrc.local`** (status quo).
  Rejected — the crown-jewel passphrase and an `infra` read/write token
  exported to every agent shell is precisely the exposure this closes.
- **Frictionless Keychain** (`add-generic-password -A`, or clicking "Always
  Allow"). Rejected — any local process could then read the token silently.
  macOS ACLs are per-_binary_, so "Always Allow" for `security`/`bws` collapses
  to frictionless; gated means never whitelisting, so a prompt fires every run
  and a silent agent attempt becomes a visible tripwire. Friction accepted for
  that.
- **Tofu-manage the passphrase + R2 creds** as `bitwarden-secrets_secret`
  resources, like the App key. Rejected — they're bootstrap-root credentials;
  a managed resource writes their values into the very R2 state they
  encrypt/gate, a circular-in-state smell. "One source of truth" is already
  satisfied by the value living in Bitwarden and being fetched — a resource
  only adds a state-visible copy. (The App key and Cloudflare token earn
  management: a real rotation lifecycle, no such circularity.)
- **A fourth, local-only read machine account** scoped to `infra`. Rejected —
  the free tier caps at three machine accounts and all three are used
  (ADR-0008). Reuse the CI account's token (same elevated trust tier, two
  homes: GH Actions secret + Keychain).

## Consequences

CI's native GitHub-secret footprint collapses to `BWS_ACCESS_TOKEN` +
`BWS_ORGANIZATION_ID`; everything else is fetched at runtime — one root
credential per surface (infra#33's principle, realized). Local runs no longer
leak any crown-jewel secret into the ambient environment, but `tofu` must go
through `just` (bare `tofu` lacks the creds now), each run raises a Keychain
prompt, and `bws` becomes a required local dependency.

The passphrase is fetched fresh per run; a failed fetch fails the run
(fail-closed) and never corrupts state — the value is safe in Bitwarden.
Rotating it remains a multi-step OpenTofu key rotation (ADR-0002), never a
Bitwarden UI value edit — moving where it's stored doesn't change that.

ADR-0008's "local never touches `infra`" now reads with this qualification;
cite ADR-0009 alongside it rather than as absolute. Revisit if Bitwarden adds
per-secret ACLs (which could give the local path the same Project-level
isolation the vend path has) or if a paid tier lifts the three-account cap (a
dedicated local read account would restore Project-disjointness for the local
elevated path).
