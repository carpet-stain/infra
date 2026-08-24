# 0031. Worker-minted ID token fronts the IAM-gated agent-memory Cloud Run Service

Date: 2026-08-23

## Status

Accepted

Supersedes **ADR-0026's Reachability clause** (the `allUsers` + edge-fronting
design) and **ADR-0028:121's categorical** "GCP service accounts | keyless —
WIF-federated" row. Both ADRs keep their original prose plus a dated
`Amended:` note pointing here — the rejected paths stay visible
(`docs/adr/README.md`'s superseding convention).

Gate sequencing corrected — #323 (2026-08-24): the ingress flip moves from
Phase 5 into the Gate, a prerequisite for checkpoints 2/3, not a step
gated behind them. See the Amendment section at the end.

## Context

The agent-memory Cloud Run Service (ADR-0026) is `Ready` but unreachable:
ingress is `internal-and-cloud-load-balancing` and its IAM policy is empty —
verified live, #323. ADR-0026's Reachability clause named `allUsers` +
app-layer-bearer-as-the-only-gate as the design; it was never built, and the
built state (nothing can reach the Service, for free) is better than the
ADR's. This ADR records the fronting mechanism ADR-0026 left unnamed.

Three fronting options and why they're rejected, derivation in #323:

- **External HTTPS LB + serverless NEG.** A global forwarding rule bills a
  standing ~$18–25/month regardless of traffic — the same recurring-bill
  kill-switch (ADR-0046, ADR-0026 §8) the ingress lock exists to protect,
  tripped unconditionally. Also cuts against ADR-0027 (detective over
  preventive): infra#276's billing budget catches the same event for free.
- **Ingress `all` + app-layer bearer as the only gate.** Requires _adding_
  an `allUsers` binding that doesn't exist today, making the Service
  publicly invocable for the first time. Its safety rested on the
  `run.app` hostname being unpublished; it's published
  (agent-memory-server#36 prints it into a public repo's Actions log).
  Obscurity as a control was already broken once, silently.
- **Cloud Armor.** Attaches only to a load balancer — the same purchase.

## Decision

Keep the Service IAM-gated (as it already is), flip ingress to `all`, and
put a **Cloudflare Worker** in front that mints a Google ID token and
forwards it. Unauthenticated traffic is rejected by Google's front end for
free (no container start, no billable request), so hostname publicity stops
mattering — the property the LB would have bought, obtained structurally at
$0.

**The header mechanism this depends on:** Cloud Run consumes
`X-Serverless-Authorization` for its IAM check and passes `Authorization`
through to the container untouched — `src/auth.ts`'s ADR-0046 per-role
bearer rides that header unchanged, server and every client untouched. #323
names this the plan's load-bearing gate; if it doesn't hold, this design is
re-planned, not patched.

**Boundary, extending ADR-0026's infra/consumer split:**

- **infra (`gcp/`):** `agent_memory_edge_invoker` SA and its
  `run.invoker` binding on the consumer's Service — scoped to that one
  Service, mirroring `scheduler_invoker` (ADR-0024). The binding lives in
  `gcp/`, not the consumer: `agent_memory_deploy`'s project-scoped
  `run.developer` role carries `run.services.getIamPolicy` but not
  `run.services.setIamPolicy` (verified against the role definition), and
  `gcp/` applies locally under ADC (`roles/owner`), which has it — already
  the documented runbook (BOOTSTRAP.md §19's `allUsers`-stays-out-of-band
  note, now superseded by this ADR's shape). The Service name/location are
  regex-validated `TF_VAR`s (`gcp/variables.tf`), never literals — the
  binding targets a Service this module doesn't manage, so a wrong or
  empty value must refuse to **plan**, not 404 at **apply** (#227).
- **infra (`workers/agent-memory-edge/`, `workers.tf`):** the Worker's
  code and its `cloudflare_workers_script` deployment. Lives in infra's
  root module, which already owns `cloudflare.tf`/`dns.tf`, rather than in
  `agent-memory-server` — the edge belongs with the rest of the Cloudflare
  surface, not the application it fronts.
- **Out-of-band (never in Tofu state):** the edge invoker's SA key. infra
  is a public repo whose root module is CI-applied via saved plan
  artifacts — in-state custody would route a live GCP private key through
  public-repo CI. Created by hand, hand-populated into the Worker's
  `GCP_SA_KEY_JSON` secret binding with `ignore_changes` — the `/cicd`
  PLACEHOLDER precedent (`ssm.tf`, `iam/main.tf`), not a new pattern.
- **Consumer (`agent-memory-server`):** flips `ingress` to
  `INGRESS_TRAFFIC_ALL` and fixes the two comments asserting the LB lock
  (`cloud_run.tf:20-21`, `outputs.tf:2`) — #323's Phase 5, sequenced after
  the Worker is live so the Service doesn't sit reachable-and-rejecting-
  everything, which looks identical to a broken deploy.

**Gate, in order, before Phase 5 opens the door** (#323's full text):

1. Cloud Run header handling — the mechanism above, live-verified.
2. A real Worker `fetch()` carrying both headers against a real MCP call —
   Cloudflare mustn't normalize/strip the custom header, and MCP-over-HTTP
   streaming must survive the hop.
3. The deny path: flood `run.app` with (a) no `Authorization` and (b) a
   valid bearer but no ID token. Both must 403 with instance-count and
   billable-request metrics flat — rejection at Google's front end, not
   after a cold start.

None of the three has run as of this ADR — the Terraform and Worker code
here are unverified against a live origin.

## Alternatives considered

- **External HTTPS LB + serverless NEG + Origin CA cert** — rejected, see
  Context: a standing ~$18–25/month regardless of traffic, against
  ADR-0026 §8's zero-baseline premise and the maintainer's declined cost.
- **Ingress `all` + app-layer bearer as the only gate** — rejected: adds a
  first-ever `allUsers` binding, resting safety on an already-published
  hostname (agent-memory-server#36).
- **Cloud Armor** — rejected: only attaches to a load balancer, the same
  purchase as the first alternative.
- **fail2ban-style reactive banning** — rejected: no host, no packet
  filter, and the cost lands before the log line you'd ban on.
- **A `google_service_account_key` resource in `gcp/`** — rejected: puts
  private key material in `gcp/terraform.tfstate`; the out-of-band +
  Worker-secret path (Decision, above) keeps it out of Tofu state
  entirely, matching the residency call this ADR also amends ADR-0016 for.

## Consequences

- **ADR-0026 amended, not reversed** — its Reachability clause is
  superseded here; its scale-to-zero decision, infra/consumer boundary,
  and every other section stand.
- **ADR-0028:121 amended** — GCP service accounts are no longer
  categorically keyless. `agent_memory_edge_invoker` is the first keyed
  exception; its key has no automated rotation (no expiry to detect,
  unlike the PAT classes ADR-0028 maps) — rotation is a manual trigger,
  owned by whoever holds Cloudflare Workers Scripts Edit access.
- **ADR-0016 amended** — a fourth machine sub-tier: Worker-scoped,
  out-of-band-provisioned, consumer-fetched-at-runtime, mirroring the
  `/cicd` shape's reasoning but landing in Cloudflare Workers Secrets
  instead of SSM, because the value must never transit this repo's
  CI-applied state.
- **Leak → cost-DoS path:** the invoker key _is_ the cost-DoS key. A
  holder passes the IAM gate and spins instances that only reject once
  warm. `gcp/`'s `google_cloud_run_v2_service_iam_member` scopes the key
  to `run.invoker` on this one Service; the consumer's
  `max_instance_count` (not this ADR's scope) bounds the burn, it doesn't
  neutralize it.
- **BOOTSTRAP.md §18/§19 rewritten** to the new topology — the ingress-lock
  bullet (§18) and the `allUsers`-stays-out-of-band bullet (§19) both
  asserted the design this ADR replaces; a new §20 documents the edge
  invoker, out-of-band key, and Worker bootstrap steps.
- **Cloudflare Workers' free tier** joins Cloud Run's as a second
  free-tier dependency this design leans on (ADR-0026 §8's flip-trigger
  enumeration gains a third route: a load balancer, alongside
  `min-instances` and always-allocated CPU — corrected in place, additive,
  not a reversal).
- **Revisit if** checkpoint 1 (the header-passthrough gate) fails live —
  the role bearer moves to a custom header, a coordinated
  `src/auth.ts` + all-clients change, and this ADR is superseded rather
  than amended.

Refs: #323, #250, #227, #276, ADR-0016, ADR-0024, ADR-0026, ADR-0027,
ADR-0028, ADR-0046 (dotfiles), agent-memory-server#36, dotfiles#634,
dotfiles#636.

## Amendment — #323 (2026-08-24): the ingress flip is a Gate prerequisite, not Phase 5

Live-testing checkpoint 2 surfaced a circular dependency the 3 original
plan-review rounds missed: Cloud Run's `ingress` is a **network-layer**
gate, evaluated by Google's front end before the IAM/bearer check ever
runs. While `ingress` stays `internal-and-cloud-load-balancing`, a
request from outside GCP — even one carrying a perfectly valid
`X-Serverless-Authorization` token — is rejected at the network layer
(404, not 403, Google's documented behavior for ingress-blocked requests,
chosen to avoid confirming the Service's existence to a disallowed
network path). Checkpoints 2 and 3 both need external reachability to
test at all, but the Decision's Consumer boundary bullet sequenced the
ingress flip in Phase 5, gated _behind_ those same checkpoints —
circular. Derivation: `carpet-stain/infra#323`'s comment thread.

**Corrected order:**

1. Checkpoint 1 (header passthrough) — test from a GCP-internal context
   (Cloud Shell, a scratch Compute Engine VM, or Cloud Build — anything
   satisfying today's ingress restriction) with a real
   `gcloud auth print-identity-token` bearer. Doesn't need ingress open.
2. Flip `ingress` to `INGRESS_TRAFFIC_ALL` — moved out of Phase 5, into
   the Gate. Not the risky step it looked like bundled with Phase 5: the
   Service's IAM policy stays empty, so `ingress: all` + no ID token
   still 403s at Google's front end for free — exactly checkpoint 3's
   success condition. The actually-visible/risky step is #250's DNS
   cutover, downstream of this Gate entirely, not the flip.
3. Checkpoint 2 (the Worker's real forwarding, from outside GCP) — only
   testable now that ingress is open.
4. Checkpoint 3 (the deny-path flood) — same; this is the design's actual
   proof, run once the network door is open, not before.

Phase 5 shrinks to the two LB-lock comment fixes (`cloud_run.tf:20-21`,
`outputs.tf:2`) plus `agent-memory-server#36` — the ingress flip already
happened above, at step 2.
