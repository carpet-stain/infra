---
name: open-work
description: Infra decision records — ADR pointers, why, and non-recoverable lessons; live status lives on the issues
metadata:
  type: project
---

Decision records for infra's major threads. Live status lives on the issues — check `gh issue
list`/`gh issue view` before assuming anything below still holds.

**Epic #50 (Bitwarden Secrets Manager)** — shipped via **ADR-0008**
(`docs/adr/0008-bitwarden-secrets-manager-two-project-store-and-token-vending.md`). Bootstrap
steps: `docs/BOOTSTRAP.md` §6. Machine-Account grant table: AGENTS.md's Bitwarden section — don't
restate either here. Implementation gotchas (provider `api_url`/`identity_url` has no defaults;
`ignore_changes = [value]` on each secret resource; `skip-token-revoke` on the vended token) are
documented inline where they're load-bearing: `versions.tf`, `app.tf`, `cloudflare.tf`,
`vend-token.yml`.

**#59 (migrate remaining CI/local secrets to Bitwarden)** — completes the Bitwarden arc with #50.
CI's routine `GH_TOKEN` PAT retired in favor of an App-minted token (plan mints
`administration:read`+`issues:read`); local elevated secrets fetch from Bitwarden at invocation
via `scripts/with-infra-secrets.sh`, gated behind a macOS Keychain prompt (**ADR-0009**). `bws`
CLI packaging (not on Homebrew) is tracked in `carpet-stain/dotfiles#388` — machine-tooling layer,
not this repo's job.

**Epic #11 (ci/cd apply pipeline)** — **ADR-0003** decides the saved-plan-on-merge model (apply
the exact saved plan). The original leaning was re-plan-on-merge, until ADR-0002's
`TF_ENCRYPTION` solved that option's stated blocker (plan files need encryption). Read the ADR
directly for the full reasoning. Implementation issues #24-#26; #25/#26 (apply-on-merge,
dispatch escape hatch) were deliberately sequenced after epic #28's credential-delegation work,
not before it.

**Epic #28 (GitHub App PAT provisioning)** — **ADR-0004** (single GitHub App, installation tokens
minted via API) amended by **ADR-0005** (private key scoped to `infra` only, never propagated
account-wide) after a plan-review catch mid-implementation — see [[backlog-conventions]]'s
plan-review-vs-ADR pattern for how that reconsideration was gated, rather than decided inline.
Sub-issues #29-#33. The App's private key later moved into Bitwarden (#47) — the native Actions
secret ADR-0004/0005 describe no longer exists; **ADR-0008** is the current source for where the
key lives.

**#73 (where a new secret class lives once the 3-account cap is spent)** — resolved via an
**ADR-0008 amendment**: dotfiles' own `GH_TOKEN` retires onto the vended-token path
(`dotfiles#377`); an LLM-API-key store is deferred until a local (non-CI) consumer exists
(`dotfiles#399`/`#400`). #76 (vend cadence vs. the App token's 1h TTL) gates that `dotfiles#377`
migration directly — see #76's own thread for why, already recorded there.

**#22 (import `golden-ratio-dual-gate`)** — the public-vs-private design question is decided
(public, not the import itself): GitHub's branch-protection Rulesets require a paid plan for a
private repo (verified live), so going private would have needed a `visibility`-based `for_each`
exclusion. The technical precedent is kept deliberately in **#22's own body**, not here — read it
if a genuinely private repo needs onboarding later; check #22 itself for the import's status.

See [[backlog-conventions]] and [[label-taxonomy]].
