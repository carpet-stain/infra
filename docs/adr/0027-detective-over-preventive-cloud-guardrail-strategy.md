# 0027. Detective-over-preventive cloud-guardrail strategy

Date: 2026-08-20

## Status

Accepted

## Context

The AWS account has solid identity hygiene — least-privilege OIDC roles and
the SSM/IAM machine-secret spine (ADR-0010), the gated admin credential
(ADR-0013), console-only admin with root break-glass-only (ADR-0015) — but no
codified spend or safety guardrails. The only cost control is a hand-created
$0.01 zero-spend budget; no CloudTrail, public-bucket block, or region pin
exists in Tofu. GCP is greenfield — its first resources landed via #191 with
zero guardrails.

Epic #230 (plan-approved 2026-08-17) adds guardrails for both hyperscalers.
The shaping question is preventive machinery (Organizations, SCPs, hard
spend caps) versus detective controls (trails, analyzers, budget alerts) —
for a solo operator on a ~$0, fully-IaC, federation-only account whose
console surface is already near zero. This ADR records the strategy so the
implementation children (#232–#237) build against it instead of
re-litigating it.

## Decision

**Detective over preventive — no AWS or GCP Organizations.** The
load-bearing fact: a single-account Organization can't apply SCPs to its own
management account, so gaining any SCP protection over root or
`infra-console-admin` would need a two-account restructure — disproportionate
for one person, all-IaC, federated OIDC, no standing keys. The preventive
tier stops at what an org-free single account can enforce; everything past
that is detective.

**Alert-only spend, no hard cap.** Monthly budget alerts at $20/$50/$100 per
cloud, kept alongside the existing $0.01 zero-spend floor — a $20 forecast
floor alone would miss a slow leak on a ~$0 account. AWS can't truly
hard-stop spend, and GCP's billing kill switch would take down our own Cloud
Run (ADR-0024/0026).

**Org-free preventive freebies.** Account-level public-bucket block (S3
Block Public Access; GCS public-access prevention) and an
`aws:RequestedRegion` pin on `infra-apply` (us-east-1, no global-service
exception — nothing global runs under it). The R2 state backend is
untouched: the pin governs AWS-API calls only, and the backend speaks to a
non-AWS endpoint with R2 credentials.

**AWS guardrails live in the break-glass `iam/` module, not the CI-applied
root.** They're account-security-class: account-wide, ~yearly, security
judgment. In root they'd widen `infra-apply` — a role any `main` push
assumes — with cost/audit/S3 management, and two resources would breach
ADR-0010's "`infra-apply` never `iam:*`/`kms:Put*`" fence outright: Access
Analyzer's service-linked role needs `iam:CreateServiceLinkedRole`, and a
KMS-encrypted CloudTrail needs `kms:Put*` — so the trail uses SSE-S3, never
a tier KMS key. Applied via a minimally-widened bootstrap key.

**No live alert path.** ADR-0014 Never-lists SNS, CloudWatch Alarms, and
Pub/Sub, so CloudTrail and Access Analyzer findings are cold forensics
**reviewed in the periodic security audit** (AGENTS.md's audit list), not
paged. Budgets notify by email natively on both clouds — GCP Budgets are
email-only, no Pub/Sub topic.

## Alternatives considered

- **AWS/GCP Organizations + SCPs / Org-Policy constraints.** Rejected: the
  one thing SCPs would add here — a fence over root and console-admin — is
  exactly what a single-account org can't provide (it can't SCP its own
  management account). A two-account restructure to get it is
  disproportionate at this scale. Revisit on a second account.
- **Hard spend caps / billing kill switch.** Rejected: AWS has no true
  hard-stop, and GCP's (disable billing on budget breach) would take down
  our own Cloud Run services — a self-inflicted outage as the failure mode
  of a cost control.
- **Cost Anomaly Detection.** Deferred: needs spend history to model; buys
  nothing on a ~$0 account. Revisit once real spend exists.
- **GuardDuty.** Rejected: recurring cost and threat-hunting noise for an
  account with no workloads or data worth hunting over.
- **AWS Config.** Rejected: per-item recording cost to detect drift that the
  periodic audit and an all-IaC posture already cover.

## Consequences

- The implementation children (#232–#237) build against a settled stance —
  budgets, CloudTrail, Access Analyzer, public-access blocks, the region
  pin, and the GCP track each land as scoped PRs citing this ADR.
- **Accepted tradeoff:** guardrails in `iam/` sit outside routine CI drift
  detection (`tofu-drift.yml` covers the root module only). The periodic
  security audit picks this up — "guardrails still applied and drift-free"
  joins its item list.
- The bootstrap key gains `budgets:`/`cloudtrail:`/`s3:` (trail bucket)/
  `access-analyzer:`/`iam:CreateServiceLinkedRole` grants (documented in
  BOOTSTRAP.md); `infra-apply` gains nothing — ADR-0010's fence holds.
- Root and `infra-console-admin` stay outside any SCP fence — accepted;
  their protection remains the human ceremony ADR-0015 records (MFA,
  break-glass, no programmatic keys).
- **Revisit if** a second account appears (Organizations becomes able to
  fence the first), real spend exists (Cost Anomaly Detection becomes
  useful), or workloads/data worth threat-hunting land (GuardDuty).
