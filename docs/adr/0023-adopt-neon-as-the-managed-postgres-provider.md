# 0023. Adopt Neon as the managed Postgres provider

Date: 2026-08-17

## Status

Accepted

Superseded by [0029. Adopt a Neon organization with project-scoped keys for
consumer isolation](0029-adopt-a-neon-organization-with-project-scoped-keys-for-consumer-isolation.md)
in status only — the provider pin, bootstrap-only scope, and management-key
residency below carry forward unchanged. What changes: the Decision
section's "project/role/`connection_uri`... consumer concern, created in
the consumer's own state, never this one" no longer holds for
`neon_project` — project lifecycle is an org-admin-key operation living in
infra's own state under `0029`. Role/database/`connection_uri` stay the
consumer's, as originally decided here.

## Context

carpet-stain/dotfiles ADR-0046 (hosted per-role agent memory over
MCP-over-HTTP) makes **Neon Postgres** the hosted store every agent-memory
surface connects to. Neon isn't yet a managed provider here — no provider
block, account, or credential in SSM. The dotfiles memory-endpoint epic
(dotfiles#602) is **blocked** on Neon being provisioned as code, the same
way the agent-memory backup work waited on the B2 bootstrap (#189,
ADR-0017).

Relational DB is already ADR-0014 §3's named default (`Neon`, exit path
`pg_dump`) — this ADR is that default's first live adoption, not a fresh
vendor pick, so it answers §5's checklist against a decision the framework
already made rather than re-arguing it.

## ADR-0014 §5 integration checklist

1. **Class:** Protocol — standard PG wire protocol, `pg_dump`/any PG client
   reads it all back. The _management_ plane (tofu provider, account/branch
   APIs) speaks Neon's native API, not PG wire — same carve-out ADR-0017
   drew for B2: management state is this repo's HCL, re-creatable anywhere.
2. **Deployment/data artifact — standard?:** Not yet applicable at bootstrap
   scope — no project/database/role exists here (see Decision). Once #602
   creates one, the artifact is a standard PG database, standard.
3. **Exit path:** `pg_dump`, per §3's own playbook row (Neon is §3's named
   relational default; the row already commits to this exit).
4. **Egress exposure:** Nil at this stage — bootstrap creates no data plane,
   only a management credential.
5. **Self-hostable alternative?:** Self-hosting PG on existing
   Hetzner/homelab capacity is the notional alternative, but §3 already
   defaults relational DB to Neon over self-host — this ADR doesn't
   re-litigate that call, only executes it.
6. **Terraform provider — official and maintained?:** **No** —
   `kislerdm/neon` is the only viable provider (verified: no official
   `neondatabase` provider exists), community tier, ~793k downloads,
   v0.15.0. This trips rule 6's yellow flag (community-only TF on a
   mainstream-adjacent platform); accepted explicitly (well-maintained,
   high adoption — the alternative is clickops outside tofu entirely) and
   carried forward as a live §6 decay-watch item, not a one-time waiver.
   Pin **`~> 0.15.0`** — conservative, since pre-1.0 minor bumps can break.
7. **Vendor-death/suspension blast radius:** Nothing yet — bootstrap holds
   no project/data. Once #602 provisions a project, Neon becomes a fifth
   vendor account (after GitHub, Cloudflare, AWS, B2), reducing correlated
   blast radius versus co-locating on an existing spine account (§2.8).
8. **Free-tier dependency:** Neon's free tier is the framework's own
   assumption for personal-scale relational DB (§3's Reference stack); the
   flip trigger (storage/compute-hours cap, or Neon repricing) is a §6 decay
   item, re-checked on the periodic audit alongside B2's tier, not trusted
   at adoption time.
9. **Backup, not just exit:** Deferred to #602 — no data exists yet to back
   up. `pg_dump` is a migration tool, not a backup, until #602 names a
   scheduled, restore-tested path for whatever it provisions.
10. **Vendor security posture:** Deferred to #602's project/role scoping —
    bootstrap holds only an account-level management key, no data-plane
    access pattern to assess yet.

## Decision

**Adopt Neon as a managed OpenTofu provider, bootstrap only** — mirroring
the B2 bootstrap shape #189/ADR-0017 set: a lazy empty provider block and a
management credential in SSM, no project/database/role and no runtime
connection credential.

**Provider = `kislerdm/neon`**, pinned `~> 0.15.0` (`versions.tf`). Its
`api_key` argument is _Optional_, defaulting to the `NEON_API_KEY` env var
(verified against the provider's own `index.md`), so an empty
`provider "neon" {}` plans clean with zero resources — the same lazy-auth
shape as the `b2` and `cloudflare` blocks it sits beside. The community-only
provider flag (checklist item 6) stays live via the §6 decay watch: checked
on the periodic audit alongside B2's, with `pg_dump` as the named fallback
exit if the provider itself goes unmaintained before Neon does — the escape
hatch doesn't depend on the provider at all.

**Scope = provider + management credential only.** No Neon **project or
role** here, same deferral #189 drew for the B2 bucket (left to #159/#200).
The account and its API key are created out-of-band
(`docs/BOOTSTRAP.md` §15); `apply` only touches the SSM parameter and its
adoption `import{}`.

**The `/runtime` boundary, extended to Neon.** `ssm.tf`'s standing "no
`/runtime/*` on purpose" rule (ADR-0010's role×path matrix) keeps this
CI-applied state — and the `infra-apply` role — out of the rotating tier.
That rule now explicitly covers Neon too: the management key lives in
`/infra`; any **project/role/`connection_uri`** the provider emits once a
project exists (a sensitive attribute, same trap ADR-0002 names for the
GitHub provider) is a **consumer concern, created in the consumer's own
state, never this one** — otherwise `infra-apply` becomes custodian of a
runtime connection credential it has no business holding. Stating this now,
before dotfiles#602 exists, is load-bearing: deferring the project without
naming this constraint would let that state silently erode the invariant
the first time it needs a credential.

**Credential residency** — by citation, not re-derivation: the management
API key is fetched by automation, long-lived and high-value, so ADR-0016's
tree lands it in SSM `/infra/neon-api-key`, `SecureString` under
`alias/infra-secrets`, a `local.infra_parameters` entry
(`ignore_changes = [value]`) plus a temporary `import{}` adoption block for
the hand-created parameter (`ssm.tf`) — #189's exact pattern, same
crown-jewel tier as `b2-management-key`.

**This ADR is 0023**, not the next sequentially-generated number — 0022 is
a reserved-but-unwritten forward reference in `versions.tf` for a future
state-encryption decision; this ADR doesn't collide with it. It does
**not** supersede ADR-0018 — the B2-vs-Neon durability/DR question for
agent-memory storage belongs to #602's own DR decision, out of scope here.

## Alternatives considered

- **Self-host Postgres on Hetzner.** Rejected per §3's existing default and
  rule 5 above — hosted removes the ops burden a self-hosted PG install adds
  (backups, patching, HA), and the framework already priced that trade-off
  for the relational-DB category before this ADR existed.
- **Wait for an official `neondatabase` Terraform provider.** Rejected —
  none exists today, and the community provider's adoption/maintenance
  signal (~793k downloads, active v0.15.0) clears rule 6's bar for
  acceptance rather than avoidance; waiting indefinitely blocks dotfiles#602
  for no named date.
- **Clickops the Neon account, skip tofu entirely.** Rejected — every other
  vendor credential in this stack is SSM-resident and tofu-tracked
  (ADR-0010); a hand-run exception here breaks the audit surface the
  periodic review already covers, for no benefit over a lazy empty
  provider block.
- **Provision the project/database now, alongside the provider.** Rejected
  — #602 hasn't landed yet to consume it, and a project created here would
  either sit unused in this state or force this state to hold a
  `connection_uri`-shaped sensitive attribute, exactly the boundary this
  ADR draws against. Bootstrap-only mirrors #189's B2 precedent.

## Consequences

- Unblocks dotfiles#602: the memory endpoint can point the `neon` provider
  (and its own `/runtime/*` connection credential, created in its own
  state) at a provisioned account.
- A fifth vendor account joins the periodic audit: MFA on, the management
  key still the only tofu credential, and the §6 decay checks (free-tier
  terms, provider health).
- Until #602 lands, the provider is pinned-but-idle and the SSM parameter
  is resident-but-unread — the foundation is verifiable now (clean plan
  with the empty block) without wiring a consumer that doesn't exist yet.
- **Revisit if** the `kislerdm/neon` provider goes unmaintained (checklist
  item 6 — exit is `pg_dump` plus re-pointing whatever consumes it, not
  dependent on the provider), Neon's free tier or pricing flips (item 8),
  or an official `neondatabase` provider ships (would warrant re-evaluating
  the pin, not the vendor choice itself).
