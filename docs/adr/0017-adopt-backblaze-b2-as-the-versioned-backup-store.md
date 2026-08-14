# 0017. Adopt Backblaze B2 as the versioned backup store

Date: 2026-08-13

## Status

Accepted

## Context

The agent-memory backup (#159, dotfiles#542) needs object storage with
**server-side versioning**, so a buggy or compromised backup client can
only add versions, never destroy the last good one. R2 — the ADR-0014 §3
object-storage default — has no versioning or object-lock (both roadmap,
not shipped); an earlier R2 plan compensated with an append-only client
_convention_ and was reversed on 2026-08-13 for exactly that weakness: a
convention isn't a control.

That makes B2 a **fourth vendor in the stack** (after GitHub, Cloudflare,
AWS), which is a real adoption decision, not a bucket detail: this ADR
answers ADR-0014 §5's checklist and fixes the management credential's
residency. The bucket itself, its lifecycle, and the durability model
belong to #159's ADR; the client's no-delete key is dotfiles#542.

## Decision

**Adopt Backblaze B2 as the versioned backup satellite**, provisioned
through the `Backblaze/b2` tofu provider (`~> 0.13`, `versions.tf`).

**ADR-0014 §5 checklist:**

1. **Class:** Protocol on the data plane — S3-compatible object storage,
   `rclone`/any S3 client reads it all back. Stated plainly so the
   classification isn't overclaimed: the _management_ plane (tofu
   provider, key minting) speaks B2's native API, not S3 — acceptable
   because management state is this repo's HCL, re-creatable anywhere.
2. **Artifact:** objects — standard.
3. **Exit:** `rclone` to any S3 target, per §3's own playbook row (B2 is
   §3's named object-storage alternate).
4. **Egress exposure:** ~nil at KB-to-MB scale; B2 egress is also free up
   to 3× stored data, orders of magnitude above a backup-restore pattern.
5. **Replaces something self-hostable?** No — off-machine durability is
   the requirement; storage on the machine being backed up can't satisfy
   it, whatever it costs.
6. **Terraform provider:** official (Backblaze-owned) but low-velocity —
   a §2.6 yellow flag priced in, not a blocker: the surface consumed is
   two resource types on a stable API, and the exit path (3) doesn't
   depend on the provider at all.
7. **Vendor dies / suspends the account:** backup history is lost,
   nothing else — the primary store is local and unaffected, and the
   fourth account _reduces_ correlated blast radius (§2.8's priced risk
   of co-locating backups on the Cloudflare spine account that already
   holds DNS, edge, and tofu-state). Re-provision elsewhere = this repo's
   HCL + one fresh backup cycle.
8. **Free-tier terms:** 10 GB stored free today, KB-scale usage — the
   flip trigger is storage growth or Backblaze repricing. A §6 decay
   item: re-checked on the periodic audit, not trusted.

**Satellite, not spine** (§7): object storage, replaceable via `rclone`;
identity/crypto stay on AWS, DNS/edge on Cloudflare. B2 gets no
governance role beyond holding backup bytes.

**Credential residency** — by citation, not re-derivation: the
management application key is fetched by automation, long-lived and
high-value, so ADR-0016's tree lands it in SSM `/infra/*`
(`b2-management-key-id` + `b2-management-key`, `alias/infra-secrets`,
hand-populated, metadata-only in `ssm.tf`). ADR-0010's fences hold:
consumers, when #159 wires them, are the CI OIDC roles' existing
`/infra/*` path grants and the prompt-gated `infra-local-apply` — never
a silently-readable local identity. Until then nothing fetches it: the
`provider "b2"` block is empty and lazy (the cloudflare precedent in
`versions.tf`), so no CI or wrapper wiring exists in this repo yet.

**The management key is a named key, not master** (BOOTSTRAP §11):
account-level with the bucket- and key-management capability set,
including `writeKeys`/`deleteKeys` so tofu can later mint the client's
no-delete key as code — a named B2 key can only grant capabilities it
holds. The master key stays unrecorded break-glass, regenerable from the
MFA'd console — same shape as the AWS bootstrap key.

## Alternatives considered

- **Stay on R2** (the reversed #159 Option A). Rejected: no server-side
  versioning or object-lock; append-only degrades to a client
  write-convention whose failure mode (buggy/compromised client deletes
  the only backup) is the scenario the backup exists for. Versioning
  turns that loss into a stale-but-present version.
- **S3.** Rejected per ADR-0014 §3 (Never: egress exposure) and §4 —
  commodity storage doesn't belong on the AWS identity/crypto spine, and
  versioning alone doesn't clear the platform gate.
- **No new vendor — skip off-machine backup.** Rejected: the store is a
  plain local directory on one machine; disk loss is total memory loss.
- **Master key as the tofu credential.** Rejected: all-capability,
  unscopeable, and unrotatable without breaking every consumer; a named
  key is revocable/re-mintable without touching the account root.

## Consequences

- #159 unblocks: the bucket lands as `b2_*` resources against this
  provider, inheriting the deferred wiring (the `read-ssm-params`
  outputs + four workflow lists + `B2_MANAGEMENT_* → B2_APPLICATION_*`
  env remap, `with-infra-secrets.sh` exports — enumerated in #189's plan
  thread) and first exercising live authentication.
- A fourth vendor account joins the periodic audit: MFA on, master key
  still unrecorded, management key still the only tofu credential, and
  the §6 decay checks (free-tier terms, provider health).
- Until #159 merges, the provider is pinned-but-idle and the SSM params
  are resident-but-unread — deliberate: the foundation is verifiable now
  (lockfile on both platforms, clean plan with the empty block) without
  wiring anything that has no consumer.
- **Revisit if** B2 repricing or the 10 GB tier flips (§6), the provider
  goes unmaintained (§2.6 — the exit is `rclone` + re-pointing the
  client), or R2 ships versioning + object-lock (would collapse the
  fourth vendor back onto the existing spine — weigh against §2.8's
  correlated-account risk before moving).
