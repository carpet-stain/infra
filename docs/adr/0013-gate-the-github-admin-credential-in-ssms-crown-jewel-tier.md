# 0013. Gate the GitHub admin credential in SSM's crown-jewel tier

Date: 2026-08-09

## Status

Accepted

Extends ADR-0010 to the GitHub-credential class (complementing it, per the
new-ADR-not-in-place-edit rule — same pattern as ADR-0011).

## Context

ADR-0009/0010 fenced the backend secrets off from agent shells: crown-jewel
values live in `/infra/*` SSM parameters, fetched at invocation behind a
macOS Keychain prompt. GitHub credentials never got the same treatment. The
admin credential was a `gh auth login` OAuth session (scopes `repo,
delete_repo, admin:public_key, read:org, project`) in gh's keyring — which
reads without a prompt, so any local process could silently pull it with
`env -u GH_TOKEN -u GITHUB_TOKEN gh auth token`. Worse, the privilege was
inverted: the minimal dev PAT existed only inside infra's direnv, so
everywhere else gh's ambient fallback _was_ the admin session (#149).

Spike #150 pinned the replacement, validated live against a real plan/apply:
a fine-grained PAT drives every admin operation infra needs, including repo
creation on this user account (the one thing App installation tokens can't
do, ADR-0004) — no classic PAT required. The classic-only endpoint
documented in `app.tf` (`github_app_installation_repository`) stopped
mattering when that resource left tofu management.

## Decision

The admin credential is a **fine-grained PAT** — Administration, Issues, and
Variables all read/write, **All repositories**, 1-year expiry (the maximum) —
stored as the hand-populated `/infra/gh-admin-token` SecureString under
`alias/infra-secrets`, same as every crown-jewel value.

Variables read/write is a plan-review amendment to #150's validated spec:
Administration write already owns the blast radius (branch protection, repo
deletion), so excluding Variables bought no real containment while leaving
`gh variable set` seeding (docs/BOOTSTRAP.md) with no named credential.

`scripts/with-infra-secrets.sh --gh-admin` fetches it in the same batched,
Keychain-gated read as the backend secrets and exports it as `GITHUB_TOKEN`.
Two consumers: `just tofu-apply` and project-starter-template's
branch-protection bootstrap script. Plain `just tofu` (plan) deliberately
omits the flag — a plan process never holds the admin token, preserving the
plan/apply privilege split (#59).

The OAuth session's removal from gh's keyring is **not** a step here: gh
keys keyring accounts by username, so #151's `gh auth login --with-token`
with the dev PAT overwrites it — the login _is_ the eviction. A logout in
this change would leave gh credential-less in every repo until #151 lands.

## Alternatives considered

- **Keep the OAuth session.** Rejected — gh's keyring reads without a
  prompt; a silently-readable admin credential is exactly the hole the
  ADR-0009/0010 arc exists to close.
- **A classic PAT.** Rejected — #150 proved the fine-grained token
  sufficient live, and classic scopes are far broader than the three
  permissions actually needed (plus `delete_repo`, `admin:public_key`, and
  `project` rode along in the old session unused).
- **A separate macOS Keychain item read by a shim.** Rejected — SSM already
  is the gated crown-jewel tier; a second store means a second fence to
  audit and a second rotation surface for no added containment.
- **Excluding Variables write (#150's original spec).** Rejected at plan
  review — see Decision.

## Consequences

- Admin fails closed for agent shells: the only path to the token is the
  Keychain-prompted SSM read. ADR-0010's audit invariant now covers GitHub
  credentials too.
- **Rotation is now a real, recurring cost.** Fine-grained PATs hard-expire
  at one year; the OAuth session never expired. Rotation = mint a new token
  with the spec above, then `aws ssm put-parameter --overwrite --key-id
alias/infra-secrets` on `/infra/gh-admin-token`. The failure mode is a
  GitHub 401 at provider auth mid-`tofu-apply` — the wrapper can't pre-check
  expiry, so a calendar reminder ahead of the expiry date is the only
  mitigation.
- `infra-plan-read` (CI) can now decrypt the admin token on refresh — the
  same crown-jewel class as the App key it already reads; the invariant
  ADR-0010 names (no silently-readable **local** identity) is unchanged.
- Until #151 lands, the OAuth session still sits in the keyring as gh's
  ambient fallback — this change stops _relying_ on it; #151 evicts it.
- The KMS key on a hand-created parameter is a trap worth naming: the
  console default is `alias/aws/ssm`, whose account-wide `ViaService`
  decrypt grant bypasses the tier's second fence. This parameter was created
  that way and re-put under `alias/infra-secrets` before adoption; the
  population recipe in docs/BOOTSTRAP.md pins `--key-id` for exactly this
  reason.
