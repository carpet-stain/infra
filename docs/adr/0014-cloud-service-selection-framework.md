# 0014. Cloud service-selection framework

Date: 2026-08-13

## Status

Accepted

Amended: 2026-08-20 — added §5 Q11, the adoption-time spend-alert /
safety-control checklist question (#275).

## Context

Provider and service choices across the personal-project stack have been made
case-by-case, and each one re-argues the same question: how much does this lock
me in, and is it worth it. Without a written rule the criteria drift, and every
per-service ADR re-derives first principles instead of applying a shared one.

The governing insight: **lock-in is not binary — it's the cost of the exit
migration.** A service is only as cheap as it is to leave. Price every service
as:

```text
true_cost = monthly_cost + (exit_cost / expected_lifetime_months) + egress_exposure
```

This is a mental model, not a computation — `exit_cost` and `expected_lifetime`
aren't knowable numbers at adoption time. Its job is to make the two terms
prose forgets (exit cost, egress) sit next to the one term it never forgets
(monthly cost); §5 Q3/Q4 ask them directly rather than asking for a number.

The framework below buys the most commoditized abstraction that satisfies each
requirement — rent operations, own the artifact — and makes the exit path a
precondition of adoption rather than an afterthought.

## Decision

Adopt a class-based service-selection framework. This is a **standing policy**,
not a one-shot decision: per-service choices answer its checklist (§5) and cite
this ADR (`per ADR-0014 §3`) instead of re-deriving the reasoning. A later
per-service ADR supersedes only its own decision, never this framework.

### 1. Classification — what the platform consumes

| Class        | Platform consumes                                            | Lock-in   | Policy                                      |
| ------------ | ------------------------------------------------------------ | --------- | ------------------------------------------- |
| **Protocol** | An open standard (SQL/PG wire, S3 API, SMTP, OTLP, OCI, K8s) | Near zero | Buy freely on price/DX                      |
| **Runtime**  | A standard artifact (container, static files, manifests)     | Low       | Buy freely; keep the config layer thin      |
| **Adapter**  | Your code via a proprietary SDK / trigger model              | Medium    | Wrap behind an interface; document the exit |
| **Platform** | Your application or data model directly                      | High      | Requires explicit justification (§4)        |

### 2. Decision rules

1. **State first.** Data gravity is the real lock-in; compute moves in a
   redeploy. Every stateful service needs a named exit path (`pg_dump`,
   `rclone`, file copy) before adoption.
2. **Egress is the price.** Cheap to run but expensive to leave or read from is
   not cheap. Zero/low-egress providers (R2, B2, Hetzner) are structurally
   preferred for data at rest.
3. **The artifact test.** If the deployment input is an OCI image or static
   files, the platform is a commodity. If it's source + buildpacks + platform
   add-ons, it's a landlord.
4. **Templates, schemas, config live in git** — never in a vendor UI (email
   templates, dashboards, alert rules → code).
5. **Instrument to standards.** OpenTelemetry for signals, Prometheus
   exposition for metrics. Exporters point anywhere; instrumentation is written
   once.
6. **Terraform provider quality is a vendor signal, scoped to providers that
   plausibly warrant first-party support.** Stale coverage on a mainstream
   platform is a yellow flag. It doesn't penalize the indie services this
   framework already defaults to (Neon, Healthchecks.io, ntfy, Umami) for
   having community-only providers — that's the expected shape of a small
   vendor, not lock-in friction.
7. **Thin cloud-specific layer.** Cloud-coupled bits (ingress annotations,
   storage classes, IAM bindings, WIF) isolated in per-environment overlays;
   workloads stay pure.
8. **Spine and stateless satellites.** DNS/edge on Cloudflare;
   identity/secrets on AWS (IAM + GitHub OIDC roles, SSM/KMS — ADR-0010/0013).
   Stateless satellites are replaceable via an env var or a DNS change; stateful
   ones exit via their named data-export path (rule 2.1), not an env swap.
   Co-locating state (R2) on the Cloudflare DNS/edge spine is a priced risk, not
   free convenience — one account suspension takes DNS, edge, Pages, and R2 at
   once (§5 Q7).
9. **Cost and free-tier terms are live signals, not adoption-time facts.** At
   personal scale much of the stack rides free or near-free tiers (Neon,
   Healthchecks.io, PostHog); the most likely failure isn't a vendor dying, it's
   a tier changing under you — a price floor, a row/seat cap, a feature moving
   behind a paid plan. §5 Q8 asks the cost question once at adoption; this rule
   makes it recurring (§6): the answer decays, so it gets re-checked, not
   trusted.

### 3. Category playbook

| Category                   | Default                                                             | Alternate                       | Never                                              | Exit path                          |
| -------------------------- | ------------------------------------------------------------------- | ------------------------------- | -------------------------------------------------- | ---------------------------------- |
| Compute (steady)           | Hetzner (k3s)                                                       | Any VPS                         | Hyperscaler VMs at list price                      | Redeploy manifests                 |
| Compute (batch/serverless) | Cloud Run Jobs                                                      | Fly.io, any OCI PaaS            | Lambda-style signatures, Beanstalk                 | `docker push`                      |
| Kubernetes                 | k3s self-managed                                                    | GKE (if paying for ops)         | EKS/AKS at personal scale                          | Flux repo re-point                 |
| Relational DB              | Neon                                                                | Supabase (PG only), self-host   | Aurora / proprietary extensions                    | `pg_dump`                          |
| Object storage             | Cloudflare R2                                                       | Backblaze B2                    | S3 with egress exposure                            | `rclone`                           |
| Queues/jobs                | Postgres, pinned always-on Neon branch (SKIP LOCKED / pgmq / River) | NATS self-hosted, Redis Streams | SQS/SNS/EventBridge, Pub/Sub                       | Table export / redeploy            |
| Email (transactional)      | SES or Resend, templates in repo                                    | Postmark                        | Vendor template builders                           | Swap API key                       |
| Web analytics              | Umami Cloud                                                         | Self-hosted Umami/Plausible     | GA4                                                | Self-host re-point (same OSS tool) |
| Product analytics          | PostHog (OSS exit path)                                             | Self-hosted PostHog             | Proprietary-only vendors                           | Documented self-host               |
| Warehouse/OLAP             | DuckDB over Parquet in R2                                           | ClickHouse self-hosted          | BigQuery below ~10 TB                              | Files you own                      |
| Frontend hosting           | Cloudflare Pages (Astro/static)                                     | Netlify, GH Pages               | Vercel + Next server features                      | DNS change                         |
| IAM / CI identity          | AWS IAM + GitHub OIDC roles (ADR-0010)                              | —                               | Long-lived static keys                             | N/A (spine)                        |
| Secrets/KMS                | AWS SSM Parameter Store + KMS (ADR-0010/0013)                       | —                               | In-repo SOPS; vendor secret UIs as source of truth | Export params / re-key             |
| Observability              | OTel → Grafana/Loki/Tempo/Prometheus                                | Grafana Cloud, Honeycomb        | CloudWatch as primary                              | Re-point exporter                  |
| Alerting                   | Alertmanager + ntfy/Pushover; Healthchecks.io                       | Grafana alerting                | CloudWatch Alarms                                  | Config in git                      |

The Warehouse/OLAP "Never" line is an absolute, not a threshold — personal
scale doesn't approach 10 TB, so it can't fire the Consequences "revisit"
trigger. DuckDB over Parquet isn't a managed-warehouse substitute; it's a file
convention (query engine over files you already own), chosen because no
volume at this scale justifies renting a warehouse.

Queues/jobs stays on Postgres, but not the same scale-to-zero Neon branch the
Relational DB default uses: polling / `SKIP LOCKED` needs a long-lived
connection, which fights suspend-on-idle. The fix is a Neon setting, not a
different service — pin the queue table's branch to always-on (a small fixed
cost) and keep the single-vendor, `pg_dump`-exits-everything simplicity
(#185, N3).

Web analytics moved from self-hosted to Umami Cloud. Rule 2.5 already treats
hosting as reversible (exporters/instrumentation point anywhere), so
self-hosting it bought little lock-in reduction for real ops load — one more
service to patch and back up on a maintainer already running k3s, the LGTM
stack, and PostHog. Product analytics was already hosted-by-default
(PostHog Cloud, self-host only as the Alternate); this brings web analytics
in line rather than adding a second self-hosted analytics service. The OTel/
Grafana/Loki/Tempo/Prometheus stack stays self-hosted — it's the observability
spine every other service's exporters point at, not a swappable satellite
(#185, N4).

### 4. When a Platform-class (proprietary) service is allowed

All three must hold:

- [ ] No credible OSS equivalent (Spanner-class consistency, TPUs, HSM-backed
      KMS, hyperscaler IAM/WIF), **or** operational savings are enormous and
      measured against a stated baseline (the self-hosted or OSS alternative
      actually priced, not assumed) — named in the adopting ADR, not waved
      through.
- [ ] Blast radius is contained: consumed behind a thin interface, state
      exportable.
- [ ] Exit is written down: a paragraph in the adopting ADR naming the
      replacement and the migration steps.

Hyperscalers earn their premium on **identity, cryptography, unique-physics
services, and compliance** — not on compute, storage, queues, observability, or
alerting. Cloud Run Jobs and GKE in §3 aren't a contradiction: they're
Runtime-class commodities (OCI in, `docker push` out), bought on DX like any
container host, not a platform bet on GCP.

### 5. New-integration checklist

Answer in the adopting ADR before taking on any new service:

1. What class is it (protocol / runtime / adapter / platform)?
2. What is the deployment/data artifact — is it standard?
3. What is the exit path, in one command or one paragraph?
4. What is the egress exposure to read all my data out once a month?
5. Does it replace something self-hostable on existing Hetzner/homelab capacity
   at ~zero marginal cost?
6. Terraform provider: official and maintained?
7. What breaks if this vendor dies with 30 days' notice — or suspends the
   account with none? Name the correlated blast radius when DNS, storage, and
   hosting share one provider account.
8. Free-tier dependency: what's the paid price when the tier changes, and what's
   the trigger (rows, seats, requests) that flips it?
9. Backup, not just exit: is there a scheduled, restore-tested backup path — an
   exit path (`pg_dump`) is a migration tool, not a backup, unless it's
   actually run on a schedule and the restore is verified?
10. Vendor security posture: what does the vendor say about its own security
    (SOC 2 / breach history / access controls) for the data this service will
    hold?
11. What spend alerts and account-level safety controls does this vendor
    support, and which land at adoption (per ADR-0027's stance)? (§6 covers
    the ongoing spend-alert posture.)

### 6. Ongoing review — the decay check

The checklist is answered at adoption, but two answers decay and get re-checked,
not trusted (rule 2.9). **The manual audit is the primary path** — it covers
every service regardless of what the vendor exposes:

- **Free-tier / price terms (Q8).** Re-confirm the tier a service still sits in
  and its flip trigger on a periodic cadence, tied to the existing infra audit
  rather than a new ceremony. A tier change is a migration trigger, not a
  surprise bill.
- **Terraform provider health (Q6).** A provider going stale or community-only
  moves a service toward operational lock-in — worth catching before the exit is
  needed, not during it.

Automated billing/usage alerts on the Alertmanager/ntfy spine are a bonus, not
the mechanism: most of the free tiers this framework rides (Neon,
Healthchecks.io, PostHog) expose no usage API to alert on. Wire an alert only
where the vendor actually has one; don't let its absence read as coverage the
manual audit doesn't need to do.

### 7. Reference stack

What the defaults above compose to — split by what's deployed today versus the
target application stack. Most personal projects aren't built yet, so don't read
the target line as current.

**Deployed today (this repo's governance surface):** AWS (IAM/OIDC, KMS, SSM
secrets — ADR-0010/0013) · Cloudflare (DNS/edge, R2) · GitHub (Actions CI).

**Target application stack:** Hetzner (k3s compute) · Neon (PG and queues) · R2
(objects) · Cloudflare (DNS/edge/Pages) · Cloud Run Jobs (batch) · SES/Resend
(mail) · OTel/Grafana stack (signals) · Healthchecks.io (batch liveness) ·
DuckDB/Parquet (analytics).

Every exit is named per service in §3 — a data export, a file copy, a DNS
change, or an env var.

## Alternatives considered

- **Hyperscaler-default (AWS/GCP for everything).** Rejected: pays the premium
  on exactly the commodity tiers (compute, storage, queues, observability) where
  hyperscalers add no durable value, and buys egress + IAM lock-in with it. The
  premium is only earned on identity/crypto/unique-physics (§4), so the stack
  uses a hyperscaler (AWS — IAM/OIDC, KMS, SSM per ADR-0010/0013) _only_ there.
- **Self-host everything on Hetzner.** Rejected: gives up the one place a
  hyperscaler genuinely wins — WIF/KMS/managed identity — and loads ops burden
  onto crypto and identity, the worst things to hand-roll. The framework keeps
  the spine bought and the satellites self-hosted.
- **Managed-PaaS-default (Vercel / Supabase-as-platform / Heroku-style).**
  Rejected by the artifact test (rule 2.3): source-plus-buildpacks deployment is
  a landlord relationship, and platform add-ons are Platform-class lock-in
  without the §4 justification.
- **No framework — decide per service, ad hoc.** Rejected: re-litigates lock-in
  every time and lets criteria drift. The §5 checklist plus this ADR are the
  forcing function that a standing rule provides and scattered judgment doesn't.

## Consequences

- Every new service arrives with a named class and a written exit path; per-
  service ADRs cite this framework (`per ADR-0014 §3`) instead of re-deriving
  it. This ADR governs the existing provider decisions already on the backlog:
  R2 as object-storage default (#159), the secrets-residency tree (#170, which
  cites §3 secrets / §4 rather than re-deriving), and the AWS identity/crypto
  spine behind the credential work (#155, #165).
- §3's IAM and secrets defaults **restate ADR-0010/0013's AWS SSM/IAM/KMS spine,
  they do not re-decide it** — this ADR does not supersede 0010, and its earlier
  rejection of in-repo SOPS stands. If a future project genuinely needs GCP
  (WIF, Cloud Run), that's a per-service ADR clearing the §4 gate, not a silent
  default here.
- Adopting a Platform-class service now costs a §4 justification — deliberate
  friction on the highest-lock-in tier, not a blanket ban.
- Free-tier drift is a monitored signal, not a quarterly surprise (§6). The
  cost: a recurring review item on the infra audit cadence, and a billing/usage
  alert wired up wherever a vendor actually exposes one to alert on.
- **Revisit if** personal scale crosses the thresholds baked into the playbook
  (k3s vs. managed Kubernetes) — the BigQuery-below-10-TB line is deliberately
  not one of these; it's a floor personal scale doesn't approach, not a
  threshold to watch — or if a free-tier change forces a paid migration the
  framework's own §6 check should have caught first. §5 is a forcing function
  only while it's actually run — `scripts/new-adr.sh` now stamps an
  integration ADR with the checklist as fields to answer, not prose to skip.
- §3's two playbook-default changes flagged for a reviewed decision
  (#185, N3/N4) are both resolved: Queues/jobs keeps Postgres/Neon but pins
  the queue branch always-on instead of switching services; Web analytics
  moves to Umami Cloud, leaving self-hosted ops load on the LGTM signal spine
  only, not two analytics services on top of it.
