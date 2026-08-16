# infra

GitHub account governance as code — repository settings, the canonical
label set, `protect main` rulesets, and least-privilege collaborator
grants for every repo in `repos.tf`'s map, managed with OpenTofu. The
stack (OpenTofu, R2-backed encrypted state, config-as-data) is ADR-0002;
the config originated in the dotfiles repo and moved here (its
ADR-0022/0024 record the founding decisions and the move).

## Install

Tools come from Homebrew: `tenv` (installs the OpenTofu version
`required_version` pins), `tflint` (via `terraform-linters/tap`), `trivy`,
`lefthook`, `just`, `direnv`, `awscli`. Log the routine dev PAT into gh's
keyring (`gh auth login --with-token` — #151; `.envrc` derives the env
copies from it), copy `.envrc.local.example` to `.envrc.local` and fill it
(Cloudflare identifiers only), store the `infra-local-apply` access key in
the login Keychain (gated — ADR-0010's #126 amendment), then `direnv allow`
and `lefthook install`.
Local `tofu` runs via `just`, which fetches the state passphrase + R2 creds
from SSM at invocation.

This assumes the account's R2 bucket, GitHub App, AWS account, and CI
variables already exist. Setting all of that up from nothing — a fresh GitHub account, no
state backend yet — is [`docs/BOOTSTRAP.md`](docs/BOOTSTRAP.md).

## Use

```sh
just tofu init          # once per checkout
just tofu plan          # routine scoped token — read-only
just tofu-apply         # admin token from gated SSM (ADR-0013)
```

Everything must run from inside the repo — direnv supplies the backend
credentials and the `TF_ENCRYPTION` block; state is client-side encrypted
before it reaches the R2 bucket. Losing `TF_STATE_PASSPHRASE` means
re-importing, not recovering (ADR-0002).

Adding a repo: an entry in `repos.tf`'s map — the next apply creates it
with labels and its ruleset. Gotcha: GitHub seeds a fresh repo with its
default labels, and the ones colliding with the canonical set (bug,
documentation, duplicate, enhancement, good first issue, wontfix) need
temporary `import` blocks; delete the four strays (help wanted, invalid,
question, accessibility) by hand. Adopting an existing repo: the map entry plus a
temporary `import` block (`id` = repo name; labels `repo:label`, rulesets
`repo:ruleset_id`), deleted once applied.

## Contributing

The contributor guide — workflow, commit rules, tooling, credentials — lives in
`AGENTS.md` (composed from your agent-config rules; generate it if it isn't
present yet). Architecture decisions live in
[`docs/adr/`](docs/adr/README.md). This README is the human front door and
points at those homes rather than restating them.

Giving a **different** repo a secret from this account's SSM store — which
path it belongs under, which credential it gets, how to fetch it at
runtime — is [`docs/CONSUMING-SECRETS.md`](docs/CONSUMING-SECRETS.md).
