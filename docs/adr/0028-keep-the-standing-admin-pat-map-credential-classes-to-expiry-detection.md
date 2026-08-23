# 0028. Keep the standing admin PAT, map credential classes to expiry detection

Date: 2026-08-20

## Status

Accepted

Credential-class table's "GCP service accounts | keyless" row corrected by
ADR-0031 (#323) — see the Amendment section at the end.

Spike #245's answer (2 rounds of plan review). Two threads: whether the standing
admin PAT can leave the local apply path, and how the long-lived-credential
residual gets monitored.

## Context

**Thread 1 — can a local App-mint replace the admin PAT?** CI already applies
under a per-job App-minted token (`mint-app-token`, `tofu-apply.yml:121-129`);
only the **local** apply path (`with-infra-secrets.sh --gh-admin`) still loads
the standing `/infra/gh-admin-token` (ADR-0013). The candidate: a local
`--gh-app` mode using the `integrations/github` provider's
`data.github_app_token` (ADR-0004 named this as unvalidated).

Checked against the provider's source
(`github/data_source_github_app_token.go` + `github/apps.go`, v6.13): the data
source takes only `app_id`/`installation_id`/`pem_file` and calls `POST
/app/installations/{id}/access_tokens` with **no request body** — no
`permissions`, no `repositories`. GitHub's API rule for that endpoint: an
empty body mints a token carrying the installation's **entire** registered
grant, every repo it's installed on. `create-github-app-token` (what CI uses)
only narrows because it sends that same JSON body itself — the Terraform data
source doesn't. So `data.github_app_token` isn't a narrower replacement for
the admin PAT; it's **wider**: today's PAT holds Administration + Issues +
Variables on all repos (ADR-0013's spec); the data source would mint
Administration + Issues + Contents + Actions + Pull requests on all repos
(the App's full registration, ADR-0004), every local apply. A narrowed
local mint is possible, but only via a hand-rolled JWT → REST exchange
(sign an RS256 JWT, POST the same endpoint with an explicit `permissions`
body) — no existing Tofu or bash precedent in this repo does RS256 signing;
it would be new code, not reuse.

Even a narrowed local mint wouldn't shrink what the admin PAT has to remain:

- **Variables** — `create-github-app-token` has no `permission-variables`
  input at all (upstream #231); categorically unreachable by any App token.
  Open spike: #244.
- **Repo creation** — `POST /user/repos` categorically rejects App
  installation tokens on a personal account (ADR-0004's Consequences).
  #238 initially looked like a live regression of this (a 403 against the
  admin PAT itself), but resolved as a GitHub API incident, not a permission
  gap (PR #285: retested live, `201 Created`) — the residual was never
  actually broader than ADR-0004 already named, just briefly obscured by
  an outage.
- **External bootstrap** — project-starter-template's branch-protection
  script lives in another repo, reads the same admin PAT. Unchanged by
  anything decided here.

Because Variables + repo-creation need the PAT's full spec regardless, the
PAT's **storage, rotation cadence, and blast-radius-if-leaked don't shrink**
whether or not local apply's routine governance calls move to an App token.
The only thing a `--gh-app` mode buys is fewer local _reads_ of the crown-jewel
parameter for the common case (repo settings/rulesets/labels on existing
repos) — real, but marginal, set against a genuinely new signing code path.

**Thread 2 — detection for the residual.** ADR-0013:75-81 concluded a
fine-grained PAT's expiry can't be pre-checked, leaving a calendar reminder as
the only mitigation. Retested live against the routine dev PAT (also
fine-grained, same mechanism as the admin PAT) — `curl` against
`GET /user` with the full raw response headers shows no
`github-authentication-token-expiration` header at all, only the
classic-token-era `X-OAuth-Scopes`/`X-Accepted-OAuth-Scopes` pair GitHub
still advertises in `Access-Control-Expose-Headers` but never populates for a
fine-grained token. External research confirms that header exists and is
populated for **some** GitHub token types (OAuth-app tokens; historically
buggy through 2025) — but not fine-grained PATs, which is the specific class
this repo's admin/dev PATs are. ADR-0013's conclusion holds for that class,
confirmed fresh rather than re-derived.

The two agent PATs (`backlog-manager`, `plan-reviewer`) are a different token
class — **classic**, not fine-grained (BOOTSTRAP.md §13, #214) — and classic
tokens with an expiration date are the class GitHub's own changelog documents
the expiration header for. Not independently verified here (no read access
to either token from this session), but worth a targeted live check before
assuming they're calendar-reminder-only like the PATs above — they may be
the one PAT class in this account a scheduled check can actually pre-empt.

Building the inventory surfaced one correction to spike #245's own table: it
cited issue #235 (IAM Access Analyzer, the free **external-access** analyzer)
as the mechanism for AWS access-key rotate-on-policy detection. Epic #230
pins issue #235 to the free external-access tier only, explicitly excluding
the paid unused-access analyzer — external-access findings are about public
or cross-account exposure, not a key's last-used timestamp. The actual free,
purpose-built call is `aws iam get-access-key-last-used` — no analyzer, paid
or otherwise, required. A distinct mechanism, not something issue #235
happens to also cover.

## Decision

**Don't build a `--gh-app` local-mint mode.** The residual admin PAT can't
shrink in scope or rotation burden either way (Variables and repo-creation need
its full spec regardless), so the only available win — fewer local reads of
the crown-jewel token for routine governance — isn't worth a new hand-rolled
JWT-signing code path with no existing precedent in this repo, especially
since the one built-in primitive (`data.github_app_token`) would be a scope
_regression_, not an improvement, if used naively. Revisit only if a future
consumer needs App-token-only local automation for an unrelated reason, or if
the provider ships a narrowing data source.

**Per-class expiry/rotation detection mapping**, for whichever mechanism ends
up implementing the "monitor the residual" follow-up (#245 named this a
follow-up, not this spike's deliverable):

| Credential                                                                   | Class                                                 | Pre-checkable expiry?                                                                                  | Detection mechanism                                                                                           |
| ---------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| dev PAT, admin-PAT residual                                                  | fine-grained PAT, ~1yr hard expiry                    | No — confirmed live, no expiration header returned                                                     | Calendar reminder only (ADR-0013's conclusion, reconfirmed)                                                   |
| `backlog-manager`/`plan-reviewer` PATs                                       | classic PAT, ~1yr expiry (BOOTSTRAP.md §13)           | Possibly — classic tokens are GitHub's documented case for the expiration header, unverified live here | Live-check candidate before defaulting to a calendar reminder; fall back to one if the header doesn't hold up |
| Cloudflare API token (+ read-only pair)                                      | no expiration set at creation (BOOTSTRAP.md §9)       | Yes, in principle — Cloudflare's token-verify API reports `expires_on` when set                        | Low-priority scheduled check under #230, since no hard clock exists unless one gets set later                 |
| GitHub App RSA private key                                                   | no expiry — derived JWT/installation tokens auto-mint | N/A                                                                                                    | App/provider health only, not an expiry watch                                                                 |
| AWS access keys (`infra-local-apply`, `infra-local-read`, `infra-bootstrap`) | no expiry — rotate-on-policy                          | N/A (no expiry to check)                                                                               | `aws iam get-access-key-last-used`, **not** #235 (see Context)                                                |
| B2 management key, B2 backup-client key                                      | no expiry (BOOTSTRAP.md §11/§12, confirmed)           | N/A                                                                                                    | Periodic security audit only (already named, BOOTSTRAP.md §18)                                                |
| Neon management API key                                                      | no expiry (BOOTSTRAP.md §15/§18, confirmed)           | N/A                                                                                                    | Periodic audit + provider-health watch (already named)                                                        |
| R2 plan/apply key pairs                                                      | no TTL set at creation (BOOTSTRAP.md §1)              | Yes, in principle — same Cloudflare token-verify shape as the API token                                | Low-priority scheduled check under #230                                                                       |
| GCP service accounts                                                         | keyless — WIF-federated                               | N/A                                                                                                    | N/A                                                                                                           |
| `tf-state-passphrase`                                                        | long-lived, no expiry                                 | N/A                                                                                                    | Out of monitoring scope — rotation is state re-encryption (#245's own non-goal)                               |

Vended tokens (`/runtime/vended-token`, `/runtime/infra-dispatch-token`) stay
dropped from this table — ~1hr auto-minted, not a monitoring target, per
spike #245's own framing.

## Alternatives considered

- **Build `--gh-app` using `data.github_app_token` as-is.** Rejected — proven
  unnarrowable against the provider's own source; every local apply would
  mint a token wider than the admin PAT it replaces.
- **Build `--gh-app` via a hand-rolled JWT → REST exchange**, narrowed like
  CI. Rejected for now — technically sound (confirmed the endpoint accepts
  the same `permissions` body `create-github-app-token` sends), but the PAT
  it would partially replace can't be retired or shrunk regardless (both
  Variables and repo-creation still need it), so the win is read-frequency
  only, not scope or rotation cost. Revisit if a second local consumer wants
  App-scoped automation and the signing code amortizes across both.
- **Push for the App to cover repo-creation via an org migration.** ADR-0021
  already defers the org migration generally; nothing in this spike's
  findings changes that calculus enough to reopen it just for this one
  residual.

## Consequences

- `with-infra-secrets.sh --gh-admin` and `/infra/gh-admin-token` are
  unchanged — no new local credential path, no new SSM parameter, no rotation
  change.
- The calendar-reminder-only conclusion for fine-grained PATs (ADR-0013) is
  now empirically reconfirmed against a live token, not just recalled from
  the original spike.
- The two classic agent PATs get a concrete, cheap follow-up: a live check of
  whether `github-authentication-token-expiration` actually populates for
  them, before the monitor (a separate follow-up issue) assumes either the
  optimistic or pessimistic case.
- The AWS access-key detection line should cite `get-access-key-last-used`
  directly rather than #235 wherever this gets referenced going forward —
  #235 doesn't cover it.
- Non-goals unchanged: the routine dev PAT keeps existing, #238/#244 stay
  their own issues, and the monitor implementation itself is still a
  follow-up, not delivered here.

## Amendment — ADR-0031 (2026-08-23): GCP service accounts aren't all keyless

The credential-class table's "GCP service accounts | keyless — WIF-federated"
row held for every GCP SA in this repo until #323: the agent-memory edge
invoker (ADR-0031) is the first keyed exception, its key created out-of-band
and held in a Cloudflare Workers secret, never SSM or Tofu state. It has no
expiry to pre-check (same `N/A` as the row it corrects) and no automated
rotation — the trigger and owner are ADR-0031's own Consequences section,
not restated here. Every other row is unaffected; WIF-federation stays the
default for any new GCP SA, this is a named exception, not a reversal.
