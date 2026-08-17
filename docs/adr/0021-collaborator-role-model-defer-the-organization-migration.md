# 0021. Collaborator role model — defer the Organization migration

Date: 2026-08-16

## Status

Accepted

## Context

infra#172 applied `plan-reviewer` at `read` cleanly across all 7 managed repos,
but every `backlog-manager` at `triage` 422'd (`Field:permissions Code:invalid`).
Spike #207 was filed to resolve the role model this exposed.

The spike's own plan-review already resolved the tactical half: the
deliberation agents' actual need per ADR-0035 is _attributed commenting_, which
`read` already satisfies, with labeling/assigning riding the existing
`issues: write` App token (ADR-0004) — no restructuring required.
infra#172/dotfiles#540 are unblocked on that basis. What's left, and what this
ADR resolves, is the strategic question #207 re-scoped to: is converting
`carpet-stain` to a GitHub Organization the right home for a _named-account_
`triage` role, and for the #545 team-of-agents direction generally — decided
deliberately, not because the 422 forces it.

**Verified, doc-first (not from memory):**

1. **`triage`/`maintain` are Organizations-only, full stop.** GitHub's own
   "Permission levels for a personal account repository" doc: a personal-owned
   repo has exactly two levels — owner, and collaborator (pull + push only) —
   and states plainly that more granular roles require "transferring the
   repository to an organization." No personal-account plan tier (Free, Pro,
   Team) changes this; the roles don't exist on user-owned repos at any price.
   **Option A (upgrade to Pro) is dead**, confirmed by documentation, not
   inference from the 422 alone.
2. **A Free organization gets the full role set at no seat cost.** GitHub's
   organization repository-roles doc ties no plan restriction to `triage`/
   `maintain` themselves (only some sub-features are Enterprise-gated), and
   Free-plan organizations carry **unlimited, unpaid** members and outside
   collaborators — seat billing only starts on Team/Enterprise. An org costs
   nothing extra to adopt on the role-and-seat axis alone.
3. **The mechanism #207 asked to disambiguate no longer exists.** #207 framed
   this as B-i (convert `carpet-stain` in place, _maybe_ preserving the
   numeric owner ID that `iam/main.tf:9` pins the OIDC `sub` claim to) vs B-ii
   (new org + repo transfer, owner ID unconditionally changes). **GitHub
   deprecated direct user-to-organization conversion entirely on 2026-01-12**,
   replaced by "Move work to an organization" — which moves selected
   repositories into a **new or existing org while the original personal
   account survives untouched**. That's B-ii's shape, not B-i's: there is now
   only one mechanism, and it unconditionally mints a new owner ID. The
   ID-preservation question #207 asked us to pin "before sizing anything else"
   is answered by GitHub having removed the branch that could have preserved
   it — not by empirical testing.
4. **Repo-transfer mechanics** (what "Move work" performs): webhooks,
   secrets, and deploy keys stay attached; GitHub auto-redirects the old
   `owner/repo` URL for web, and for `git clone`/`fetch`/`push` — until
   something new is created at the vacated name, which permanently kills the
   redirect. Undocumented for GitHub Apps specifically, but Apps are
   independently known to be **owner-scoped installations**: a transferred
   repo doesn't carry its old account's App install with it, so the
   destination org needs its own install regardless (ADR-0004's flow, run
   again for the new owner → new install ID → re-vend).
5. **In-place conversion was never actually cheaper on the App axis anyway** —
   GitHub's own (now-retired) docs for it said outright: "Any GitHub Apps
   installed on the converted personal account will be uninstalled." The only
   thing B-i might have saved was the OIDC re-pin, and GitHub's docs never
   asserted numeric-ID preservation for it even while it existed — only
   username retention. So its removal costs nothing #207's plan was actually
   relying on as a load-bearing saving.

Net: #207's "B-i vs B-ii, opposite risk, pin the mechanism first" framing is
moot. Any future org migration is unconditionally: new org (new owner ID) +
repo transfer + OIDC re-pin (`iam/main.tf`) + App reinstall/re-vend + label/
ruleset re-provision (tofu handles this idempotently once the provider owner
repoints) + an org-member-vs-outside-collaborator call for the two machine
users + a submodule-URL check in dotfiles (soft risk — redirects hold until
the old name is reclaimed) + branch-protection re-verification.

## Decision

**Confirm Organization as the eventual correct home**, once a real structural
need exists — named-account-authored `triage` labeling, or #545's
team-of-agents model — but **defer executing the migration**. Nothing
currently depends on it: infra#172/dotfiles#540 are already resolved at
`read` + App-token labeling, with zero restructuring. Running an irreversible,
owner-ID-breaking migration for a role nobody currently needs is the thing
this spike's own non-goals warned against ("don't let the 422 force the flip").

**When it is eventually triggered**, execute it as a single mechanism (new
org + "Move work" repo transfer), staged reversibly:

1. Create the org; register + install the GitHub App on it; prepare the
   re-vend path — all inert, nothing production depends on it yet.
2. Decide org-member vs outside-collaborator for `backlog-manager`/
   `plan-reviewer` on the new org — outside-collaborator is cheaper
   (no membership-wide visibility) and still gets the full role grant on
   Free, so it's the least-privilege default; revisit only if org-only
   features later require membership.
3. The point of no return: transfer/move the repos, re-pin `iam/main.tf`'s
   OIDC `sub` to the new owner ID, and flip the App installation/vended-token
   source to the org **in the same change** — a split between these leaves
   `AssumeRoleWithWebIdentity` or routine `gh` tokens dark, not just stale.
4. Verify OIDC assumption, vending, and the dotfiles `agents` submodule URL
   resolve post-move before treating it as done; update the submodule URL
   even though the redirect holds, so it isn't a silent single point of
   failure the day someone reclaims `carpet-stain/agents`.

Tracked as #208, **blocked on the trigger** (dotfiles#545 concretely needing
it) — not scheduled now.

## Alternatives considered

- **Option A — upgrade the personal account to GitHub Pro/Team.** Rejected:
  confirmed via GitHub's own docs that `triage`/`maintain` don't exist for
  user-owned repos at any plan tier — there's no version of "pay for it" that
  works.
- **Option C — grant `write` + a scoped PAT + branch protection.** Already
  rejected by the maintainer in #207: over-grants the collaborator role even
  though the PAT scope and branch protection would neutralize the push in
  practice — a role that can structurally push conflicts with dotfiles#540's
  least-privilege intent regardless of whether the capability is exercised.
- **Execute the org migration now, off #172's 422.** Rejected: nothing
  currently needs it (`read` + App-token labeling already unblocks the
  agents), and GitHub's 2026-01-12 deprecation made the migration strictly
  riskier than #207 assumed (mandatory owner-ID change, no in-place option) —
  better to absorb that risk once, deliberately, when #545 gives it a real
  trigger, than pre-emptively for a role nothing currently exercises.
- **In-place conversion ("B-i").** Not a live alternative — GitHub retired
  the feature 2026-01-12; "Move work to an organization" is the only
  mechanism now, and it's B-ii's shape (new owner ID, unconditionally).

## Consequences

infra#172/dotfiles#540 stay resolved as-is — `backlog-manager` labels via the
App token, both machine accounts are attributed commenters at `read`; nothing
in `repos.tf`/`main.tf` changes as a result of this ADR. The runbook above is
the reference a future migration issue works from, captured while the
investigation is fresh instead of a cold start later. `iam/main.tf`'s OIDC
`sub` pin (`carpet-stain@5483606`) is the load-bearing follow-up whenever that
migration happens — it must move in the same change as the App
install/re-vend flip, not before or after. ADR-0004's personal-account
constraints (App tokens can't create repos or install App-repos) stay in
force until then — a standing, deliberate exception, not a gap to close
urgently. Revisit this ADR's "defer" call the moment #545's team-of-agents
design concretely requires named-account-authored labeling or org-scoped
structure — that's the trigger, not a calendar date.
