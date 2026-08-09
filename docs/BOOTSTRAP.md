# Bootstrapping this repo from zero

The one-time sequence to get from "nothing exists" to a working
tofu-managed GitHub account with automated plan-on-PR and apply-on-merge.
Assumes a personal GitHub account (not an organization), a Cloudflare
account for the state backend, and an AWS account for the machine-secret
store (ADR-0010). Ongoing day-to-day workflow, once this is done, is
AGENTS.md's job — this doc only covers getting there once.

Follow it in order; later steps depend on earlier ones. The ordering has
one load-bearing subtlety: every local `tofu` run fetches its backend
secrets from SSM (`scripts/with-infra-secrets.sh`), so the SSM parameters
are hand-created with real values (§4) _before_ the first tofu command of
any kind, and the root module later adopts them (§6).

## 1. Tools and a Cloudflare R2 bucket

Install from Homebrew: `tenv`, `tflint`, `trivy`, `lefthook`, `just`,
`direnv`, and `awscli` (§4's parameter population and every wrapper-run
tofu use it). In Cloudflare's dashboard, create the state backend by
hand — this isn't tofu-managed yet (tracked as a known gap, see AGENTS.md):

- An R2 bucket named `tofu-state`.
- Two R2 API tokens scoped to that bucket: one **Object Read & Write**
  (local + CI apply) and one **Object Read only** (CI plan/drift). For
  each, the access key ID is the token's ID (shown at creation, or
  `GET /user/tokens/verify`); the S3 secret is derived from the token
  value by the consumers (`sha256`, ADR-0002) — record the raw values,
  they go into SSM in §4.
- A state encryption passphrase: `openssl rand -hex 32`, saved in a
  password manager. Losing it means every resource has to be re-imported,
  not recovered.

Clone this repo (or start a fresh one from it), copy
`.envrc.local.example` to `.envrc.local` and fill it (the backend values
do NOT go there — only SSM, §4), then `direnv allow` and
`lefthook install`.

## 2. Two GitHub credentials, minted up front

Both are described in full in AGENTS.md's Credentials section — this is
just the bootstrap-time checklist for creating them the first time.

- **Routine PAT** (fine-grained, github.com/settings/personal-access-tokens):
  Contents / Pull requests / Actions / Issues read-write, **not**
  Administration. (No Secrets/Variables scope — no `github_actions_secret`
  or `_variable` resource is tofu-managed, so no plan refresh needs it.)
  Put the value in `.envrc.local`'s `GH_TOKEN`.
- **Elevated session**: `gh auth login` with the full default scopes (or a
  classic PAT with `repo` + `delete_repo`), used only via
  `env -u GH_TOKEN -u GITHUB_TOKEN gh ...` / `just tofu-apply`. This is
  what creates repos, applies rulesets, and handles anything the routine
  PAT or a GitHub App can't reach (see AGENTS.md's Credentials section and
  ADR-0004's Consequences for exactly what those are).

## 3. Bootstrap the AWS account

The machine-secret store's trust roots (ADR-0010). Everything here runs as
the **root user in the console** — the bootstrap IAM user created at the
end is the account's first non-root credential.

- **Create the account**; root email and password go in the
  password-manager vault — human credentials, outside ADR-0010's
  machine-store scope. Enroll **hardware MFA** on root (IAM dashboard →
  root user → Security credentials → Assign MFA device). Never create a
  root access key — the bootstrap user below is the CLI credential.
- **Billing alarm**: Billing and Cost Management → Budgets → Create
  budget → the **Zero spend budget** template (alerts past $0.01),
  notifying the account email. This account should run at ~$0 — SSM
  Standard and IAM are free at this scale — so any spend is a signal,
  not a threshold to tune.
- **Region: `us-east-1`.** SSM parameters are regional, so the pick is
  recorded here once, not re-derived (ADR-0010): the nearest existing
  tooling is GitHub-hosted runners (US-based), and nothing else in this
  account has a location. `versions.tf` pins it as the `aws` provider's
  `region`.
- **Bootstrap IAM user**: IAM → Users → Create user `infra-bootstrap`,
  **no console access**, no group. Attach the inline policy below (name
  it `infra-bootstrap`), then create one access key (use case: CLI).
  Not `AdministratorAccess`: it can create the OIDC provider, the roles,
  the two tier keys, and the SSM parameters, but can't touch billing,
  root, users beyond the module's own, or its own permissions.

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "IamBootstrap",
        "Effect": "Allow",
        "Action": [
          "iam:CreateOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:CreateRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:CreateUser",
          "iam:GetUser",
          "iam:PutUserPolicy",
          "iam:GetUserPolicy",
          "iam:ListGroupsForUser",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:DeleteUser",
          "iam:DeleteUserPolicy",
          "iam:DeleteOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint"
        ],
        "Resource": "*"
      },
      {
        "Sid": "KmsBootstrap",
        "Effect": "Allow",
        "Action": "kms:*",
        "Resource": "*"
      },
      {
        "Sid": "SsmBootstrap",
        "Effect": "Allow",
        "Action": "ssm:*",
        "Resource": "*"
      }
    ]
  }
  ```

  The `iam:Get*`/`iam:List*` entries extend ADR-0010's write-action list:
  tofu reads back everything it creates on the next refresh, so the
  writes alone can't converge a plan. The `Update*`/`Delete*` entries are
  the same lesson one step later — tofu owns these resources' whole
  lifecycle, and a create-only list turns every trust-policy fix or
  refactor into another console round-trip (both learned from live 403s,
  not guessed). `kms:*` is on `Resource: "*"`
  because `kms:CreateKey` can't be scoped to a key ARN that doesn't
  exist yet — the two tier keys are the only keys this account will ever
  hold, so `*` covers exactly them; tighten to the two ARNs after the IAM
  module creates them if wanted.

- **Store the access key in the login Keychain, gated** — one item
  holding both halves:

  ```sh
  security add-generic-password -s infra-aws-bootstrap -a <ACCESS_KEY_ID> -w
  ```

  Paste the secret access key at the prompt; omitting `-A` is deliberate,
  so each read prompts. The key id is the item's account attribute
  (`security find-generic-password -s infra-aws-bootstrap | grep acct`);
  the secret comes back with `-w`. Local-only, never a GitHub secret.
  Once OIDC is confirmed working for every CI path (§10), **deactivate
  (don't delete)** the key — it stays as local break-glass, reactivated
  only for `just tofu-iam` runs, a standing audit item (ADR-0010's
  step 7).

## 4. Hand-populate the SSM parameters

Before any tofu: create the ten `/infra/*` parameters with the bootstrap
key — the wrapper (`scripts/with-infra-secrets.sh`) reads four of them for
every local run, including the very first `just tofu-iam init`. The values
you have now come from §1; the three that don't exist yet
(`gh-app-private-key` and the two `cloudflare-api-token*`) get the
literal `PLACEHOLDER` and are populated in §7-§9. `gh-admin-token` is the
fine-grained admin PAT (Administration/Issues/Variables read-write, all
repos — ADR-0013's spec); mint it at github.com → Settings → Developer
settings → Fine-grained tokens before this step, and note the 1-year
expiry: set a rotation reminder, since the failure mode is a 401
mid-apply. This is the
highest-risk manual step: a placeholder silently read
as the state passphrase fails state decryption, not loud (the wrapper and
CI both guard against the literal `PLACEHOLDER`, nothing can guard against
a wrong real-looking value). Values ride a 0600 mktemp file
(`--cli-input-json` can't read a pipe — verified against a live
ParamValidation error), never argv:

```sh
export AWS_SECRET_ACCESS_KEY="$(security find-generic-password -s infra-aws-bootstrap -w)"
export AWS_ACCESS_KEY_ID=<the item's acct attribute> AWS_REGION=us-east-1

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for param in gh-admin-token gh-app-private-key cloudflare-api-token \
  cloudflare-api-token-ro tf-state-passphrase \
  r2-account-id r2-plan-access-key-id r2-plan-storage-token \
  r2-apply-access-key-id r2-apply-storage-token; do
  # paste each real value when prompted (PLACEHOLDER where noted above);
  # ⚠ an R2 token value is the raw token, not Cloudflare's pre-hashed
  # Secret Access Key — consumers sha256 it (ADR-0002), and a key id and
  # its token must come from the same R2 token.
  printf '%s: ' "/infra/$param" >&2
  IFS= read -rs value && echo >&2
  jq -n --arg n "/infra/$param" --arg v "$value" \
    '{Name: $n, Type: "SecureString", KeyId: "alias/infra-secrets",
      Overwrite: true, Value: $v}' >"$tmp"
  aws ssm put-parameter --cli-input-json "file://$tmp" \
    --output text --query Version
done
```

Wait — `alias/infra-secrets` doesn't exist until §5's IAM apply. Chicken
and egg resolves in the other direction for a true from-zero run: create
these parameters **without** `KeyId` first (they encrypt under the
account's default `aws/ssm` key), then re-run this loop after §5 to
re-encrypt them under the tier key (`Overwrite: true` handles it), and
verify each with a decrypting read
(`aws ssm get-parameter --name /infra/<param> --with-decryption`).

## 5. Apply the IAM module, seed the identities

The trust roots as code (`iam/`, ADR-0010): the GitHub OIDC provider, the
CI roles (`infra-plan-read`, `infra-apply`, `infra-vend-write`), the local
users (`infra-local-apply`, `infra-local-read`), and the two tier keys
(`alias/infra-secrets`, `alias/runtime-secrets`).

- **Apply the bootstrap module** (Keychain prompt: `infra-aws-bootstrap`):

  ```sh
  just tofu-iam init
  just tofu-iam apply
  ```

- **Re-run §4's loop** now that `alias/infra-secrets` exists (see the
  chicken-and-egg note there), and verify one decrypting read of each.

- **Create the two local users' access keys** (console, as root: IAM →
  Users → the user → Security credentials → Create access key, use case
  CLI) and store them:

  ```sh
  # elevated: crown-jewel read/write, so NO -A — every read prompts
  security add-generic-password -s infra-aws-local-apply -a <ACCESS_KEY_ID> -w
  # routine: runtime tier only, silent reads are fine (-A) — this one
  # belongs to the consuming machine's dotfiles setup, see dotfiles'
  # AGENTS.md Credentials
  security add-generic-password -s infra-aws-local-read -a <ACCESS_KEY_ID> -A -w
  ```

- **Seed the role-ARN variables** the workflows assume (from
  `just tofu-iam output`), under the elevated session:

  ```sh
  env -u GH_TOKEN -u GITHUB_TOKEN gh variable set AWS_PLAN_ROLE_ARN   # plan_role_arn output
  env -u GH_TOKEN -u GITHUB_TOKEN gh variable set AWS_APPLY_ROLE_ARN  # apply_role_arn output
  env -u GH_TOKEN -u GITHUB_TOKEN gh variable set AWS_VEND_ROLE_ARN   # vend_role_arn output
  ```

## 6. First root apply — the governed repos and the parameter shells

Populate `repos.tf`'s `local.repos`/`local.labels` with whatever repos and
labels you're bringing under management. `ssm.tf` declares the eight
parameters §4 already created by hand, so adopt them with temporary
`import` blocks (`id` = the parameter name, e.g. `/infra/tf-state-passphrase`;
the repo's adopt-then-delete convention), then:

```sh
just tofu init
just tofu-apply
```

This creates/adopts `github_repository.this`, `github_issue_label.this`,
and `github_repository_ruleset.this` for every repo in the map, and brings
the parameters under management (existence and metadata only — values stay
hand-set, `ignore_changes = [value]`). Delete the spent `import` blocks.
Set `strict_required_status_checks_policy = true` on the ruleset **from
this first apply**, not later — it costs nothing this early (no
apply-on-merge pipeline exists yet to care about SHA drift), and
retrofitting it after CI automation is live means an extra manual
round-trip.

## 7. Register the GitHub App — with the full permission set at once

App registration has no tofu resource; it's a one-time manifest-flow
step at github.com/settings/apps/new. The important part: **grant every
permission category this setup will ever need in one pass**, since
adding one later means every existing installation has to separately
accept the update — a second manual step this bootstrap skips entirely
by front-loading it.

Repository permissions, all set to **write**:

- Issues, Pull requests, Contents, Actions, Administration

Leave Secrets and Variables alone — don't grant either. The App key lives
in SSM (ADR-0010), so no minted token ever refreshes a
`github_actions_secret`, and `github_actions_variable` is deliberately not
tofu-managed at all (§8 explains why) — the App never needs to touch
either category.

Uncheck **Active** under Webhooks (nothing here is event-driven), and set
**Where can this GitHub App be installed?** to **Only on this account**.

Capture all three outputs before moving on: the **App ID**, the
**Client ID** (what CI will actually use — see AGENTS.md's App bullet for
why Client ID over App ID), and the **private key** (`.pem`, shown once).
Populate `/infra/gh-app-private-key` with the `.pem` now — §4's loop shape,
one parameter.

## 8. Install the App, then propagate its credentials

- **Install it** on every repo from step 6
  (github.com/settings/installations → the App → Repository access →
  Only select repositories). Manual, permanently — the installation-repository
  API rejects fine-grained PATs and App tokens outright (confirmed against
  GitHub's own docs and a live 403; see `app.tf`'s top comment). A future
  new repo needs this same manual step, every time.
- **Set the client ID** as a plain repo variable — also manual, also
  permanent: `gh variable set GH_APP_CLIENT_ID --body <client id>`.
  `actions/create-github-app-token` has no permission input that could
  ever let a minted token refresh a `github_actions_variable` resource
  (confirmed against a live 422 and the tool's own open issue #231), so
  there's no path to making this tofu-managed today.

## 9. Cloudflare API token and the last variable

Create the least-privilege Cloudflare API token per
`.envrc.local.example`'s comment (Zone Read / DNS Edit / R2 Storage Edit),
put it in `.envrc.local`'s `CLOUDFLARE_API_TOKEN`, and populate
`/infra/cloudflare-api-token` with the same value (§4's loop shape).
Create a second, read-only token for CI's plan/drift jobs (#144) — same
custom-token flow, scopes Zone Read / DNS Read / R2 Storage Read, same
zone scoping — and populate `/infra/cloudflare-api-token-ro`. Seed
the account id: `env -u GH_TOKEN -u GITHUB_TOKEN gh variable set
CLOUDFLARE_ACCOUNT_ID`.

## 10. Bring in the CI workflows

Add `.github/actions/mint-app-token/`, `.github/actions/read-ssm-params/`,
and the `.github/workflows/tofu-*.yml` files. Open a PR touching only
these, confirm `tofu plan` posts a comment showing no unexpected drift
(this exercises `infra-plan-read` end to end), merge, and confirm
`tofu-apply.yml` completes automatically (`infra-apply`).

Then add `.github/workflows/vend-token.yml` and trigger it once via
`workflow_dispatch` — confirm it publishes a fresh `{token, expires_at}`
to `/runtime/vended-token` and that the minted token never appears
unmasked in the run log. Local shells (`dotfiles`#377) read from there.
Once every path is green, deactivate the bootstrap key (§3). From here on,
AGENTS.md's Branch & PR model and Credentials sections are the operating
manual, not this doc.

## What's still manual, permanently

Not a bootstrap-only list — these stay manual forever, for reasons
verified against GitHub's own docs and live behavior, not just today's
tooling gaps:

- Creating a **new** repo (App tokens can't call the repo-creation
  endpoint on a personal account).
- Installing the App on a new repo (the installation-repository API
  rejects every non-classic token type).
- Setting `GH_APP_CLIENT_ID` if it's ever lost (no App-minted token can
  refresh a `github_actions_variable` resource).
- Any App-manifest permission change plus its separate per-installation
  approval step.
- Every SSM parameter _value_ — hand-populated (§4), `ignore_changes`d;
  tofu manages existence and metadata only (ADR-0010).
- The AWS account scaffolding — account creation, root MFA, the
  zero-spend budget, the bootstrap IAM user, and every IAM user's access
  key + Keychain item. "Bootstrap key still deactivated, still needed"
  joins the periodic audit alongside the containment invariant
  (`iam/main.tf`'s header, ADR-0010 as amended by #126).

See AGENTS.md's Credentials section for the day-to-day version of this
list, and ADR-0004/ADR-0005 for the full reasoning behind the model.
