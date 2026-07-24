# Consuming secrets from another repo

For a contributor giving a **different** repo (not `infra`) its first secret,
or wiring one to fetch a secret at runtime. ADR-0008 and ADR-0009 record the
design — two Projects, three Machine Accounts, why the split is load-bearing,
how `infra` itself consumes it. Those are `infra`'s own decision records; this
is the consumer-facing synthesis, so it **points at** them rather than
restating the reasoning. Read ADR-0008 for the store's shape and ADR-0009 for
the runtime-fetch model; this doc answers "which Project, which account, how do
I fetch it, who do I ask."

## What a different repo actually gets today

One thing: **read access to the vended GitHub token** in the `vended-tokens`
Project. That token is a narrowly-scoped, rotating credential
(`{contents, issues, pull_requests}: write`, no `administration`, over the
managed repos except `infra` itself), republished every 20 minutes by
`vend-token.yml`. It exists precisely so a local or agent shell in another repo
can do routine cross-repo GitHub work without ever touching the App's raw
private key (ADR-0008; the live consumer is `dotfiles`#377).

It does **not** get a place to store its own arbitrary new secret. See
[Storing a genuinely new secret](#storing-a-genuinely-new-secret) — under the
current grant structure that is not self-service, and inventing ad hoc storage
(a literal in `.envrc.local`, a native CI secret) is the exact anti-pattern
ADR-0008/0009 exist to close.

## Which Project — and why it's a security boundary

Bitwarden access control is **Project-granular only**: a Machine Account holds
read (or read/write) on a whole Project, so anything a credential can reach a
Project for, it can read _every_ secret in that Project for (ADR-0008). The
Project a secret lives in is therefore a security boundary, not organization.

| Project         | Holds                                                                            | Who can read it                                                 |
| --------------- | -------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `infra`         | Crown jewels — the App private key, state passphrase, R2 creds, Cloudflare token | `infra` CI and (Keychain-gated) `infra`'s own local `tofu` only |
| `vended-tokens` | The one rotating vended GitHub token                                             | Any cross-repo consumer (the Local account)                     |

Don't put another repo's secret in `infra` because it's convenient — that
Project is deliberately unreachable from any local/agent shell, and widening a
grant on it to reach a lesser secret collapses the boundary that keeps the raw
key out of those shells. See ADR-0008's Machine-Account-to-Project grant table
(mirrored in `AGENTS.md` as the auditable spec) for the exact grants.

## Which Machine Account you get

The **Local** account — `read` on `vended-tokens`, and nothing else. That is
the only account available to cross-repo work; `infra`'s CI and Vending
accounts are not for reuse (they hold write grants on `infra`, the boundary the
whole design protects).

You cannot get a new dedicated account. The free tier caps at **three** Machine
Accounts and all three are in use (ADR-0008) — no headroom. So a new consumer
either reuses the vended path above or triggers a design conversation, not a
self-service grant (below).

## Runtime recipes

The general fetch pattern, shown with the vended token as the concrete secret
you can read today. `infra`'s own workflows and `scripts/with-infra-secrets.sh`
are the reference implementations — mirror them.

### CI — `bitwarden/sm-action`

Store the Local machine-account token as a native Actions secret
(`BWS_ACCESS_TOKEN`) and the vended secret's UUID as a non-secret variable
(`BWS_VENDED_SECRET_ID` — a UUID identifies a secret, it grants nothing on its
own, so it's a variable not a secret). Pin the action by SHA, keep the fetched
value a step output (`set_env: false`), and let `sm-action` mask it:

```yaml
- name: Read vended token from Bitwarden
  id: bw
  uses: bitwarden/sm-action@1238aae8fc64b212641190a9227c8a734ab1a793 # v3.0.1
  with:
    access_token: ${{ secrets.BWS_ACCESS_TOKEN }}
    set_env: false
    secrets: |
      ${{ vars.BWS_VENDED_SECRET_ID }} > VENDED

# steps.bw.outputs.VENDED is the {token, expires_at} JSON — parse .token
```

In practice a repo's own CI rarely needs the vended token — it already has the
ephemeral `github.token` and can mint its own. The recipe matters when you've
been granted read on a secret of your own; the shape is identical, only the
`access_token` and secret UUID change. See `tofu-plan.yml`'s `sm-action` step
for the same pattern reading the `infra` Project.

### Local / agent shell — `bws`

Routine cross-repo work reads the vended token with the `bws` CLI, using the
Local machine-account token, and parses the `.token` field out of the
`{token, expires_at}` JSON. `dotfiles`#377/#388 is the live implementation of
this — generalize from it rather than reinventing the parsing.

**If a local secret is elevated, gate it in the Keychain.** Never export an
elevated credential ambiently into `.envrc.local` — direnv fires for
non-interactive agent shells too (`dotfiles`#160), so an ambient export is
reachable from every agent process. `infra`'s own elevated local path is the
model: the machine-account token lives in the macOS login Keychain added
**without** an app ACL (no `-A`), so each read raises a prompt — an interactive
human clicks Allow, a silent agent attempt fails closed and becomes a visible
tripwire. See `scripts/with-infra-secrets.sh`, `.envrc.local.example`'s setup
block, and ADR-0009 for the why. The vended token is _not_ elevated — it's the
routine path and can stay ambient — but anything with a write grant or a
crown-jewel scope must be gated.

## Storing a genuinely new secret

Not supported self-service today, and that's a deliberate consequence of the
three-account cap, not an oversight. A new secret readable by a different repo
needs a Machine Account with a grant on the Project it lives in — but every
account is spoken for, and widening an existing grant to a new consumer erodes
the CI-vs-local boundary the design rests on (ADR-0008).

So before storing anything new: **reuse the vended token if the need is GitHub
API work**, or **open an ADR-0008-consequences discussion** (an issue against
`infra`) if it genuinely isn't — the fix is a design decision about the
account budget (e.g. merging the two CI-side accounts to free one, per
ADR-0008's own Consequences), recorded as it's made.

## Who to ask for a grant

The account holder, by hand. The Machine-Account-to-Project grants are the
actual security boundary and the Terraform provider has no resource for them
(ADR-0008) — so adding or changing a grant is a manual step in Bitwarden's web
UI, never a PR against `infra` and never self-service. File an issue against
`infra` describing what the consuming repo needs and why; the grant is made
manually and the live state is audited against `AGENTS.md`'s grant table
afterward, since nothing else enforces it.
