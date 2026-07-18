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
