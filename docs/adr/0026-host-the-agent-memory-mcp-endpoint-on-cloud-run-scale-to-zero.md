# 0026. Host the agent-memory MCP endpoint on Cloud Run scale-to-zero

Date: 2026-08-17

## Status

Accepted

## Context

dotfiles' ADR-0046 moves per-role agent memory from a machine-local JSONL
store to a hosted MCP-over-HTTP endpoint (TypeScript server, Neon Postgres
state, per-role bearer auth) so every surface — CLI, macOS app, claude.ai
web, iOS — reaches the same memory. That server (dotfiles#634's
`agent-memory-server` repo) needs a host, and the host decision is this
repo's to make: it lands in the ADR-0014 selection framework, and the
bootstrap identities it needs (a GCP runtime identity, an AWS runtime-tier
SSM role, a keyless deploy identity) live in `gcp/` and `iam/`.

Unlike ADR-0024's dispatch **Job** (fires, does one HTTP round trip,
exits), this is a persistent **Service**: a low-traffic HTTPS endpoint
that must answer whenever an agent session starts, from any network. Two
kill-switches from ADR-0046 constrain the choice: any meaningful recurring
bill, or p95 session-start retrieval above 2 s sustained a week, forces a
fall-back-to-JSONL decision. So the host must be free at this volume while
idle-most-of-the-time, and its cold path must have a fighting chance at
sub-2s.

Decided in #240 (plan-approved, one review round); the plan-review
derivation lives in that issue's comments.

## ADR-0014 §5 integration checklist

Answer each before deciding — a blank line here is a question skipped, not a
question with no answer.

1. **Class** (protocol / runtime / adapter / platform): **Runtime** — a
   Cloud Run Service consumes a plain OCI image, same as ADR-0024's Job
   (OCI in, `docker push` out). A container host, not a platform bet on
   GCP (§4's own carve-out); the app itself is portable TypeScript
   speaking MCP and Postgres.
2. **Deployment/data artifact** — is it standard?: Yes — an OCI image in
   Artifact Registry. No data lives in GCP: state is Neon Postgres
   (ADR-0023), secrets are AWS SSM (ADR-0010), the container is stateless.
3. **Exit path**, in one command or one paragraph: `docker push` the same
   image to Fly.io or any OCI PaaS, repoint the Cloudflare record, and
   re-pin the AWS trust policy at the new host's identity. Only the thin
   Cloud Run overlay in `gcp/` is GCP-specific (§3 rule 7).
4. **Egress exposure** to read all the data out once a month: None from
   GCP — no data at rest there. The Service's own traffic is small JSON
   (MCP tool calls); Cloud Run→Neon is the billable class, kept small by
   co-locating Neon's region near the GCP region (§2 rule 2).
5. **Self-hostable alternative** on existing Hetzner/homelab capacity at
   ~zero marginal cost?: No — no personal/cloud workload mixing rules out
   k3s for this (maintainer call, #240), and no always-on personal compute
   exists to piggyback on. Same posture as ADR-0024 checklist #5.
6. **Terraform provider** — official and maintained?: Yes —
   `hashicorp/google`, already adopted and pinned `~> 6.0` (ADR-0024).
7. **Vendor-death / suspension blast radius** — what breaks with 30 days'
   notice, or none? Name anything correlated (shared account with DNS,
   storage, hosting): A GCP suspension kills the memory endpoint and the
   ADR-0024 dispatch job — this GCP project holds only agent-operating-model
   workloads, nothing else. Memory degrades to the local JSONL fallback
   (ADR-0046's designed rollback); DNS/edge (Cloudflare), secrets (AWS),
   and state (Neon) are all elsewhere, so no correlated loss.
8. **Free-tier dependency** — paid price when the tier changes, and the
   trigger (rows, seats, requests) that flips it: Cloud Run's always-free
   tier (2M requests / 180k vCPU-s / 360k GiB-s / 1 GiB NA egress per
   month, verified live at #240) covers this volume by orders of
   magnitude **while scale-to-zero with request-scoped CPU**. Baseline
   non-zero cost: Artifact Registry image storage, ~a few cents/month —
   baseline, not an ADR-0046 kill-switch trip (dotfiles#645 refines that
   wording). The flip trigger is `min-instances` or always-allocated CPU,
   both of which this ADR forbids.
9. **Backup, not just exit** — is there a scheduled, restore-tested backup
   path, or only a migration tool run by hand?: N/A for GCP — stateless
   compute; the durable definition is `gcp/`'s Tofu. The data's backup
   story is Neon's, owned by ADR-0025 (pg_dump DR to B2).
10. **Vendor security posture** — SOC 2 / breach history / access controls
    for the data this service will hold: Google Cloud holds SOC 2 Type II /
    ISO 27001 (as recorded at ADR-0024). The container holds no persistent
    secret — it reads `/runtime/agent-memory/*` via OIDC federation at
    boot; the private memory content itself resides in Neon, whose posture
    ADR-0023 records.

## Decision

The agent-memory MCP endpoint runs as a **Cloud Run Service,
scale-to-zero, request-scoped CPU — no `min-instances`, ever, under this
ADR** — on the GCP project ADR-0024 adopted, reusing its
GCP-SA→OIDC→AWS-SSM federation. No new vendor.

**Scale-to-zero is load-bearing, not a tuning default.** Pinning
`min-instances=1` to fix a slow cold path would trade one ADR-0046
kill-switch (p95 > 2 s) for the other (a recurring bill) — the exact
signal that ADR says means fall back to JSONL. So the cold path is a
go/no-go, not a knob: dotfiles#636 measures a **cold** request end to end
(container boot → SA OIDC mint → `AssumeRoleWithWebIdentity` → SSM read →
KMS decrypt → Neon connect), since a low-traffic endpoint is cold most of
the time and that chain is what the 2 s gate actually gates. Cold p95
< 2 s → ship; above → ADR-0046's keep-or-migrate decision, out of this
ADR's scope. To keep the chain boot-shaped, the app caches its secrets
once at container boot, never per request.

**Boundary — infra bootstraps, the consumer owns the runtime** (the split
from #204/ADR-0023, not #191/ADR-0024: the memory server is a
distinct application with its own repo, not infra's own plumbing):

- **infra (`gcp/`):** the Artifact Registry DOCKER repo `agent-memory`;
  the runtime SA `cloud-run-agent-memory` the Service runs as; a deploy
  SA `agent-memory-deploy` plus a Workload Identity Federation
  pool/provider trusting the `agent-memory-server` GitHub repo, so its CI
  deploys keyless. The deploy trust rides the exact OIDC-subject mechanism
  #227 flags as inconsistent and silent-failing, so it fails loud instead:
  the subject claim is a required, regex-validated input (the ID-pinned
  `repo:owner@id/repo@id:ref` form, ADR-0010's #163 discipline), and the
  WIF provider carries an attribute condition — a malformed or empty
  subject refuses to plan rather than deploying nothing silently. The
  deploy SA gets `roles/run.developer` at **project** scope: resource-level
  would need the Service to pre-exist, which the consumer creates; the
  project holds only agent-operating-model workloads, so the blast radius
  is bounded. Plus `roles/artifactregistry.writer` on the one image repo
  and `roles/iam.serviceAccountUser` on the one runtime SA.
- **infra (`iam/`):** AWS role `agent-memory-ssm-read`, break-glass state
  per #230 (IAM never widens `infra-apply`). Trust = the runtime SA's
  numeric `unique_id` via `AssumeRoleWithWebIdentity` against the
  **native** `accounts.google.com` principal with the `:oaud` condition
  key — the shape ADR-0024's amendment verified live, not the generic
  OIDC-provider pattern. Policy = SSM read on `/runtime/agent-memory/*`
  plus `kms:Decrypt` on the runtime tier key. Mirrors `infra-dispatch-read`.
- **infra (`ssm.tf`, docs only):** the `/runtime/agent-memory/*` path
  convention is documented, never created here — the parameters
  (`connection-uri`, per-role bearers) are consumer-created, keeping
  infra's CI-applied state and `infra-apply` entirely out of the rotating
  tier (ADR-0010's role×path matrix, same as the vended token).
- **consumer (`agent-memory-server`, dotfiles#634):** the
  `google_cloud_run_v2_service` itself, the Neon project/role/
  `connection_uri`, and the `/runtime/agent-memory/*` values.

**Reachability:** public HTTPS, `allUsers`-invocable, the ADR-0046
per-role app-layer bearer as the only _data_ gate (that ADR's
structural→operational privacy downgrade — TLS and bearer handling are
load-bearing). _Invocation_ is a separate exposure the bearer doesn't
cover: an unauthenticated flood against the raw `*.run.app` URL spins
billable instances — a cost-DoS straight into the recurring-bill
kill-switch. So the Service sits behind the Cloudflare edge on a custom
domain (the §2 rule 8 spine; a stable hostname also keeps the cloud
sandboxes' egress allowlist from chasing a generated URL), with an edge
rate-limit, and its ingress locked so the raw URL isn't directly
invocable — only Cloudflare-fronted traffic reaches it. The DNS record
lands in `dns.tf` once the consumer's first deploy makes the Service
hostname exist (docs/BOOTSTRAP.md §18's ordering); the ingress lock is
enforced on the consumer's Service resource, verified at the §18
reachability check.

**Sequencing:** (1) this ADR; (2) `gcp/` + `iam/` bootstrap applies,
outputs published (SA emails, WIF provider name, AWS role ARN); (3) the
consumer builds/pushes the image and applies the Service + Neon +
parameters against those outputs; (4) reachability check from a cloud
surface, then dotfiles#636's cold-p95 go/no-go.

## Alternatives considered

- **k3s (the ADR-0014 §3 steady-compute default)** — rejected: no
  personal/cloud workload mixing (maintainer call), and no k3s exists yet;
  standing one up for a scale-to-zero-friendly endpoint inverts the cost
  argument.
- **Fly.io** — rejected: a new vendor plus a standing bill for the
  smallest always-on machine, versus zero on an already-adopted provider.
  Stays the named exit path (checklist #3), so not a one-way door.
- **AWS for compute (Lambda/Fargate)** — rejected: AWS is the
  identity/secrets spine, not a compute host (§4/§8; Lambda-style
  signatures are §3's explicit Never). Same reasoning that sent ADR-0024
  to Cloud Run.
- **`min-instances=1` as a latency escape hatch** — rejected in plan
  review: it silently overrides ADR-0046 by trading the latency
  kill-switch for the cost one. Scale-to-zero only; the cold path is a
  measured go/no-go.
- **The Service in infra's `gcp/` state (the #191 shape)** — rejected: the
  server is a distinct application; infra custody of a runtime workload is
  the ADR-0010 role×path catch the #204 split exists to avoid.

## Consequences

- `agent-memory-server`'s CI deploys keyless via WIF; a broken or
  reshaped OIDC subject fails at plan/deploy time, loud (#227's lesson),
  and the emitted `sub` gets verified at first apply.
- `iam/`'s audit surface grows one role: `agent-memory-ssm-read` joins
  ADR-0010's fence (a) set — runtime tier only, one path, never
  `alias/infra-secrets`. AGENTS.md's identity table carries it.
- The GCP project now holds a second workload class (a persistent
  Service beside the dispatch Job) — still only agent-operating-model
  workloads, which is what bounds the deploy SA's project-scope grant.
  Revisit that grant if anything else ever lands in this project.
- The memory endpoint's availability is Cloud Run's cold-start behavior;
  if dotfiles#636's cold p95 exceeds 2 s, the decision escalates to
  ADR-0046's keep-or-migrate — nothing here pre-commits the answer, and
  `min-instances` is not an available move under this ADR.
- Cloudflare-fronting adds the §18 post-deploy step (DNS record, rate
  limit, ingress verification) to the bootstrap runbook — a manual seam
  between infra's apply and the consumer's, priced in by the split.

Refs: #240, #227, #230, #204, ADR-0010, ADR-0014, ADR-0023, ADR-0024,
ADR-0025, dotfiles ADR-0046, dotfiles#634, dotfiles#636, dotfiles#645.
