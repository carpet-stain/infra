# 0017. Append-only agent-memory backups on R2

Date: 2026-08-13

## Status

Accepted

## Context

The agent-memory redesign (dotfiles ADR-0036) keeps memory in a plain
local store, which needs a durable off-machine backup. infra governs the
account's object storage, so the backup _target_ lives here; the backup
_client_ is dotfiles' (dotfiles#527, epic dotfiles#542).

The constraint that shapes the design: **R2 has no object versioning and
no object-lock** (both on Cloudflare's roadmap, not shipped), so "no bad
overwrite destroys the only backup" can't be a server-side guarantee.

## Decision

A second R2 bucket, `agent-memory-backups` (`cloudflare.tf`, the
`tofu_state` pattern — `prevent_destroy`, ADR-0012's semantics), holding
an **append-only backup history as a client write-contract**:

- Each backup is a **new timestamped key** — the client never overwrites
  or deletes. History is the object list itself.
- An age-based `cloudflare_r2_bucket_lifecycle` rule expires objects at
  **365 days** (whole-bucket scope; tunable once the client's cadence
  lands). Verified against the resolved provider 5.22.0's schema: the
  `delete_objects_transition` condition takes a relative `Age` in
  seconds, and an empty `conditions.prefix` scopes the rule to the whole
  bucket.

R2 as the store is `per ADR-0014 §3` (object-storage default; S3 with
egress exposure is Never) — not re-argued here.

## Alternatives considered

- **Option B — S3, for server-side versioning + object-lock.** Rejected:
  contradicts ADR-0014 §3's playbook row outright, and at KB scale with
  the primary store already local-redundant it doesn't clear §4's
  platform-gate; buying egress exposure to replace a write-convention is
  the wrong trade.
- **No lifecycle rule.** Rejected: append-only with no expiry grows
  unboundedly; at this scale the cost is trivial but the object list —
  the history a restore walks — degrades into noise.
- **Rely on `prevent_destroy` alone.** Rejected as insufficient by its
  own semantics: it guards the _bucket_ resource, not the objects (see
  the enforcement gap below).

## Consequences

- **Total-loss hazard: 365-day expiry + a silently-dead client.** If the
  backup job stops writing and nobody notices for a year, the lifecycle
  rule deletes the last backup — the expiry that keeps history bounded
  is also a deadline on noticing failure. The guard is a backup-job
  **liveness check** (Healthchecks.io, ADR-0014 §3's alerting spine) —
  a **blocking acceptance criterion on dotfiles#542/#527**, not this
  repo's scope.
- **Enforcement gap: append-only is convention, not control.**
  `prevent_destroy` guards the bucket, not its objects; a buggy or
  compromised client holding the bucket token can DeleteObject or
  overwrite, bypassing append-only entirely. The future control is a
  **no-delete R2 token scope** for the client — an **open question**:
  R2 token granularity may not express put-without-delete (Object
  Read & Write bundles them). Verify at dotfiles#542/#527 when the
  client's token is minted; the bucket-scoped token itself is deferred
  to that build.
- A restore is a plain object fetch (newest key, or any older one) —
  no version-API coupling; `rclone`/`aws s3` against the S3 API is the
  exit path, per ADR-0014 §3.
- **Revisit if** Cloudflare ships R2 object versioning or object-lock —
  either converts the write-contract into a server-side guarantee and
  likely retires the no-delete-token question.
