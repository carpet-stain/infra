# 0018. Agent-memory backup durability - versioned B2 with a 365-day version floor

Date: 2026-08-14

## Status

Accepted

## Context

The agent-memory store (dotfiles ADR-0036) is a plain local directory on
one machine; its off-machine backup target is this repo's job (#159).
ADR-0017 already decided the vendor (B2, the versioned satellite) and the
management credential; this ADR is scoped to the **durability model** —
what protects a backup from being destroyed, and what the accepted loss
windows are. The client that writes backups is dotfiles#542's.

An earlier R2 design made "never destroy the last backup" an append-only
_client convention_ and was reversed for exactly that: a convention binds
only a correct client, and the failure the backup exists for is an
incorrect one.

## Decision

**Server-side versioning as the substrate, one lifecycle rule as the only
deletion path, immutability deferred to the client key** — `b2.tf`,
`b2_bucket.agent_memory_backups`.

- **Versioning is inherent.** B2 files are versioned unconditionally —
  the pinned provider's schema (v0.13.2) has no versioning toggle,
  verified per the build gate. A same-name upload supersedes the previous
  version; it cannot replace it. A buggy client overwriting backups
  degrades the history, never truncates it to zero.
- **One lifecycle rule is the sole retention/deletion mechanism:**
  `days_from_hiding_to_deleting = 365`, empty `file_name_prefix` (whole
  bucket), no `days_from_uploading_to_hiding` (current versions are never
  auto-hidden). Schema-verified: the rule governs "file versions that are
  not the current version" — superseded counts as hidden.
- **Immutability is the client key's job, not the bucket's** — and it
  arrives with dotfiles#542, not this change: the client gets a
  `writeFiles`-without-`deleteFiles` app key (mintable as code — the
  management key holds `writeKeys`, ADR-0017), so a leaked or buggy
  client credential can add versions but never purge them. **Enforcement
  boundary, stated plainly:** this protects against client-side loss
  only. The management key, or the account itself, can still delete —
  compromised-owner is out of this model's scope, priced by ADR-0017's Q7
  answer (backup history is the whole blast radius).
- **File lock stays off** (`is_file_lock_enabled = false`, explicit):
  enabling it is a one-way door (schema: modifying forces bucket
  replacement; B2 can't disable it once on), and object-lock's
  compliance-hold semantics fight the 365-day expiry this design needs.
  Versioning + no-delete key covers the threat model without it.
- **Security asserted in code, not by scanner:** trivy has no `b2_bucket`
  coverage, so `allPrivate` and SSE-B2 are pinned explicitly in `b2.tf`
  with the tripwire comment. Payload-side encryption is the client's
  call (dotfiles#542); SSE-B2 is the floor either way.
- **The RPO ceiling, accepted:** the 365-day rule is the only deletion
  path, so a corruption that goes unnoticed longer than 365 days can
  outlive the last good version. Guard: the backup-job liveness check
  (Healthchecks.io, ADR-0014 §3's alerting spine) — a blocking
  acceptance criterion on dotfiles#542, recorded there, not here.

## Alternatives considered

- **Append-only as a client write-convention on R2** (the reversed
  design). Rejected: no server-side enforcement — the convention holds
  exactly until the client misbehaves, which is the scenario being
  insured against. Vendor reasoning: ADR-0017, not re-argued.
- **B2 object-lock (file lock) for hard immutability.** Rejected: a
  one-way door (irreversible per bucket, forces replacement to change),
  and compliance retention contradicts the lifecycle expiry that bounds
  the RPO window. Revisit only if the threat model grows a
  compromised-management-key case worth that rigidity.
- **Shorter version floor (30/90 days).** Rejected for now: memory
  snapshots are KB-scale, so a year of versions is effectively free, and
  a longer floor widens the corruption-detection window the RPO ceiling
  depends on. Tunable when dotfiles#542 fixes the cadence.
- **Bucket-level immutability via a second guard bucket / replication.**
  Rejected: KB-scale personal data doesn't clear Simplicity First for a
  second replication target; the primary store is itself a live copy.

## Consequences

- A silently-dead client now degrades to a **stale backup**, not total
  loss — the current version has no expiry. The liveness check
  (dotfiles#542, blocking) is what bounds staleness.
- Restore is version-aware: fetch the current version, or any version
  within the 365-day floor (`b2 file`/S3 API — exit path per ADR-0017).
- The plan/drift CI jobs now hold the management key (there is no
  read-only B2 management credential today — one key, both scopes). A
  #144-style read/write split is a possible follow-up if B2's capability
  set can express a useful read-only management key; not done here.
- Until dotfiles#542 lands its no-delete key and liveness check, the
  bucket is a **versioning substrate only — not immutability**; the
  interim window is empty (no client, no data), so nothing depends on
  protection that isn't wired yet.
- **Revisit if** the store outgrows KB-scale (the free-tier trigger,
  ADR-0017 §6 decay check), or the 365-day floor proves mismatched to
  the client's cadence once real.
