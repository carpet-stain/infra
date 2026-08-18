# 0025. Repurpose B2 for pg_dump DR of the Neon store, superseding ADR-0018

Date: 2026-08-17

## Status

Accepted

Supersedes [0018. Agent-memory backup durability](0018-agent-memory-backup-durability-versioned-b2-with-a-365-day-version-floor.md)
in status only — its versioning/lifecycle/no-delete-key decisions carry
forward unchanged (see Decision).

## Context

carpet-stain/dotfiles ADR-0046 moved agent memory off the local JSONL store
ADR-0018 was backing up onto a hosted **Neon Postgres** store (this repo's
ADR-0023 bootstrapped the provider). ADR-0046 named the resulting question
directly: does B2 get re-purposed for Postgres-dump DR, or decommissioned?
dotfiles#638 is that spike; this ADR is its answer, recorded where the ADR
it revisits lives.

**What Neon's own recovery covers, verified against current docs — and its
limits:**

- **Point-in-time restore / history window** is same-account, same-vendor
  recovery of live branch state: **6 hours on Neon's Free plan** (1 day
  default on paid, configurable to 7 days on Launch or 30 days on Scale).
  This deployment is explicitly scoped to the Free plan — ADR-0023 checklist
  item 8 and dotfiles epic #602's kill-switch both name it as the assumed
  tier. It restores a bad query or accidental delete; it is not a backup.
- **Deletion recovery** undoes an accidentally-deleted _project_ within 7
  days — still Neon's own account/infrastructure, narrower than PITR, and no
  help if the loss is at the Neon-account level (compromise, vendor
  outage/death) rather than a single project.
- ADR-0023 itself declined to count either as a backup: checklist item 9
  states "`pg_dump` is a migration tool, not a backup, until #602 names a
  scheduled, restore-tested path" — deferred here, not answered.

**What ADR-0017/0018 already built solves exactly that gap for the old
store:** an independent vendor account (B2, a fourth vendor precisely to
reduce correlated blast radius against the existing spine, ADR-0017 §7/§2.8),
server-side versioning, a no-delete client key, a 365-day version floor
sized to the corruption-detection RPO, and healthchecks liveness monitoring
already wired (`backup-agent-memory.sh`). None of that is JSONL-specific —
the bucket (`b2_bucket.agent_memory_backups`) and its lifecycle rule hold
whatever object a client pushes.

## Decision

**Repurpose B2 — don't decommission it.** The bucket, its server-side
versioning, the 365-day lifecycle floor, and the no-delete client-key model
(ADR-0017/ADR-0018) carry forward unchanged. What changes is the object a
scheduled job pushes: a `pg_dump` snapshot of the Neon store, instead of the
JSONL file. Designing and scheduling that job is dotfiles#634's migration
scope, not this ADR — this ADR is the durability-model decision that scope
builds against, the same relationship ADR-0017 (vendor pick) already has to
ADR-0018 (durability model) it amends.

**Two lines of defense, not one replacing the other:**

- **Neon PITR/instant-restore stays the first line** — fast, in-place, the
  right tool for the common case (a bad write caught within hours to days).
- **B2/pg_dump is the second line**, for the class of loss PITR structurally
  cannot cover: Neon account compromise or vendor-level loss. This mirrors
  ADR-0018's own accepted threat-model boundary (protects against
  client-side/vendor-outage loss, not a compromised owner) — now symmetric
  on both vendors: a compromised Neon account can still delete live data
  and, within the 7-day project-recovery window, its own recovery path; a
  compromised B2 account is the gap ADR-0018 already priced and accepted
  (ADR-0017 §7's answer to "vendor dies or the account is compromised").

**No `b2.tf` resource change here.** Same bucket, same lifecycle rule, same
365-day floor — no premise in ADR-0018's durability model changed, only the
object shape. The floor is worth revisiting once dotfiles#634's migration
lands real pg_dump snapshot size/cadence numbers, not pre-emptively here.

## Alternatives considered

- **Decommission B2, rely on Neon PITR alone.** Rejected: a 6-hour (Free) to
  30-day (Scale) window is same-account/same-vendor recovery, not backup —
  it doesn't survive Neon account compromise or vendor death, exactly the
  class of loss B2's independent account exists to cover (ADR-0017 §7).
  ADR-0023 itself declined to call PITR a backup.
- **Rely on Neon's 7-day deletion-recovery window as sufficient DR.**
  Rejected: still Neon's own infrastructure, narrower in scope than PITR
  (project-level undelete, not point-in-time), and no protection against
  account-level compromise or corruption that goes undetected past 7 days —
  ADR-0018's 365-day floor already rejected windows this short for exactly
  that reason.
- **A second, independent replication target instead of B2.** Rejected:
  KB-to-MB-scale data, the same Simplicity-First reasoning ADR-0018 already
  used to reject a second guard bucket — and B2's versioned/no-delete
  substrate is built and already paid for.
- **WAL-shipping instead of `pg_dump` snapshots.** Rejected: ADR-0014 §3 and
  ADR-0023 already name `pg_dump` as Neon's exit path; WAL-shipping
  duplicates Neon's own PITR mechanism at real operational cost for a
  capability this design doesn't need — the gap being closed is
  vendor-independence, not sub-day RPO, which PITR already covers.

## Consequences

- Unblocks dotfiles#634's migration scope to design the actual
  pg_dump-to-B2 job (schedule, credentials, restore-tested path) against a
  settled durability model instead of an open question.
- dotfiles' `backup-agent-memory.sh` header currently reads "disposable —
  replaced once the hosted store carries its own DR." That premise is false
  at the Free-plan PITR window; dotfiles#634 replaces the script's target
  object (JSONL → pg_dump), not its existence.
- ADR-0018 is superseded in status only — its versioning, lifecycle, and
  no-delete-key decisions are the substrate this ADR reuses verbatim; a
  reader asking "does this store still need B2" now lands here first.
- **Revisit if** Neon's paid-tier PITR window (30 days on Scale) plus the
  7-day deletion-recovery window are ever judged sufficient without an
  independent vendor — that requires explicitly re-litigating ADR-0017 §7's
  correlated-blast-radius reasoning, not assuming it away — or pg_dump
  snapshot size/cadence argues for a shorter-than-365-day version floor once
  dotfiles#634 lands real numbers.
