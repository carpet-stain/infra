# 0004. GitHub App PAT provisioning and cross-repo delegation model

Date: 2026-07-19

## Status

Accepted

## Context

Every managed repo's `gh` credential today is a fine-grained PAT a human mints
by hand in the GitHub UI and pastes into `.envrc.local` — fine at 2 repos
(dotfiles, infra), not at the scale `local.repos` is already growing to
(`project-starter-template` landed, more following). No API mints a _personal_
fine-grained PAT — creation is UI/device-flow only, by design, since it's tied
to a human identity. Spike #19 asked whether provisioning can be code-managed
at all, and what the cross-repo delegation model should be.

Two things this ADR resolves that #19 left open, both changing its recorded
"leaning to validate":

**A GitHub App is the code-manageable replacement, confirmed.** The
`integrations/github` provider (pinned `~> 6.13`) has
`github_app_installation_repository` (tofu-managed: which repos an
installation can reach) and `data.github_app_token` (mints installation
tokens). There is no `resource "github_app"` — GitHub requires a one-time
human-in-the-browser manifest-flow approval to register an App and its
permission set. So "manage this as code" holds for installation wiring and
token minting, not for the App's own registration — that stays a one-time
manual bootstrap, not ongoing tofu-managed drift, same conclusion #19
originally reached.

**One App, not two, and not a Cloudflare-backed key store.** GitHub's
"create an installation access token" endpoint — what `data.github_app_token`
and `actions/create-github-app-token` both call — accepts optional
`permissions` and `repositories` parameters that narrow a minted token
_below_ the App's full registered grant, expiring in 1 hour. That means a
single App registered with the union of every permission any consumer
needs (`issues`, `pull_requests`, `contents`, `actions`: write for routine
agent work; `administration`: write for infra's elevated `tofu apply`) can
still hand out a minimally-scoped, short-lived token per consumer at mint
time — nobody ever holds the App's full grant as a standing credential. This
directly answers epic #11's #25/#26: the elevated Administration-scope
credential their `tofu apply` workflow needs is a narrowly-minted token from
this same App, requested at apply time.

That leaves one long-lived secret to protect: the App's RSA private key,
used to sign the JWT that's exchanged for installation tokens. #19 recorded
a leaning toward Cloudflare Secrets Store for it (not GitHub-native), to
validate. Checked and reversed: there is no OIDC/"trusted publishing" bridge
between GitHub Actions and Cloudflare (an open, unresolved community feature
request as of 2026) — so storing the key in Cloudflare Secrets Store doesn't
remove a long-lived secret from GitHub Actions, it relocates it to a standing
Cloudflare API token that CI would need as its _own_ GitHub Actions secret
instead, a strictly longer chain for no benefit. It also inherits #10's still
undecided, concretely-flagged state-trap risk (`cloudflare_secrets_store_secret`'s
`value` likely lands in tofu state as plaintext, not proven to use
write-only/ephemeral semantics) rather than sidestepping it. GitHub Actions'
own encrypted secret store needs no such bridge and no dependency on #10
resolving first — and propagating the key there via a tofu-managed
`github_actions_secret` per repo is exactly the mechanism ADR-0002 already
anticipated and already accepted the state-encryption tradeoff for ("RELEASE_PAT
management is planned" foreshadowed this precise case).

**A real constraint this account hits that an org wouldn't: App tokens can't
create new repos here.** `carpet-stain` is a personal user account, not an
organization (confirmed via the API). GitHub-staff-confirmed: `POST
/user/repos` — what `github_repository.this` calls when `local.repos` gains a
brand-new entry — categorically rejects GitHub App installation tokens; only
the org equivalent, `POST /orgs/{org}/repos`, works with Apps. Every other
governance operation this repo performs (label sync, ruleset management,
settings updates) targets a repo that already exists and works fine with an
App token. Only first-time repo creation is blocked.

## Decision

**Register one GitHub App** (manual one-time bootstrap: manifest flow in the
GitHub UI), granted the union of permissions every consumer needs —
`issues`, `pull_requests`, `contents`, `actions`: write for routine
repo-scoped agent work; `administration`: write for infra's own governance
and elevated applies. Install it on every repo in `local.repos` (installation
membership managed by `github_app_installation_repository`, `for_each` over
the same map routine changes already edit).

- **Token minting is per-consumer, not per-App.** Each consumer requests a
  token scoped to only what it needs, via the `permissions` +
  `repositories` narrowing on token creation: a repo's agent session (e.g.
  backlog-manager) mints `{issues, pull_requests, contents}: write` scoped to
  that one repo; infra's CI apply workflow (#25/#26) mints
  `{administration}: write` scoped to the repos being applied. 1-hour
  expiry, minted at use time — no standing broadly-scoped credential
  anywhere.
- **The App's private key is the one long-lived secret**, stored as a
  tofu-managed `github_actions_secret` propagated to every repo in
  `local.repos` — the same `for_each` shape `repos.tf` already uses,
  writing the key into R2-encrypted state under ADR-0002's existing
  enforced encryption, not a new risk class for this repo.
- **CI's bootstrap**: a workflow step (`actions/create-github-app-token` or
  equivalent) reads the App ID (a plain, non-secret repo var) and the
  private-key secret, mints a token scoped to that job's actual need, uses
  it, discards it. No local root credential involved — the secret is
  native to the platform running the job.
- **Local/agent-shell bootstrap is a separate, still-open problem**, not
  solved by the above. GitHub Actions secrets aren't fetchable outside CI,
  so a human or agent session working locally needs its own path to the
  App's private key (or a token minted on its behalf) — direnv doesn't
  solve this either, since it only hooks interactive shells and an agent's
  non-interactive shell never sources it (dotfiles#160). This ADR decides
  the credential _model_; the local bootstrap mechanism is follow-up scope,
  filed separately.
- **New-repo creation stays a human-run elevated apply.** Adding a genuinely
  new entry to `local.repos` still needs one `just tofu-apply` under the
  human's elevated session, same as today — App-minted tokens cannot create
  it. This is a standing exception, not a gap to close: the automated apply
  pipeline (#11) targets steady-state governance drift on repos that already
  exist, which is the overwhelming majority of applies; first-time repo
  creation was already a deliberate, infrequent, reviewed action before this
  ADR and stays one.

## Alternatives considered

- **Formalize the current hand-minted-PAT model** (codify the permission
  manifest per repo in `repos.tf`, keep minting manual). Rejected: doesn't
  solve the actual scaling problem (#19's motivating case) — every new repo
  still needs a human in the GitHub UI, no rotation path short of doing it
  by hand again, and GitHub's own guidance is explicit that PATs are the
  interim step, Apps are the scalable answer once you're past prototyping.
- **Two GitHub Apps** (one broad/elevated, one narrow/routine). Rejected:
  per-mint `permissions`/`repositories` narrowing already gets least-privilege
  per token without a second App registration, a second private key to
  protect, and a second one-time manual bootstrap. Revisit only if a single
  App's permission manifest becomes politically or operationally awkward to
  reason about (e.g. a future consumer that must never be able to _request_
  Administration, not just never hold it).
- **Cloudflare Secrets Store for the App's private key.** Rejected — see
  Context: no OIDC bridge to GitHub Actions exists, so it adds a hop and a
  standing Cloudflare credential instead of removing one, and inherits #10's
  unresolved state-trap risk. Revisit if Cloudflare ships GitHub Actions OIDC
  federation, or if a non-GitHub-Actions consumer (a Cloudflare Worker) needs
  this same key directly.
- **OAuth App / user-to-server flow for repo creation**, to give App-based
  automation full parity including new-repo creation. Rejected as
  disproportionate: it exists specifically to work around one narrow,
  infrequent operation this repo already handles deliberately by hand.

## Consequences

Every managed repo gains one App installation instead of a hand-minted PAT;
adding a new repo to the delegation model is `github_app_installation_repository`
data, not a UI trip. The App's private key becomes this account's single
highest-value credential — compromise mints tokens (still permission- and
repo-narrowable, but potentially broad) for every installed repo, so it needs
the same care as the elevated keyring session does today. Local/agent-shell
bootstrap is explicitly not solved here and needs its own follow-up (filed
under #19's implementation issues, not this ADR). New-repo creation keeps a
human in the loop permanently, not just until automation catches up — that's
a property of personal (non-org) GitHub accounts, not a temporary gap. Spike
issue #10 (Cloudflare Secrets Store) is now decided _for this specific
credential_; it stays open for whatever else it was evaluating beyond the App
key.
