# 0015. Console-only IAM admin user, root break-glass-only

Date: 2026-08-13

## Status

Accepted

Amends ADR-0010 (the audit-invariant clause only — its store model and
role×path matrix stand unchanged).

## Context

Interactive console work ran as root: every non-root identity in the
account is programmatic (the OIDC CI roles, the Keychain-gated local
users, the deactivated `infra-bootstrap` key). Root is MFA'd and keyless
(BOOTSTRAP.md §3), but daily console use of root is the anti-pattern —
root should be break-glass-only, the AWS-side mirror of the GitHub
least-privilege split (#149, #155).

The constraint shaping every mechanical choice below: `iam/` is applied
by `infra-bootstrap`, whose policy holds `iam:PutUserPolicy` but neither
`iam:AttachUserPolicy` nor `iam:TagUser` — so the admin grant must be an
inline user policy (a managed `AdministratorAccess` attachment 403s the
apply), and the user stays untagged, both matching the module's existing
direct-user-policy convention.

## Decision

`infra-console-admin`: an `aws_iam_user` + one inline
`aws_iam_user_policy` in `iam/`, everything credential-shaped out of
state — the console password and MFA device are enrolled by hand
(BOOTSTRAP.md §5), password + recovery in the Bitwarden human vault
(ADR-0010 scopes human credentials there).

The one policy document:

- **`Allow *:*`** — the admin grant.
- **`Deny iam:CreateAccessKey` on its own ARN** — defense-in-depth
  against the casual self-key click, _not_ containment. This identity is
  escalation-class: like `infra-bootstrap`, it can mint keys for or
  create other identities via the console. Containment rests on
  console-only + enforced MFA + human discipline.
- **MFA enforcement** — `Deny` with `NotAction` = the enrollment set and
  `BoolIfExists aws:MultiFactorAuthPresent = false`, on `Resource: "*"`
  (load-bearing: a narrower resource would let reads on other ARNs
  escape the deny). Pre-MFA the user can only enroll; post-MFA it can do
  everything except self-`CreateAccessKey`.
- **Enrollment exemption Allows**, scoped to `user/${aws:username}` +
  `mfa/${aws:username}` (the two account-level `Get`/`List` calls IAM
  can't resource-scope ride `Resource: "*"`). The set includes
  `iam:DeleteVirtualMFADevice` so an abandoned-then-retried enrollment
  can delete its orphaned device instead of `EntityAlreadyExists`-locking
  the user out to root. `iam:DeactivateMFADevice` is deliberately
  omitted: device-loss recovery is a stated root break-glass path.

**The audit invariant splits into two fences** (canonically worded in
ADR-0010's #155 amendment and `iam/main.tf`'s header):

- _(a) Steady-state read-reachability_ — the existing invariant, now
  explicitly scoped to the non-escalation set (`infra-local-*`, the CI
  roles, `infra-vend-write`'s one-ARN carve-out): no silently-readable
  key-holding identity resolves `kms:Decrypt` on `alias/infra-secrets`.
  The silently-readable qualifier stays — `infra-local-apply` resolves
  the key, but never silently (per-read Keychain prompt).
- _(b) Escalation class_ — `infra-bootstrap` and `infra-console-admin`
  reach anything by construction; their fence is human ceremony (MFA
  console session, no programmatic key, deactivation/discipline), not
  the path/key boundary. The console admin's post-MFA reads are silent
  per-read — a weaker fence than `infra-local-apply`'s prompt — so it is
  explicitly **not** folded into fence (a)'s carve-out.

Root keeps only billing, close-account, and root-only IAM tasks —
break-glass, not a daily driver.

## Alternatives considered

- **IAM Identity Center** — overkill for one human in one account
  (Simplicity First), and it breaks the module's direct-user pattern for
  no containment gain at this scale.
- **Managed `AdministratorAccess` attachment** — `infra-bootstrap` lacks
  `iam:AttachUserPolicy`; granting it that for a one-user convenience
  widens the bootstrap key for nothing inline can't do.
- **Permissions boundary on the admin** — boundaries cap identities the
  capped user _creates_; on the daily-driver admin itself a boundary is
  self-defeating (it either blocks admin work or is `*:*` and inert).

## Consequences

- Daily console work needs no root session; the periodic audit gains
  "root still break-glass-only" alongside the bootstrap-key item.
- Two invariant fences to audit instead of one sentence — the cost of
  naming the escalation class honestly instead of pretending the `Deny`
  contains it.
- MFA device loss is a root ceremony by design (no
  `iam:DeactivateMFADevice` self-service).
- The enrollment flow is order-sensitive: the virtual device must be
  named exactly `infra-console-admin` or the `mfa/${aws:username}` scope
  denies the enable — BOOTSTRAP.md carries the loud warning.
