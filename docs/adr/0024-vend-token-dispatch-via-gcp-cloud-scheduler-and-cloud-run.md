# 0024. Vend-token dispatch via GCP Cloud Scheduler and Cloud Run

Date: 2026-08-17

## Status

Accepted

Trust-policy mechanics corrected in place — see the Amendment at the end.

## Context

`vend-token.yml` publishes the rotating GitHub App token consumed by local
and agent shells (`/runtime/vended-token`, ADR-0010). It's triggered by
`schedule: */5 * * * *` plus manual `workflow_dispatch`. GitHub's `schedule:`
trigger is best-effort on a public repo: runs land ~hourly instead of every
5 min, and one gap ran 2.5h. `create-github-app-token` mints tokens hard-
capped at a 1h TTL. A trigger that lags longer than the token it produces
lives means a recurring dead window — every consumer 401s until someone
runs `just revend` (dotfiles#619, the interim, not a fix) or waits for the
next lucky `schedule:` tick.

`workflow_dispatch` runs start in ~2s with no queue latency (verified live,
2026-08-17) — the fix isn't a better cadence, it's a reliable _caller_.
GitHub itself can't be that caller (the thing throttling `schedule:` is
GitHub's own scheduler), so the caller has to live outside GitHub. Per
ADR-0014 §3, Cloud Run Jobs is the framework default for batch/serverless
compute; Cloud Scheduler is the reliable-cron piece GitHub can't provide for
itself. This is `infra`'s first GCP resource.

The GCP-side compute needs a GitHub token scoped to call
`workflow_dispatch` on `carpet-stain/infra`. The existing
`/runtime/vended-token` deliberately excludes `infra` from its repo list
(#51's crafted-PR-against-infra containment, ADR-0008's #163 amendment) —
reusing it here would reopen that containment for an unrelated reason. This
ADR mints a second, dedicated `/runtime/*` token instead, scoped to nothing
but `actions: write` on `infra`, leaving the general vended-token's
containment untouched.

## ADR-0014 §5 integration checklist

1. **Class** (protocol / runtime / adapter / platform): **Runtime** — Cloud
   Run Jobs consumes a plain OCI image (`docker push` in, no proprietary
   SDK in the container itself); Cloud Scheduler's HTTP target is a
   standard REST call with OAuth, not a GCP-specific trigger binding. §3's
   playbook already names Cloud Run Jobs the batch/serverless default —
   this ADR is the "per-service ADR" that §4's closing note requires before
   GCP appears anywhere in this repo's footprint, but the class itself
   clears §4 by inspection (Runtime, not Platform): no application logic
   or data model lives in GCP, only a reliable timer and a stateless
   executor.
2. **Deployment/data artifact** — is it standard?: Yes. The Job is an OCI
   image (`gcp/dispatch/Dockerfile`); Cloud Scheduler's config is plain
   Terraform, no vendor UI. No data is stored in GCP at all — the job is
   stateless and holds no state beyond one HTTP round trip per invocation.
3. **Exit path**, in one command or one paragraph: `docker push` the same
   image to any other OCI-accepting scheduler (a k3s CronJob is the
   self-hosted equivalent already in the target stack, ADR-0014 §7) and
   repoint the AWS trust policy's `sub` condition at the new caller's
   identity. Nothing GCP-specific leaks into the container itself — it
   reads three env vars and calls two REST APIs (AWS STS/SSM, GitHub).
4. **Egress exposure** to read all the data out once a month: None — no
   data lives in GCP to read out. The only traffic is the job's own outbound
   calls (AWS STS, AWS SSM, GitHub API), a few KB per 5-minute tick.
5. **Self-hostable alternative** on existing Hetzner/homelab capacity at
   ~zero marginal cost?: Yes in principle (a k3s CronJob calling the same
   entrypoint), but the entire premise of this fix is a scheduler GitHub's
   own infrastructure doesn't control — Hetzner buys nothing there over
   GCP, and GCP's Cloud Scheduler + Cloud Run Job pair is free at this
   volume (2,016 job-executions/month, both products' free tiers cover
   far more). Revisit only if `infra` ever runs its own always-on compute
   for other reasons and a k3s CronJob becomes free to add.
6. **Terraform provider** — official and maintained?: Yes —
   `hashicorp/google`, HashiCorp-maintained, `~> 6.0`.
7. **Vendor-death / suspension blast radius** — what breaks with 30 days'
   notice, or none? Name anything correlated (shared account with DNS,
   storage, hosting): If GCP suspends this project, `vend-token.yml` falls
   back to its existing `schedule:` trigger (kept as a backstop, not
   replaced) — degraded to the pre-#191 dead-window behavior, not an
   outage. No other service shares this GCP account; it holds nothing but
   this one job, so there's no correlated blast radius with DNS, R2, or
   any other provider in the stack.
8. **Free-tier dependency** — paid price when the tier changes, and the
   trigger (rows, seats, requests) that flips it: Cloud Run Jobs free tier
   is 180k vCPU-seconds + 360k GiB-seconds + 2M requests/month; Cloud
   Scheduler's free tier is 3 free jobs. This workload uses 1 scheduler job
   and ~8,640 sub-second executions/month — orders of magnitude under
   either ceiling. If GCP ever prices Cloud Scheduler's free-job count to
   zero, the cost is one job at its list price (cents/month) — not a
   structural risk.
9. **Backup, not just exit** — is there a scheduled, restore-tested backup
   path, or only a migration tool run by hand?: N/A — stateless compute,
   nothing to back up. The Terraform in `gcp/` is the durable definition;
   redeploying it re-creates the job identically.
10. **Vendor security posture** — SOC 2 / breach history / access controls
    for the data this service will hold: Google Cloud holds SOC 2 Type II
    and ISO 27001 certification. Irrelevant in practice here regardless —
    the job holds no persistent secret; the one credential it touches
    (`/runtime/infra-dispatch-token`) is read fresh via OIDC federation
    each run and never written to GCP-side storage or logs.

## Decision

**Cloud Scheduler (GCP) → Cloud Run Job (GCP) → OIDC-federated AWS STS →
SSM read → GitHub `workflow_dispatch`.** No ADR-0014 §4 exception needed
(Runtime-class, see checklist #1); no Lambda (ADR-0014 §3's explicit
Never); no standing credential anywhere in the new path.

- **Cloud Scheduler** fires an HTTP POST against the Cloud Run Jobs Admin
  API every 5 minutes, authenticated as a dedicated GCP service account
  (`scheduler-dispatch-invoker`) holding `roles/run.invoker` on the job
  only — no broader project role.
- **Cloud Run Job** (`vend-token-dispatch`, `gcp/dispatch/`) runs as its
  own service account (`cloud-run-dispatch`). It mints its own GCP-issued
  OIDC identity token (audience `sts.amazonaws.com`, from the instance
  metadata server — no key material anywhere) and presents it to
  `sts:AssumeRoleWithWebIdentity` against a new AWS role,
  `infra-dispatch-read` (`iam/main.tf`, bootstrap-only state — same
  privilege-escalation-avoidance reasoning as every other role there,
  ADR-0010). The trust condition pins `accounts.google.com:sub` to the
  service account's numeric `unique_id`, never its email (ADR-0010's #163
  ID-pinning discipline — emails are the friendly name, not the stable
  identifier a trust policy should key on).
- **`infra-dispatch-read`** can do exactly one thing: `ssm:GetParameter`
  on `/runtime/infra-dispatch-token` plus `kms:Decrypt` on
  `alias/runtime-secrets` — the same shape as `pst-e2e-read` and
  `pr-review-openrouter-read`, one ARN, read-only, runtime tier only. It
  never resolves `kms:Decrypt` on `alias/infra-secrets` — it joins ADR-
  0010's fence (a) non-escalation set.
- **`/runtime/infra-dispatch-token`** is a _new_, dedicated SSM parameter,
  not a reuse of `/runtime/vended-token`. `vend-token.yml` gains one more
  step: mint a second token scoped to `actions: write` on `infra` only
  (no other permission, no other repository) and publish it here, using
  the App key it already holds and the `infra-vend-write` role's existing
  crown-jewel read (extended with one more `ssm:PutParameter` grant, this
  parameter's ARN only). This keeps #51's containment on the _general_
  vended-token completely untouched — a Cloud Run Job compromise can
  dispatch one workflow on `infra` and nothing else, and a
  `dotfiles`/other-repo consumer's vended-token compromise still can't
  touch `infra` at all.
- The Job never mints anything — minting stays inside `vend-token.yml` via
  `infra-vend-write`, unchanged in shape from ADR-0010's original design.
- **Self-sustaining, with a backstop.** Once Cloud Scheduler successfully
  triggers one `vend-token.yml` run, that run re-mints both tokens
  (`/runtime/vended-token` and `/runtime/infra-dispatch-token`), so the
  next scheduler tick always has a fresh dispatch token — as long as
  _something_ triggers a run within any 1h window (the App-token TTL).
  GitHub's own `schedule:` trigger stays wired as exactly that backstop:
  degraded (back to the pre-#191 dead-window behavior) rather than a hard
  outage if GCP has its own bad day.
- **GCP onboarding is code-only in this ADR's PR.** `gcp/` is a new
  bootstrap-only Tofu root module (own state, third key in the same R2
  bucket, mirroring `iam/`'s isolation from CI) — applied locally, never
  by CI, since no GCP-authenticated CI identity exists yet. The project,
  billing account, and Application Default Credentials are created by
  hand per `docs/BOOTSTRAP.md` §17 before the module's first apply.

## Alternatives considered

- **Lambda + EventBridge.** Rejected — both are ADR-0014 §3's explicit
  Never for this category (`#98` and the now-closed-moot `#215` covered
  this ground already); no new argument reopens it.
- **Reuse `/runtime/vended-token` for the dispatch call**, widening its
  repo CSV to include `infra`. Rejected — this is the #51 crafted-PR-
  against-infra containment specifically, not an incidental scoping
  choice; widening it for an unrelated automation need trades a narrow,
  well-understood risk for a broader one to save one SSM parameter and one
  mint step. A second dedicated token costs nothing extra to operate and
  keeps the two blast radii independent.
- **Tighten `schedule:`'s cadence further** (the original framing, before
  #98/#114 concluded the ceiling is GitHub's, not this repo's config).
  Rejected — already litigated: no interval, however tight, fixes a
  best-effort trigger GitHub itself throttles under load.
- **A self-hosted k3s CronJob today, skip GCP entirely.** Rejected for
  now per checklist #5 — `infra` runs no always-on compute today, so
  standing one up costs more than GCP's free tier does at this volume.
  Named as the exit path (checklist #3) precisely so this isn't a one-way
  door if that changes.
- **Wire GCP into CI immediately** (drift detection via `tofu-plan.yml`
  equivalent for `gcp/`). Deferred, not rejected — no GCP-authenticated
  CI identity exists yet (this repo's first GCP resource), and building
  GCP↔GitHub OIDC for CI is a separable piece of work from the dispatch
  fix itself. `gcp/` stays local-apply-only until a follow-up names that
  identity.

## Consequences

`vend-token.yml`'s dead window closes: as long as one run happens within
any rolling hour, the next Cloud Scheduler tick has a live dispatch token
to trigger the next one. `infra`'s footprint gains a second cloud account
(GCP) with its own project/billing/service-account surface to audit
alongside AWS's — enumerated in `gcp/`'s own state and `docs/BOOTSTRAP.md`
§17, and `infra-dispatch-read` joins ADR-0010's fence (a) audit set in
`AGENTS.md`'s identity table.

New residual: GCP's own `schedule`-adjacent surface (Cloud Scheduler) could
in principle suffer a similar throttling failure mode to GitHub's; nothing
here proves it won't, only that it's a different, independently-operated
scheduler than the one causing today's problem, and the `schedule:`
backstop means a GCP outage degrades rather than breaks the flow.

`gcp/` stays local-apply-only (no CI wiring) until a follow-up issue
designs a GCP-authenticated CI identity — revisit if drift detection on
this module becomes worth the design cost. Revisit this ADR's whole
premise if GitHub ever ships a reliable low-latency scheduled trigger of
its own; the caller-outside-GitHub shape here exists only because today it
can't provide one for itself.

Refs: #191, #51, #98, #215 (closed moot), ADR-0010, ADR-0014,
dotfiles#619, dotfiles#453.

## Amendment — #191 (2026-08-18): accounts.google.com is a native principal, not a custom OIDC provider

Live testing after this ADR's PR merged found the Decision's AWS-side
mechanics wrong in two ways — both AWS-STS-specific, neither visible from
Terraform validation or a plan (no live GCP project existed to test
against until after merge, per this ADR's own code-only scope).

**What was wrong.** The original `iam/main.tf` created an
`aws_iam_openid_connect_provider "google"` resource (mirroring the
`github` provider's shape exactly) and pointed the `dispatch_read` role's
trust policy `Federated` principal at that resource's ARN. Every live
attempt failed with `InvalidIdentityToken: The web identity token
provided could not be validated` — a token-validation failure occurring
_before_ AWS ever evaluates a trust policy's `Condition` block (confirmed
via CloudTrail showing no attributable event for the failed calls at all,
unlike a `Condition`-mismatch `AccessDenied`, which does log).

**Root cause.** `accounts.google.com` is one of a small set of identity
providers AWS STS recognizes _natively_ (alongside Login with Amazon and
Facebook) — a different, older mechanism than the generic
`iam:CreateOpenIDConnectProvider` path GitHub/GitLab/etc. use. AWS's own
IAM condition-keys reference shows every Google trust-policy example
using the literal string `"accounts.google.com"` as the `Federated`
principal, never an OIDC-provider ARN; a real, published Terraform module
for this exact GCP-service-account-to-AWS pattern (Spotify's
`gcp-aws-iam-federation-webidentity`) creates no OIDC provider resource
for Google at all. Registering one anyway doesn't error at apply time —
Terraform/AWS accept the resource — but STS never matches an incoming
Google-issued token's issuer to it, so validation fails before condition
evaluation ever runs.

A second, related gotcha surfaced once the principal was fixed: the
failure changed from `InvalidIdentityToken` to `AccessDenied: Not
authorized`, i.e. the _token_ now validated but the _condition_ didn't.
AWS's native-Google-federation claim mapping is not a 1:1
`<issuer>:<claim-name>` scheme the way generic OIDC condition keys are:
the `accounts.google.com:aud` condition key maps to the token's `azp`
claim when present (falling back to `aud` only if `azp` is absent) — and
a GCP service-account identity token always carries `azp` (set to the
same value as `sub`). The fix is `accounts.google.com:oaud`, a separate
AWS-documented key that maps to the raw `aud` claim regardless of `azp` —
exactly what Spotify's module uses instead of `:aud`.

**Fix applied** (`iam/main.tf`): removed the `aws_iam_openid_connect_provider
"google"` resource entirely; `dispatch_read`'s trust policy now sets
`Principal = { Federated = "accounts.google.com" }` (a literal string) and
checks `accounts.google.com:oaud` (not `:aud`) against `sts.amazonaws.com`,
alongside the unchanged `accounts.google.com:sub` ID-pin. Verified live,
end to end: the Cloud Run Job successfully assumes `infra-dispatch-read`,
reads `/runtime/infra-dispatch-token`, and dispatches `vend-token.yml`
(`HTTP 204`, a real workflow run landing within seconds).

**Consequence for future non-GitHub OIDC federation in this repo**: any
future identity provider AWS recognizes natively (Amazon, Facebook, and
Google are the current set) needs this same literal-principal-plus-`oaud`
shape, not the generic `iam:CreateOpenIDConnectProvider` pattern
`iam/main.tf`'s other roles use. Everything else here — path/tier
scoping, ID-pinning via `sub`, bootstrap-only state — is unaffected and
was correct as originally designed.

## Amendment — #243 (2026-08-18): the dispatch token is two-fenced, not one

The Decision's "scoped to nothing but `actions: write` on `infra`, leaving
containment untouched" framing treated token scope as the only fence,
and #243 found the gap that hid: `infra-local-read`'s then-`/runtime/*` wildcard
let the broadest-held local key read this token, and `actions:write` on
infra dispatches _any_ `workflow_dispatch` workflow — `tofu-apply-dispatch.yml`
included — so runtime-tier read escalated to an infra apply. The real
structure is **two independent fences** (ADR-0010's matrix as amended
by #243): (1) **token scope** — `actions:write`, infra only; (2) **reader
scope** — only `infra-dispatch-read` can read
`/runtime/infra-dispatch-token`; `infra-local-read`'s explicit allow-list
excludes it. Narrowing the reader set still doesn't gate the token→apply
chain itself — defense-in-depth on the dispatch target (an Environment /
required-reviewer gate) is #246.
