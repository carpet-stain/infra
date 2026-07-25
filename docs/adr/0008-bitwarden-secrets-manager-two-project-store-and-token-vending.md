# 0008. Bitwarden Secrets Manager: two-Project store and token vending

Date: 2026-07-20

## Status

Accepted

## Context

Two secrets this account depends on live in two different places, neither a
deliberate store: the GitHub App's private key (ADR-0004/0005) sits in
`infra`'s own native GitHub Actions secrets (#31), and the routine gh
credential is a fine-grained PAT hand-pasted into `.envrc.local`. Spike #33
asked where secrets should actually live and resolved it: one source of
truth, **Bitwarden Secrets Manager**. This ADR records that decision and the
two-Project structure two rounds of plan review added on top of it.

Three constraints shape the structure:

- **`carpet-stain` is a personal account, not an organization.** Secrets
  Manager isn't available on an Individual/Premium vault directly — it needs
  an Organization, which the free tier provides on top of the existing paid
  personal account (confirmed against Bitwarden's docs).
- **Bitwarden access control is Project-granular only.** There is no
  per-secret ACL inside a Project (verified directly against Bitwarden's
  machine-accounts docs). A Machine Account is granted read or read/write on
  a whole Project — so anything a credential can reach the Project for, it
  can read _every_ secret in that Project for. This is the single fact that
  forces two Projects rather than one flat store.
- **The Terraform provider manages secrets, not the Projects or Machine
  Accounts around them.** `bitwarden/bitwarden-secrets` (published by
  Bitwarden's own GitHub org, community tier) has exactly one resource,
  `secret` — no `project` or `machine_account` resource exists. Same shape
  as the App's own registration (ADR-0004: no `resource "github_app"`): the
  scaffolding is a one-time manual bootstrap, the secrets inside it are code.

The local/agent-shell half of #33 (and ADR-0004's explicitly-deferred
"local bootstrap") is the other force. A local or agent session can't reach
GitHub Actions secrets, and it must never hold the App's raw private key —
even scoped down — because `dotfiles`#160's eager `direnv export` fires for
non-interactive agent shells too, so any credential exported into a shell is
reachable from every agent process, not just an interactive human. The naive
fix (give the local Machine Account read on the same Project the raw key
lives in) would make the key reachable from every one of those shells.

## Decision

**Bitwarden Secrets Manager, under a free Organization on the existing paid
personal account, is the account's secret store.** Two Projects, three
Machine Accounts, with the grants between them kept deliberately disjoint.

**Two Projects, because the Project is the access boundary:**

- **`infra`** — the App's raw private key (migrated off #31's native secret,
  see #47) plus infra-only secrets (the Cloudflare API token, #7). Read/write
  by a dedicated **CI Machine Account** used by `infra`'s own `tofu apply`
  and by the workflows that mint from the key (#32, #51). This account's
  token is never exported to a local shell.
- **`vended-tokens`** — a single JSON secret (`{token, expires_at}`) holding
  a narrowly-scoped, rotating GitHub token that local/agent shells read
  (`dotfiles`#377). Written by the vending workflow (#51), read by the local
  Machine Account.

The split is load-bearing, not cosmetic: because access is Project-granular,
the only way a local credential can be structurally unable to read the raw
key is for the key to live in a Project that credential has no grant on. One
flat Project can't express that.

**Three Machine Accounts, grants disjoint** (the free tier caps at three, so
the design uses its entire budget — see Consequences):

| Machine Account | `infra`    | `vended-tokens` | Held by                                 |
| --------------- | ---------- | --------------- | --------------------------------------- |
| CI              | read/write | —               | `infra` CI (`tofu apply`, minting)      |
| Vending         | read       | read/write      | `infra`'s scheduled vend workflow (#51) |
| Local           | —          | read            | a local/agent shell (`dotfiles`#377)    |

The **Machine-Account-to-Project grants are the actual security boundary**,
and the provider can't manage them — this table is the reviewable spec to
audit the live Bitwarden state against. The invariant to check: no Machine
Account a local shell ever holds has a grant on `infra`, and the CI and
local Machine Accounts share no Project.

**Vending, not direct access, is how the local side gets a credential.**
`infra` mints a token from the raw key and _publishes_ it to `vended-tokens`;
the local side only ever reads the published token, never the key. The
vended token is scoped to `{issues, pull_requests, contents}: write` with no
`administration`, over every repo in `local.repos` **except `infra` itself** —
a vended token that could write to `infra` could push a crafted file and open
a PR against the one repo that holds the raw key and runs the mint, a smaller
copy of the exact exposure this structure exists to close (#51).

**Bootstrap is manual, ongoing management is code.** The Organization, both
Projects, all three Machine Accounts, and their grants are a one-time manual
setup (documented in AGENTS.md, same as the App's registration). Individual
secrets inside a Project are `bitwarden-secrets_secret` resources, declared
with **no `value` in config** (dynamic secrets — the value is set by hand in
Bitwarden's UI or generated, never written into a `.tf` file or CLI arg).

**No new encryption step.** A secret's resolved value lands in Terraform
state regardless — `Sensitive` only redacts CLI/log output, it doesn't keep
the value out of state. But `infra`'s state is already R2-backed and
client-side encrypted under ADR-0002's enforced `TF_ENCRYPTION` before it
leaves the machine, and config never holds a literal (dynamic secrets). The
existing architecture already covers this end to end.

## Alternatives considered

- **Cloudflare Secrets Store** (the leaning #19/ADR-0004 recorded for the App
  key). Rejected — a product-shape mismatch, not an auth gap, confirmed
  against Cloudflare's own docs: _"This permission does not grant access to
  the value of a secret"_ even for a Read-scoped API token. Secrets Store
  only ever exposes values to Cloudflare's own Workers/AI Gateway bindings,
  never to an external reader, so no `tofu`/CI/local consumer here can ever
  read a value out of it. Fed back to #10; it stays open for anything else.
- **One flat Project.** Rejected — Project-granular ACL means any credential
  that can read the Project reads the raw key too, so a local-shell
  credential and the raw key can't coexist in one Project without the key
  being reachable from every agent shell. The whole point is that the key
  lives somewhere the local credential structurally cannot reach.
- **A local Machine Account reading `infra` directly** (the first local-access
  design, before plan review). Rejected — same Project-granularity problem
  seen from the other side: this hands every ambiently-exported agent shell
  (`dotfiles`#160) a credential that can read the raw key. Vending through a
  second Project is the indirection that removes the key from the local
  side's reach entirely.
- **Keep native GitHub Actions secrets as the store** (the #31 status quo).
  Rejected — they can't be fetched outside CI, so they solve nothing for the
  local/agent case, and keeping them alongside Bitwarden for everything new
  is two sources of truth. #47 migrates the App key off them onto Bitwarden;
  one native secret remains (`BWS_ACCESS_TOKEN`, the CI Machine Account's own
  token), which is the irreducible bootstrap credential — the one secret that
  can't itself live in the store it unlocks.

## Consequences

`infra`'s own secrets become Bitwarden-managed and Tofu-wired — one source of
truth, and the local/agent-shell gap ADR-0004 and #33 left open is closed by
the vending path (`dotfiles`#377 consumes it). Every `tofu plan`/`apply` and
the vend workflow now authenticate to Bitwarden (`BWS_ACCESS_TOKEN` +
organization id), a new apply-time credential in `.envrc.local` and a native
Actions secret; the whole epic is gated on the manual bootstrap existing
first, so the first apply after this lands fails until the Organization,
Projects, Machine Accounts, and grants are created by hand.

Free-tier ceilings are load-bearing, not incidental:

- **Three Machine Accounts is the hard cap, and the design uses exactly
  three** — zero headroom. If a fourth consumer ever appears, the clean
  consolidation is merging the two CI-side accounts (one account with grants
  on both Projects): the boundary that must stay real is CI-vs-local, not the
  split between CI consumers. **(Stale — do not follow. Post-ADR-0009 this
  merge would hand the unattended vend cron write-`infra`; the corrected path
  is a new Project read by an existing account — see the #73 amendment below.)**
- **`infra` staying public keeps Actions minutes unmetered.** The vend
  workflow's cadence alone (~48–72 runs/day) would consume the entire
  private-repo free allotment; "infra stays public" is a load-bearing
  assumption here, same as it already is for free rulesets.
- **Scheduled workflows auto-disable after 60 days of repo inactivity.** If
  `infra` goes quiet, vending silently stops and local shells start
  loud-failing on a stale token — the designed degradation, with the one-click
  re-enable noted in AGENTS.md so it's diagnosed in seconds, not re-derived.

The Machine-Account-to-Project grants can't be Tofu-managed, so auditing the
live grants against this ADR's table is a manual, periodic check — the price
of the provider having no resource for them. Revisit the whole structure if
Bitwarden adds per-secret ACLs (the two-Project split's entire reason to
exist), or if a paid tier lifts the three-account cap and a genuine fourth
consumer wants its own boundary. (Revisited in #73 — see the amendment below.)

## Amendment — #73 (2026-07-25): the third secret class

Spike #73 hit the revisit trigger named above ("a genuine fourth consumer").
It resolved two questions and corrected one piece of the guidance above.

**(1) dotfiles' own `GH_TOKEN` retires onto the vended path.** dotfiles' last
standing PAT (Contents/PRs/Actions/Issues, ambient in `.envrc.local`) is
retired for the vended token (`dotfiles`#377) like every other consumer. The
only scope the vended token lacks is **Actions**, exercised at a single
human-invoked step (`gh workflow run release-prepare.yml`) that already has a
documented by-hand fallback — so the swap is clean and the vended token is
**not** widened. Adding `actions: write` to the most broadly-distributed,
ambient token to serve one convenience is the wrong trade; the operator
elevates for that one step or uses the fallback, the same pattern dotfiles
already uses for branch-protection bootstrap. Consequence to name: dotfiles'
own routine `gh` work now inherits the vend cron's liveness — if vending
stalls (the 60-day auto-disable), dotfiles loud-fails too, the same designed
degradation local shells already have.

**(2) A new secret _class_ (third-party LLM API key) — store adoption
deferred until its local consumer exists.** Two pulls: the shipped PR-reviewer
(`dotfiles`#330/#370) and the unbuilt scratch-terminal (`dotfiles`#399/#400).
The reviewer is **CI-only** — its key stays a native Actions secret, the
correct home for a single-repo CI secret, not the ad-hoc anti-pattern
`CONSUMING-SECRETS.md` targets (that section is about local/cross-repo sprawl,
not a workflow holding its own secret). The scratch-terminal is the only
consumer that would need the store's local reach, and it isn't built — so no
Project, account, or grant changes now. Provisioning for an unbuilt consumer
is guessing at its usage; decide when it exists.

**The "merge the two CI-side accounts" guidance above is stale — do not
follow it.** It predates ADR-0009, which reused the CI account as the local
Keychain-gated credential. Merging CI+Vending would give the unattended
`vend-token.yml` cron **read/write on `infra`** (today: read only), so a
vend-cron compromise could _overwrite_ crown jewels (swap the App key, plant a
backdoor) — contradicting the invariant AGENTS.md states outright: the Vending
account is "never the CI account, so the vended path can't reach CI's write
grant on `infra`." The corrected path: **the binding constraint is machine
accounts (0 free), not Projects (1 of 3 free).** A new secret class gets a
**new Project in the free slot, read by an _existing_ account** — no merge, no
new account. The account budget binds only if a secret genuinely needs its own
account boundary; that trade-off (reuse-an-existing-account-and-gate vs. spend
the last slot vs. the paid tier — Secrets Manager Teams, ~$72/yr, which also
converts the free personal Org to a paid subscription) is re-evaluated against
the real consumer, not pre-committed here.

For the LLM key specifically, that sub-question stays open by design: it's
billable-but-not-crown-jewel, fitting neither the ambient `Local` account (a
grant there exposes a billing key to every agent shell) nor the crown-jewel
`CI` account cleanly. When the scratch-terminal is built, decide its account
and gate its fetch (treat billing exposure as elevation — a gated wrapper, not
an ambient `.envrc.local` export) with its actual usage in hand.

Follow-ups: `dotfiles`#377 (retire `GH_TOKEN`, update its Non-goals);
`dotfiles`#399/#400 (the LLM key's plan once the tool exists). No infra
grant/Project change falls out of this now — the store is unchanged.
