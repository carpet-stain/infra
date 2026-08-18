# 0010. AWS SSM Parameter Store and IAM as the machine-secret store

Date: 2026-07-27

## Status

Accepted

Supersedes ADR-0008, ADR-0009.

Audit-invariant clause amended in place — #126 (the local elevated
identity) and #155/ADR-0015 (the console-admin escalation class); see the
Amendment sections at the end.

Human-credential residency claim superseded by ADR-0016 (#170); the
machine/human scope boundary stands — see the last Amendment section.

## Context

ADR-0008 spent the entire free-tier Machine Account budget (three, hard cap)
on day one. Its own Consequences section named the revisit trigger — "a
genuine fourth consumer" — and #73 hit it four days later, patched by reusing
an existing account rather than spending a Project slot. #76 and #98 then
spent two more spikes on the vend workflow's cadence problem and concluded
with an accepted, unfixable residual: on a public repo, GitHub's `schedule:`
trigger is best-effort, so a vended token can go dead for the length of a gap
no cadence tightening removes, and #98 rejected every on-demand alternative
because GitHub cannot scope `actions: write` to a single workflow. Three
spikes in three days against the same store is the signal, not any one of
them alone: the free tier isn't merely tight, it's structurally unable to
add a fourth consumer without either spending money or re-deriving the same
trust-tier reasoning under a tighter cap each time.

This issue (#114) opened as a fourth reorg — restructure the existing
Projects/Machine Accounts within the free tier's limits. Pricing it against
the alternative changed the question. **Bitwarden Secrets Manager Teams**
(the paid tier that lifts the three-account cap) is ~$72/yr and still caps
resource _counts_, just at a higher number — the same shape of ceiling,
moved. **AWS SSM Parameter Store, Standard tier, is free with unlimited
parameters and unlimited IAM identities**; the scarce resource that drove
every one of #73/#76/#98's trade-offs doesn't exist in the replacement.
GitHub Actions' native OIDC federation additionally removes the vend
workflow's entire reason to exist for CI consumers: a CI job can assume an
IAM role directly, no minted-and-published credential in the loop, no
cadence problem to have. Reorganizing BWS first and migrating to AWS later
would mean doing the trust-tier design twice — the fork this spike names in
its own body (Bitwarden paid vs AWS) resolves to AWS, and the trust-tier
thinking that would have gone into a BWS reorg lands directly in the IAM
design below instead.

**Scope boundary, unchanged from ADR-0008**: this is the machine-secret
store — `infra`'s own credentials and what it vends to local/agent shells.
Human credentials stay in the Bitwarden password-manager vault; nothing
here touches that.

## Decision

**AWS SSM Parameter Store + IAM is the account's machine-secret store**,
provisioned as code in this repo. CI authenticates via **OIDC federation —
no standing AWS credential in GitHub Actions, ever**. The store is
cloud-neutral plumbing: a zero-compute AWS account (authenticated API calls
only, no workload) doesn't tie any managed project to AWS as a platform.

**Path is the access boundary, replacing Project.** Bitwarden's Project was
the only ACL granularity it had; SSM's parameter path plays the identical
role, scoped by IAM policy instead of a provider-specific grant:

- **`/infra/*`** — the crown-jewel tier: GitHub App private key, Cloudflare
  API token, Tofu state passphrase, both R2 credential pairs, R2 account id.
  Direct successor to ADR-0008's `infra` Project and ADR-0009's remainder.
- **`/runtime/*`** — the rotating tier: the vended GitHub token
  (`/runtime/vended-token`), and a reserved `/runtime/<app>/*` shape for a
  future workload's own runtime secrets (none exist yet — no design work
  ahead of a real consumer, Simplicity First). Direct successor to
  `vended-tokens`.

Every `SecureString` parameter is encrypted under a **per-tier customer-
managed KMS key** (`alias/infra-secrets`, `alias/runtime-secrets`), not the
AWS-managed default. This is a deliberate improvement over the Bitwarden
model, not just a translation of it: a Project's ACL was the _only_
enforcement point, so a policy bug that granted an extra `ssm:GetParameter`
would have been a straight break of the containment invariant. A second,
independent boundary — a role must hold both the SSM path grant and a KMS
`kms:Decrypt` grant on that tier's key to read a value — means one
misconfigured policy alone can't cross tiers.

**Role-per-consumer, least-privilege path scoping — the ADR-0008
containment invariant re-expressed in IAM:**

| Role                | `/infra/*` read    | `/infra/*` write | `/runtime/*` read      | `/runtime/*` write                 | Held by                                        |
| ------------------- | ------------------ | ---------------- | ---------------------- | ---------------------------------- | ---------------------------------------------- |
| `infra-plan-read`   | yes                | no               | no                     | no                                 | `tofu-plan`/`tofu-drift` (OIDC)                |
| `infra-apply`       | yes                | yes              | no                     | no                                 | `tofu-apply`/`tofu-apply-dispatch` (OIDC)      |
| `infra-vend-write`  | yes (App key only) | no               | no                     | yes (`/runtime/vended-token` only) | `vend-token.yml` (OIDC)                        |
| `infra-local-read`  | no                 | no               | yes                    | no                                 | a local/agent shell (IAM user, Keychain-gated) |
| `infra-app-runtime` | no                 | no               | yes (own subpath only) | no                                 | reserved — no workload exists yet              |

The invariant to check, direct successor to ADR-0008's: **no role a local or
agent shell ever holds resolves `kms:Decrypt` on `alias/infra-secrets`, and
the roles a local shell can assume and the roles CI assumes share no common
grant.** `infra-vend-write`'s read on `/infra/*` is scoped further than the
table shows — an inline policy naming the App-key parameter ARN only, not a
path wildcard, so compromising the vend role's CI job can't walk the rest of
the crown-jewel tier (Bitwarden's Project grant couldn't express this;
IAM's resource-ARN scoping can, and this is strictly tighter than what
ADR-0008 shipped). Name it plainly rather than let the "vend-**write**"
label imply otherwise: `infra-vend-write` is an **unattended, scheduled**
job that holds `kms:Decrypt` on the crown-jewel key for one ARN — the same
shape of exposure #98 already named for BWS's Vending account (whole-
`infra`-Project read), just narrowed from a whole Project to one ARN. It's
an improvement, not a new risk, but the periodic audit against this
invariant must include it, not just `infra-local-read`.

`infra-plan-read`'s read surface is **the entire crown-jewel tier**, not a
lesser one — `tofu-plan.yml` and `tofu-drift.yml` both fetch the App key,
the state passphrase, and both R2 pairs to refresh state and mint a read
token, so `infra-plan-read` holds the same `/infra/*` read + `kms:Decrypt`
grant `infra-apply` does; write is the only difference. Its trust policy
must name the exact subs it's used from, not a repo-wide wildcard: GitHub's
OIDC `sub` claim is `repo:carpet-stain/infra:pull_request` for
`tofu-plan.yml`'s `pull_request` trigger and
`repo:carpet-stain/infra:ref:refs/heads/main` for `tofu-drift.yml`'s
`schedule` trigger (schedule/push triggers carry the branch-ref sub, not a
`pull_request` one) — two explicit conditions, not `repo:carpet-stain/infra:*`.
This design assumes GitHub never forwards `id-token: write`'s OIDC token to
a fork-originated `pull_request` run without explicit approval (true today,
and unaffected by the exact-sub fix above, since forked-repo runs still
present the same-repo `pull_request` sub once approved) — revisit this
trust policy the day `infra` ever accepts outside contributions.

**IAM, the OIDC provider, and the two KMS keys are managed from a separate
Tofu root module and state that CI never plans or applies** — a second
backend key in the same R2 bucket (e.g. `iam/terraform.tfstate`), applied
only by the local bootstrap/break-glass key. This is the fix that makes the
"one misconfigured policy can't cross tiers" claim actually hold: if the
OIDC/IAM/KMS resources lived in the same state `infra-apply` manages, that
role would need `iam:PutRolePolicy`, `iam:UpdateAssumeRolePolicy`, and
`kms:PutKeyPolicy` just to `plan`/`apply` its own module — permissions that
let it rewrite any role's trust policy or grant itself `kms:Decrypt` on the
tier it's supposed to be fenced from, exactly the privilege-escalation path
ADR-0008's Bitwarden design avoided by giving the `bitwarden-secrets`
provider no resource for Projects/Machine Accounts/grants at all. Splitting
the state reproduces that same shape in Tofu: `infra-plan-read` and
`infra-apply` hold only `ssm:GetParameter`/`ssm:PutParameter` (path-scoped)
and `kms:Decrypt`/`kms:GenerateDataKey` (key-scoped) — never `iam:*` or
`kms:Put*` — because the resources those permissions would manage simply
aren't declared in the state either role ever touches. The SSM parameter
_resources_ (values/metadata) stay in the existing CI-applied root module,
referencing each KMS key by its literal alias name (`alias/infra-secrets`),
not a cross-state lookup — no data-source dependency on the IAM module is
needed for that reference to resolve.

**Bootstrap sequence resolves the credential chicken-and-egg** (tofu needs
AWS credentials before it can create the very OIDC provider that lets CI
stop needing standing ones):

1. **Human ceremony** (docs/BOOTSTRAP.md gets an AWS section; sketched here,
   written in full by the migration epic's first child): create the AWS
   account, enroll hardware MFA on the root user, set a low-threshold
   billing alarm (this account should run at effectively $0 — SSM Standard
   and IAM cost nothing at this scale), pick one region and pin it in
   `versions.tf` (SSM parameters are regional; no reason to pick anything
   but the region nearest existing tooling — recorded, not re-derived, when
   the child issue lands), and create a **bootstrap IAM user** scoped to
   exactly `iam:CreateOpenIDConnectProvider`, `iam:CreateRole`,
   `iam:PutRolePolicy`, `iam:CreateKey`/`kms:*` for the two tier keys, and
   `ssm:*` — not `AdministratorAccess`. Its access key lives in the macOS
   Keychain, gated the same way as ADR-0009's `infra-bws` item (no `-A`, so
   every read prompts) — local-only, never a GitHub secret.
2. **Local `tofu apply` against the IAM module, using the bootstrap key**,
   creates: the `token.actions.githubusercontent.com` OIDC identity
   provider (AWS resolves the thumbprint automatically — no manual
   thumbprint pinning, unlike the 2019-era guidance still floating around),
   the five roles above with trust policies scoped to the exact `sub`
   claims named above (never a repo-wide wildcard), and the two KMS keys
   with their per-role grants.
3. **Local `tofu apply` against the existing root module** declares the
   SSM parameters themselves (placeholder value + `lifecycle {
ignore_changes = [value] }` — SSM has no "value optional" shape the way
   Bitwarden's provider does, so a placeholder is the closest analog to
   ADR-0008's "no `value` in config").
4. **Hand-populate every real value** — state passphrase, both R2 pairs, R2
   account id, App private key, Cloudflare token, and (once Child 4 of the
   migration epic lands) the vended token — from its live BWS value into
   its SSM parameter, by hand, using the bootstrap/local-read credentials.
   Verify one read of each before treating it as populated: this is the
   single highest-risk manual step in the whole migration (a placeholder
   value silently read as the state passphrase fails state decryption, not
   loud in an obviously-diagnosable way), so it gets its own checklist item
   and verification gate in the epic, not just a mention here.
5. **CI workflows flip to `aws-actions/configure-aws-credentials` +
   `id-token: write`**, scoped at job level, never at workflow level —
   #98's finding that `actions: write` "is not the narrow capability its
   name suggests" on this repo generalizes: grant OIDC permissions per job,
   audit each job's trust condition individually, don't lean on a
   workflow-wide `permissions:` block the way a careless port of the
   existing `permissions: {}` pattern might invite.
6. **Verify** each role's trust condition and path scoping against a real
   plan/apply/vend run before relying on it.
7. **Demote the bootstrap key**: deactivate (don't delete) once OIDC is
   confirmed working for every CI path — kept as local break-glass, rotated
   on a schedule or on suspicion of compromise, never used for routine work
   again. Deactivated-not-deleted is a real residual, not a closed risk: an
   extant key with `iam:CreateRole`/`kms:*`/`ssm:*` permissions, however
   inactive, is worth a periodic "still deactivated, still needed" check —
   name it in the same audit pass as the containment invariant above.

**Provider and state mechanics**: add `hashicorp/aws` to `versions.tf`
alongside `github`/`cloudflare`/`bitwarden-secrets` (the latter removed at
decommission, see below) for the existing root module; the IAM module
(above) pins the same provider in its own `versions.tf`. State stays on
R2, untouched — SSM is a secret store, not object storage, and ADR-0002's
backend has no AWS dependency today (`skip_credentials_validation` etc.
are already `true` specifically _because_ R2 isn't AWS); the IAM module's
state is a second key in the same R2 bucket, not a new backend. The
plan-vs-apply split mirrors #59's read/write R2 pair exactly:
`infra-plan-read` (read-only IAM policy, no `ssm:PutParameter`) for
`tofu-plan`/`tofu-drift`, `infra-apply` (read/write) for
`tofu-apply`/`tofu-apply-dispatch` — the same shape as the existing
`R2_PLAN_*` vs `R2_APPLY_*` credential pair, now expressed as two IAM roles
instead of two credential pairs.

**Local access has no BWS-style account-cap constraint, and that changes
the local design for the better.** ADR-0009 reused the CI Machine Account
for local infra-reads because a fourth account didn't exist in the budget.
AWS IAM identities are free and unlimited, so `infra-local-read` is its own
dedicated IAM user rather than a reused, over-scoped one — a strict
tightening, not a like-for-like port. GitHub OIDC has no local-shell
equivalent (there's no Actions `sub` claim to federate from a laptop), so
`infra-local-read` stays a conventional IAM user access key, Keychain-gated
exactly like ADR-0009's pattern, scoped to `ssm:GetParameter` on
`/runtime/*` only. `infra-app-runtime` is a reserved name and path
convention only — no role, no policy, until a workload exists to design it
against.

**Decommission line**: BWS retains nothing machine-side once migration
completes. Order: stand up the AWS side fully while BWS stays live (no flag
day); migrate each `/infra/*` secret one at a time (state passphrase, R2
pairs, App key, Cloudflare token), swapping each workflow's
`bitwarden/sm-action` step for an SSM fetch; migrate the vend path last —
rewrite `vend-token.yml`'s publish step from `bws secret edit` to
`aws ssm put-parameter` against `/runtime/vended-token` (the vend step
itself doesn't disappear: `dotfiles`'s local/agent shell still isn't a
GitHub Actions OIDC principal, so a delivered credential is still the
mechanism, just published to SSM instead of Bitwarden); once nothing reads
BWS, remove the `bitwarden-secrets_secret` resources (`removed{}` blocks,
mirroring `app.tf`'s existing precedent for retiring the old native
secret) and the provider block from `versions.tf`; last, tear down the
Bitwarden Organization/Projects/Machine Accounts by hand (mirror of
`docs/BOOTSTRAP.md`'s manual-bootstrap steps, in reverse) and update
`docs/CONSUMING-SECRETS.md` for the AWS-side self-service story. The full
reference enumeration (every workflow, script, `.envrc` var, and doc on
both the `infra` and `dotfiles` side that names a `BWS_*`/`BW_*` value) is
the migration epic's tracked checklist, not restated here — an ADR records
the decision, not the day-by-day flip list.

## Alternatives considered

- **Reorganize BWS around trust tiers within the free tier** (this issue's
  original v1 framing). Rejected — #73/#76/#98 already spent three spikes
  fighting the same scarce-resource ceiling from different angles, and the
  ceiling is structural (a fixed Machine Account count), not a design flaw
  a reorg fixes. Doing that work now would be redone the moment AWS is
  adopted, since the trust-tier reasoning is identical either way — it
  belongs in IAM policy design once, not in Bitwarden Project design first.
- **Bitwarden Secrets Manager Teams** (paid, ~$72/yr, lifts the 3-account
  cap). Rejected — it raises the ceiling, it doesn't remove it; the same
  class of "spike to reorganize within a cap" recurs at a higher number.
  AWS SSM Standard has no comparable cap on parameters or IAM identities at
  this account's scale.
- **AWS Secrets Manager instead of SSM Parameter Store.** Rejected on cost:
  Secrets Manager bills per secret per month plus API-call pricing; this
  account has no rotation-Lambda use case (GitHub Actions workflows already
  own minting/vending), so Secrets Manager's rotation automation buys
  nothing here that SSM Standard's flat-free tier doesn't already cover.
- **Cloudflare Secrets Store**, re-litigated for the machine-secret case
  generally (ADR-0004 already rejected it for the App key specifically).
  Rejected on the same grounds: Cloudflare's own docs state a Read-scoped
  API token can't read a secret's value back, only bind it into a
  Worker/AI Gateway — no CI/local/tofu consumer here can ever read a value
  out of it, a product-shape mismatch, not an auth gap.
- **AWS IAM Identity Center (SSO) for local access**, instead of a
  dedicated IAM user. Rejected as unnecessary complexity for a single local
  consumer path: SSO earns its keep with multiple human operators needing
  federated, auditable access across many accounts; this is one
  Keychain-gated credential on one laptop, the same shape ADR-0009 already
  validated for Bitwarden. Revisit if this account ever needs more than one
  human's local access.
- **Keep the vend-token pattern's shape but publish to SSM without OIDC for
  CI** (i.e., migrate the store but not the CI credential model). Rejected
  — it would keep every one of #76/#98's cadence and `actions: write`
  findings alive for no reason; OIDC removes CI's need for a delivered
  credential entirely, so leaving CI on a vend-and-fetch pattern against
  the new store would carry the old problem into the new tool for free.
- **In-repo encrypted secrets (SOPS/age), no external store at all.**
  Rejected — it solves the CI-side problem cleanly enough but has no answer
  for the vended-token path: a local/agent shell in another repo
  (`dotfiles`) still needs a live, rotating credential handed to it, and an
  encrypted file in `infra`'s own repo doesn't reach a different repo's
  shell any more than a native GitHub secret would. Would still need a
  second mechanism bolted on for that case, so it doesn't actually reduce
  the moving parts this decision has to cover.

## Consequences

The free-tier ceiling that drove #73/#76/#98 disappears — a new consumer
gets a new IAM role and SSM path, no account-budget negotiation. CI holds
no standing AWS credential ever; `vend-token.yml`'s entire reason to exist
narrows to serving the one non-OIDC consumer (a local/agent shell), rather
than every consumer including CI. The local path picks up a real
improvement (its own dedicated, narrower IAM identity) as a side effect of
AWS having no account-count scarcity, not as separate design work.

New surface to own: an AWS account is now part of this account's footprint,
with its own root/MFA/billing-alarm ceremony (docs/BOOTSTRAP.md's AWS
section) and its own bootstrap credential (the deactivated-but-retained
break-glass key) to audit periodically, the same category of manual,
provider-unmanaged bootstrap ADR-0008 already accepted for Bitwarden's
Organization/Projects/Machine Accounts. This category isn't identical in
weight, though: an AWS root account carries billing-abuse exposure and a
broader compromise blast radius than a free Bitwarden Organization ever
did, and it's a standing decommission obligation (close the account, not
just stop paying) if this project ever goes dormant — worth naming plainly
rather than filing under "same category" and moving on. IAM roles and SSM
parameter _metadata_ are Tofu-managed; parameter _values_ are hand-set
exactly like Bitwarden's dynamic secrets were — moving stores doesn't
remove that step, it moves where it happens.

Migration is multi-step and dual-running by design (BWS stays live until
each secret is cut over), tracked as an epic rather than one PR — the
reference-enumeration flip list is real risk surface (every workflow,
script, and doc naming a `BWS_*`/`BW_*` value) and deserves its own
tracked checklist, not a single large diff. Revisit this decision only if
AWS SSM/IAM pricing or availability changes materially, or if a genuine
compute workload later gives this account a reason to be AWS-native beyond
secrets — neither is expected, and this ADR doesn't design for it ahead of
time.

## Amendment — #126 (2026-08-08): the local elevated identity

The decommission child surfaced a gap the original text never resolved:
routine local tofu runs (`just tofu` / `just tofu-apply` on the root
module) need a working crown-jewel credential, twice over — a plan
refreshes the `/infra/*` SecureString parameters (a decrypting read), and
`scripts/with-infra-secrets.sh` must fetch the state passphrase and R2
credentials from somewhere once Bitwarden is gone. The original role
matrix offered no identity for this: `infra-local-read` is runtime-tier
only, and the bootstrap key is deactivated break-glass, explicitly "never
used for routine work again."

Decision: a dedicated **`infra-local-apply` IAM user**, holding the same
read+write crown-jewel surface as the `infra-apply` CI role (they apply
the same module; the grants are shared verbatim in `iam/main.tf`), with
its access key hand-created in the console and stored in the login
Keychain **without** an app ACL — every read prompts. The **audit
invariant is amended accordingly**: from "no identity a local/agent shell
holds resolves `kms:Decrypt` on `alias/infra-secrets`" to "no
**silently-readable** local identity does" — the Keychain prompt is the
named fence, the same human-in-the-loop trust model ADR-0009 established
for the `infra-bws` item this replaces. Local and CI identities still
share no credential, and `infra-local-apply` holds no `iam:*`/`kms:Put*`,
so the trust roots stay reachable only through the bootstrap key's
reactivation ceremony.

Considered and rejected: keeping the invariant verbatim by storing local
copies of the four backend values directly in the Keychain (two homes per
value, rotation drift, and the SecureString refresh still needs _some_
AWS credential); reactivating the bootstrap key per local run (routinely
exercises a key holding `iam:*`/`kms:*`, the exact habit step 7 forbids).

## Amendment — #155 (2026-08-13): the console admin, an escalation class

`infra-console-admin` (ADR-0015) joins the account: a console-only
`Allow *:*` IAM user so daily console work stops running as root. It
cannot be folded into the invariant above — it resolves everything,
including `kms:Decrypt` on `alias/infra-secrets`, silently per read once
MFA'd — so **the audit invariant is restated as two fences**:

- **(a) Steady-state read-reachability** — the invariant as amended by
  #126, now explicitly over the non-escalation set (`infra-local-*`, the
  CI roles, `infra-vend-write`'s one-ARN carve-out): no
  _silently-readable_ key-holding identity resolves `kms:Decrypt` on
  `alias/infra-secrets`, and local and CI identities share no grant.
  `infra-local-apply` still resolves the key, never silently (per-read
  Keychain prompt).
- **(b) Escalation class** — `infra-bootstrap` and `infra-console-admin`
  reach anything by construction; their fence is human ceremony (MFA
  console session, no programmatic key, deactivation/discipline), not
  the path/key boundary. Audited as its own item: root and the console
  password/MFA stay in the Bitwarden human vault, the user keeps no
  access key (self-`CreateAccessKey` denied as defense-in-depth), root
  stays break-glass-only.

Reasoning, policy mechanics, and rejected alternatives: ADR-0015.

## Amendment — #170 (2026-08-13): human-credential residency → ADR-0016

The Context's scope boundary bundles two claims. The **scope boundary**
("this is the machine-secret store; human credentials are out of scope")
stands — it's what authorizes a separate ADR to own the human side. The
**residency claim** ("human credentials stay in the Bitwarden
password-manager vault") is superseded by ADR-0016: human logins default
to iCloud Passwords, the Bitwarden vault holds what exceeds the login
triad, and the four-tier decision tree lives there. Nothing machine-side
changes; this ADR's Status stays Accepted.

## Amendment — #163 (2026-08-14): OIDC sub claims are ID-pinned, and a same-sub residual

Comment-concision sweep #163 surfaced two implementation facts this ADR never recorded, both
in `iam/main.tf`'s trust-policy locals.

**Sub claims are GitHub's ID-pinned form, not the plain form this ADR's own Decision text
shows.** The Decision section above writes `repo:carpet-stain/infra:ref:refs/heads/main`; the
actual trust policies use `repo:carpet-stain@5483606/infra@1304594349:...` — owner and repo
numeric IDs baked into the sub, immune to a rename-then-resurrect attack the plain form
wouldn't catch. Verified against a live `AssumeRoleWithWebIdentity` denial and each repo's own
`GET /repos/{o}/{r}/actions/oidc/customization/sub` (`sub_claim_prefix`). Applies to both
`infra`'s own sub and `project-starter-template-e2e-read`'s (#147) — same verification method,
same ID-pinned shape.

**Accepted residual: `infra-apply`, `infra-vend-write`, and `tofu-drift.yml` share one sub.**
schedule/push/`workflow_dispatch` triggers all present the same branch-ref sub
(`gh_sub_main`); only `pull_request` differs. That means the trust policy alone can't tell
those three roles' triggering workflows apart on `main` — every main-branch workflow looks
identical to it. Accepted for now since all three already sit in this ADR's non-escalation,
same-trust-tier set; revisit if a workflow with a lesser trust tier is ever added on `main`.

## Amendment — #243 (2026-08-18): `infra-local-read` reads an explicit allow-list, not `/runtime/*`

ADR-0024's `/runtime/infra-dispatch-token` (`actions:write` on `infra`)
turned the matrix's `infra-local-read` row into an escalation path: the
broadest-held local key — silent, `-A`, in every local/agent shell — could
read a token that `workflow_dispatch`es any infra workflow, including
`tofu-apply-dispatch.yml`, i.e. runtime-tier read → an infra apply. The
matrix row's "`/runtime/*` read: yes" is superseded: `infra-local-read`'s
grant is now an **explicit per-parameter ARN allow-list** (`iam/main.tf`) —
every `/runtime/*` value with a local reader (steady-state consumption or
bootstrap/rotation verification); `/runtime/infra-dispatch-token`, the sole
parameter with no local reader _and_ an Actions-trigger capability, is
excluded by construction. This also makes the row fail-closed for future
parameters: a new `/runtime/*` value isn't local-readable until explicitly
added to the list — an `iam/` break-glass apply (BOOTSTRAP.md §12–§14).
`DecryptRuntimeTier` stays key-wide: a Decrypt grant can't be exercised
against a parameter the SSM grant doesn't cover, so the per-param ARN list
is the effective fence.

Considered and rejected: an explicit `Deny` on just this parameter atop the
wildcard (can't break a reader, but fail-_open_ for future parameters —
fixes the instance, not the class); relocating the token to a non-`/runtime/`
prefix (also fixes the class, but touches `vend-token.yml`, the dispatch
container, and `infra-dispatch-read`, and a third prefix muddies this ADR's
`/infra` vs `/runtime` split).
