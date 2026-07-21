---
name: open-work
description: Pending backlog follow-ups on infra — the theme cloudflare label gap and epic implementation issues awaiting spikes
metadata:
  type: project
---

Outstanding follow-ups after the first backlog fill (2026-07-18):

**Epic #50 (Bitwarden Secrets Manager) — code shipped 2026-07-20, epic + all three sub-issues
stay open pending manual verification.** PR #58 merged all three sub-issues' implementation
(#46 provider wiring, #47 App-key migration, #51 token vending) in one PR, deliberately not using
`Closes #N` — the acceptance criteria on #46/#47/#51 (and the epic) require a one-time manual
Bitwarden bootstrap (Organization, both Projects, three Machine Accounts, the grants between them)
plus live verification (`tofu plan` clean, the vended-token write-rejection test, a `vend-token.yml`
dry run) that only a human can do against real Bitwarden state — not provable in CI, so the
issues can't be marked done by the merge. Posted a status comment on all four (#46, #47, #50, #51)
listing the specific remaining-to-verify items per issue's own acceptance criteria. ADR-0008
(`docs/adr/0008-bitwarden-secrets-manager-two-project-store-and-token-vending.md`) records the
decision, resolving infra#33. Bootstrap steps live in `docs/BOOTSTRAP.md` §6; the Machine-Account
grant table lives in AGENTS.md — don't restate either into issue bodies. #59 (migrate the
remaining standing secrets — TF_STATE_PASSPHRASE, R2 credential pairs, CI GH_TOKEN) was filed as a
deferred follow-up, not part of this epic's closing bar. **When the bootstrap is eventually done**,
these four issues need closing by hand (not a PR merge) with a comment confirming what was verified.

**`theme: cloudflare` label — tracked by issue #13 (sub-issue of Epic #6).** Approved to add to
`local.labels` in repos.tf (color F38020, desc "Cloudflare account surface — provider, zones, DNS,
R2, stores"). Does NOT exist in GitHub yet — labels are terraform-managed, needs the repos.tf edit
+ `just tofu-apply` (elevated token). NEVER `gh label create`. Note: `setproduct` wiring in main.tf
means the entry creates the label on BOTH infra and dotfiles (shared canonical set).
**Why:** issues #7-#10 were filed WITHOUT it to avoid blocking on the label round-trip.
**How to apply:** once #13 is applied and the label exists, apply `theme: cloudflare` to #7-#10.

**Implementation issues gated on spikes.**
- Epic #11 (ci/cd apply pipeline): spike #12 is **decided and closed** (2026-07-19) — ADR-0003
  (`docs/adr/0003-ci-apply-pipeline-saved-plan-on-merge-model.md`) picks **Option 1** (apply the
  exact saved plan), reversing #12's original "leaning toward Option 2" note. The leaning flipped
  because its stated blocker against Option 1 (plan files need encryption) was already solved by
  ADR-0002's `TF_ENCRYPTION`, and once that's gone, saved-plan's stale-plan safety net (OpenTofu
  refuses to apply if state moved) beat re-plan-on-merge at this repo's scale. Read the ADR
  directly for the full reasoning — don't rely on this summary. Implementation issues filed under
  #11: #24 (plan-on-PR workflow + PR comment, not blocked), #25 (apply-on-merge workflow), #26
  (`workflow_dispatch` apply-main escape hatch). **#25 and #26 are blocked on #19** (native
  `blocked-by` + `blocked` label) — CI has no mechanism yet to hold the elevated
  Administration-scope credential apply needs; don't start either before #19 resolves.
- Spike #10 flags the tofu-state-write trap, still open, still "leaning to validate," NOT decided.
  Don't treat the leaning as the outcome.

**Epic child dependencies:** #8 and #9 depend on #7 (provider must land first). Reflected in their
bodies, not in a label — no native dependency link set.

**#19 (spike, architecture, `theme: credentials`, priority medium) — GitHub PAT provisioning +
cross-repo delegation model, filed 2026-07-18.** Not a child of epic #6 — deliberately standalone,
since it's account-wide (every managed repo's credential model), not Cloudflare-scoped. Decided:
ADR-0004 (`docs/adr/0004-github-app-pat-provisioning-and-cross-repo-delegation-model.md`) closes
#19 — adopt a single GitHub App (installation tokens minted via API, no long-lived human-owned
PAT), tracked as epic #28. See the epic #28 entry below for the full follow-on (ADR-0004 was
itself amended by ADR-0005 before any of it shipped).

**Epic #28 (`epic(tofu): adopt GitHub App for PAT provisioning and delegation`) — ADR-0004
accepted 2026-07-18, amended by ADR-0005 2026-07-19.** Sub-issues: #29 (register the App), #30
(install across `local.repos`), #31 (propagate the private key), #32 (mint scoped tokens in CI),
#33 (local/agent-shell bootstrap — separate open spike, `GITHUB_TOKEN` can't reach outside CI,
tracks dotfiles#160). #31/#32 unblock epic #11's #25/#26.

During #28's plan review, #31 as drafted diverged from ADR-0004's literal text (a scoped-down key
holder instead of blanket `for_each` propagation over `local.repos`) — reverted to match the
accepted ADR rather than ship a silent divergence, and spike #34 filed to gate the reconsideration
deliberately instead of deciding it inline. **#34 resolved 2026-07-19: ADR-0005**
(`docs/adr/0005-scope-the-github-app-private-key-to-infra-only.md`) **amends ADR-0004** — the
App's private key is held only by `infra` (a single `github_actions_secret` in `infra`'s own
repo), not propagated to every repo in `local.repos`; `infra`'s CI is the sole minting authority
for any App-issued token, including the elevated `administration`-scope ones #25/#26 need. Read
ADR-0005 directly for the full reasoning (the per-mint-narrowing-doesn't-defend-against-a-raw-key-
holder argument, and why ADR-0004 reached for blanket propagation in the first place — personal
account, no org-secret-restricted-to-N-repos feature to fall back on) — don't rely on this summary
for anything written into an issue. #31 and #32 rewritten to match (infra-only secret, infra-only
minting); the native `blocked-by #34` link removed from both (#31 stays `blocked` — still blocked
by open #29; #32 was never `blocked`-labeled). Epic #28's body corrected to match. #33 stays open,
unaffected either way — ADR-0005 says so explicitly.

**Reusable fact for future credential-scoping issues:** every GitHub Actions job already gets a
repo-scoped `GITHUB_TOKEN` for free, set via that workflow's own `permissions:` block — that
covers all *same-repo* CI work (issues/PRs/contents/actions). The App (and its private key) is
only for `infra`'s *cross-repo or elevated* (`administration`-scope) work. Don't reach for an
App-minted token for routine same-repo automation in any managed repo — check whether
`GITHUB_TOKEN` already covers it first.

See [[backlog-conventions]] and [[label-taxonomy]].

**#22 (enhancement, priority medium) — import `golden-ratio-dual-gate` into `local.repos`,
filed 2026-07-18, simplified 2026-07-19.** Originally scoped as this account's first *private*
repo, which surfaced a real gap: GitHub's branch-protection mechanisms (classic API and
Rulesets) require a paid plan for private repos — verified via GitHub's docs and a live 403
against this exact repo. Went through five plan-review rounds designing a `visibility`-based
`for_each` exclusion for `github_repository_ruleset.this` before the user decided (2026-07-19) to
make the repo public instead, resolving the whole plan-tier question outright. Issue rewritten to
drop `architecture`/`plan-approved` — it's now the same "adopt an existing repo" shape as
`project-starter-template`#14, no gate needed. **The private-repo analysis is kept in #22's body
as precedent**, not deleted — worth reading if a genuinely private repo ever needs onboarding:
the key finding was that `github_repository.this`'s merge-method settings
(`allow_rebase_merge`/etc.) are unconditional regardless of visibility, but
`github_repository_ruleset.this`'s four bundled protections (deletion, force-push,
PR-requirement, required-checks) are only available on a paid plan for a private repo — excluding
the ruleset loses all four, not just CI-gating.
