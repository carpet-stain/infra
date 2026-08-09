# Consuming secrets from another repo

For a contributor giving a **different** repo (not `infra`) its first secret,
or wiring one to fetch a secret at runtime. ADR-0010 records the design —
SSM Parameter Store, two KMS-fenced tiers, per-consumer IAM identities.
That's `infra`'s own decision record; this is the consumer-facing synthesis,
so it **points at** it rather than restating the reasoning. This doc answers
"which path, which identity, how do I fetch it, how do I get a new one."

## What a different repo actually gets today

One thing: **read access to the vended GitHub token** at
`/runtime/vended-token`. That token is a narrowly-scoped, rotating
credential (write on the managed repos with a live vended-token consumer,
no `administration` — `vend-token.yml`'s own comment is the current list
and why each repo is on it), republished every 5 minutes by
`vend-token.yml` on a best-effort basis — GitHub's `schedule:` trigger can
be delayed on public repos, so this is not a hard freshness guarantee
(ADR-0008's issue-76 amendment records the measurement; the store moved,
the cadence physics didn't). It exists precisely so a local or agent shell
in another repo can do routine cross-repo GitHub work without ever touching
the App's raw private key (#51; the live consumer is `dotfiles`#377).

## Which path — and why it's a security boundary

Access control is IAM-per-path with a KMS key per tier (ADR-0010): reading
a parameter needs both the SSM path grant and `kms:Decrypt` on that tier's
key — two independent fences.

| Path         | Holds                                                                            | Who can read it                                                    |
| ------------ | -------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `/infra/*`   | Crown jewels — the App private key, state passphrase, R2 creds, Cloudflare token | `infra`'s CI roles and its prompt-gated local identity — never you |
| `/runtime/*` | The rotating vended GitHub token                                                 | Any cross-repo consumer (`infra-local-read`)                       |

Don't ask for another repo's secret to land under `/infra/*` because it's
convenient — that tier is deliberately unreachable from any local/agent
shell (the audit invariant in `iam/main.tf`'s header), and widening a grant
on it to reach a lesser secret collapses the boundary that keeps the raw
App key out of those shells.

## Which identity you get

The **`infra-local-read`** IAM user — `ssm:GetParameter` on `/runtime/*`
plus `kms:Decrypt` on the runtime key, and nothing else. Its access key is
hand-created in the console and Keychain-stored with a silent-read ACL
(routine, not elevated — `dotfiles`' AGENTS.md Credentials has the setup).
`infra`'s CI roles and its local-apply/bootstrap users are not for reuse:
they hold crown-jewel or trust-root grants, the boundary the design
protects.

Unlike the Bitwarden era, there is **no account-cap scarcity** (ADR-0010):
a genuinely new consumer class gets its own IAM identity and path grant —
a design conversation and a PR, not a budget negotiation.

## Runtime recipes

`infra`'s own workflows and scripts are the reference implementations —
mirror them rather than reinventing.

### CI — OIDC, never a stored credential

A repo's own CI should not consume the vended token at all — it has the
ephemeral `github.token` and can mint what it needs. If a workflow in this
account genuinely needs an SSM value, the pattern is `infra`'s: a dedicated
IAM role trusting that repo's exact OIDC sub, `id-token: write` job-scoped,
`aws-actions/configure-aws-credentials`, then the fetch (see
`infra`'s `.github/actions/read-ssm-params` and `vend-token.yml`'s inline
single-parameter read). Never store an AWS access key as a GitHub secret
(#143 tracks enforcing this).

### Local / agent shell — `aws-vended-token`

Routine cross-repo work reads the vended token via `dotfiles`'
`aws-vended-token` (`dotfiles`' `scripts/aws-vended-token.sh`, on PATH from
its deploy): fetches `/runtime/vended-token` as `infra-local-read`, checks
`expires_at` in jq, prints the token or fails loud — generalize from it
rather than reinventing the parsing. Each repo's `.envrc` runs it at shell
entry and exports `GH_VENDED_TOKEN` (`dotfiles`#377).

**If a local secret is elevated, gate it in the Keychain.** Never export an
elevated credential ambiently into `.envrc.local` — direnv fires for
non-interactive agent shells too (`dotfiles`#160), so an ambient export is
reachable from every agent process. `infra`'s elevated local path is the
model: the `infra-aws-local-apply` key lives in the macOS login Keychain
added **without** an app ACL (no `-A`), so each read raises a prompt — an
interactive human clicks Allow, a silent agent attempt fails closed and
becomes a visible tripwire. See `scripts/with-infra-secrets.sh`,
`.envrc.local.example`'s setup block, and ADR-0010's #126 amendment for the
why. The vended token is _not_ elevated — it's the routine path and can
stay silent-read — but anything with a write grant or a crown-jewel scope
must be gated.

## Storing a genuinely new secret

Self-service in a way Bitwarden never was (ADR-0010): a new secret is a new
SSM parameter under the tier that fits its trust level, plus an IAM grant
for exactly its consumers.

- **Reuse the vended token if the need is GitHub API work** — that's what
  it's for.
- Otherwise: open an issue against `infra` proposing the parameter path and
  the consumer identity, then a PR — parameter metadata in `ssm.tf` (or a
  new `/runtime/<app>/*` path per ADR-0010's reserved convention), the
  role/user grant in `iam/`. The `iam/` change is applied by hand via
  `just tofu-iam` (bootstrap key, reactivated for the run) — never by CI,
  so no CI role can grant itself anything. Values are hand-populated
  (`docs/BOOTSTRAP.md`'s population pattern), never in config or state.

## Who to ask for a grant

The account holder — but unlike the Bitwarden grants, it's a reviewable PR
against `iam/`, not an invisible web-UI toggle: the role×path matrix is
code, and the periodic audit checks the live account against it (ADR-0010,
as amended by #126).
