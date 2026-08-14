# 0002. OpenTofu with R2-backed encrypted state, config-as-data

Date: 2026-07-18

## Status

Accepted

## Context

This repo owns GitHub account governance as code: repository settings, the
canonical label set, and `protect main` rulesets for every managed repo.
The config was born inside the dotfiles repo — its ADR-0022 records the
full decision spike with evidence and rejected alternatives, and its
ADR-0024 records why the config moved here (governance out of a
workstation-config repo, the TF credential surface with it) and why there
is no reusable template behind this repo. This ADR restates the foundations
in the repo that now owns them, so its stack is walkable without the
dotfiles history.

The binding constraint from the spike still governs everything: state is a
plaintext secret store (`github_actions_secret`'s value is
sensitive-marked but not hidden from state, and RELEASE_PAT management is
planned), so encryption-at-rest is a requirement, not a preference.

## Decision

- **OpenTofu** (1.12.x line), pinned by `required_version` and installed on
  demand by tenv; Terraform is BUSL and lacks client-side state encryption.
- **Single flat config, data-driven**: one root module, `for_each` over the
  repos map in `repos.tf` — routine changes edit data, not resource logic.
  No Terragrunt, no modules until a real reuse boundary exists.
- **State: Cloudflare R2** (`tofu-state` bucket) with native lockfile
  locking (`use_lockfile`), plus **enforced client-side encryption**
  (`aes_gcm` + PBKDF2) assembled by `.envrc` from a single passphrase in
  `.envrc.local`. S3 credentials derive from the R2 API token (access key =
  token ID, secret = SHA-256 of the full token value); the endpoint carries
  the account ID via env, keeping it out of this public repo.
- **Two-tier auth**: the routine scoped token plans; applies run under the
  elevated keyring session (`just tofu-apply`), never in CI.
- **Refactors are declarative**: `import` blocks to adopt, `moved` blocks
  to re-key (the migration PR's own address moves are the worked example),
  state surgery as last resort. Both are spent once applied and deleted
  rather than merged.

## Alternatives considered

The spike's full matrix lives in dotfiles ADR-0022; the short form of what
was rejected and why: **Terraform** (BUSL, no client-side encryption),
**Terragrunt** (multi-env/account machinery at single-account scale),
**HCP Terraform** (free tier EOL'd, OpenTofu unsupported, encryption
incompatible with the `cloud` block), **Backblaze B2** (no conditional
writes ⇒ no locking), **AWS S3** (account + IAM surface for pennies R2
doesn't charge), **Scalr** (TACOS overhead for a solo config). For this
repo specifically, a **copier overlay/template** behind it was rejected in
dotfiles ADR-0024 — a one-off repo is bootstrapped once, not templated.

## Consequences

Governance changes are map edits reviewed as diffs, applied deliberately by
a human with the elevated credential. Encrypted state is OpenTofu-only —
moving back to Terraform requires decrypting first. Losing the passphrase
loses the state but not the world: every managed resource re-imports.
Rulesets require GitHub Pro on private repos, so every repo in the map is
public today — revisit if a private repo needs protection. Spent `import`/`moved`
blocks are deleted once applied — the PR journal is their record.

## Amendment — #88 (2026-07-27): the read-tier plan token forces two `ignore_changes` classes

`github_repository.this`'s merge-setting attributes (`squash_merge_commit_title`,
`squash_merge_commit_message`, `allow_auto_merge`, `allow_rebase_merge`,
`delete_branch_on_merge`, `merge_commit_title`, `merge_commit_message`) are
`ignore_changes`d, for two different reasons that read the same from the diff but
aren't:

- **`squash_merge_commit_title`/`squash_merge_commit_message`** are inert while
  squash-merge is off, and GitHub's create API stores its own defaults for them
  regardless of what's sent — pinning them makes every fresh repo drift once.
  Unmanaged on principle, independent of #59.
- **The other five** are a consequence of #59's plan-token narrowing (AGENTS.md's
  Credentials section): `tofu-plan.yml`'s `administration:read`-scoped token gets
  `GET /repos` back with every merge-setting field omitted — confirmed empirically
  against this exact App-token config, not just read from GitHub's docs. The
  provider then diffs `null` against these `true`/`true`/`true` config values on
  every single PR, a permanent 3-change floor with no real drift underneath. No
  read-tier permission fixes this: granting the plan token write access would
  defeat #59's whole point (a compromised plan step could then rewrite repo
  settings). Unmanaged past initial creation; the `protect main` ruleset's
  `allowed_merge_methods = ["rebase"]` is the actual rebase-only enforcement, a
  harder gate than these convenience toggles ever were.

Revisit only if GitHub's read-scoped `GET /repos` response ever includes these
fields, or if #59's plan-token tier changes.
