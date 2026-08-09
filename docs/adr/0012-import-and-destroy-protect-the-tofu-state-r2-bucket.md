# 0012. Import and destroy-protect the tofu-state R2 bucket

Date: 2026-08-09

## Status

Accepted

## Context

The `tofu-state` R2 bucket holds this config's own state but was never
managed by it — created out-of-band at bootstrap, because it couldn't be in
the state it stores before it existed. That's the last hand-managed piece of
the backend (ADR-0002): no review trail, no reproducibility, drift from the
rest of `local.repos`' config-as-data story.

Adopting it is a genuine self-reference: `cloudflare_r2_bucket.tofu_state`'s
own state record lives inside the bucket the resource describes. Decided at
plan review (2026-08-08, #8): manage it anyway. The plumbing — the
`cloudflare` provider, the account-id variable, the read/edit token split
(#7/#144) — already exists from #121/#122; the marginal cost is one resource
plus this ADR, and it closes the backend's last manual piece.

## Decision

Import, don't create. `cloudflare.tf` adopts the live bucket via a temporary
`import` block (var-interpolated id, deleted once applied — no literal
account id lands in git history) and declares `lifecycle { prevent_destroy =
true }` so a plan that would replace or destroy it hard-errors instead of
silently recreating a bucket that holds this config's own encrypted state.

Two corrections against #8's original spec, found reading the vendored
`cloudflare/terraform-provider-cloudflare` v5.22.0 source directly rather
than trusting general Terraform ForceNew intuition:

- **Import id needs three segments, not two.** The resource's `ImportState`
  parses `<account_id>/<bucket_name>/<jurisdiction>` via a strict
  `ParseImportID` that errors on a segment-count mismatch
  (`internal/importpath/parse.go`) — #8's proposed
  `"${var.cloudflare_account_id}/tofu-state"` would fail outright. Fixed to
  `"${var.cloudflare_account_id}/tofu-state/default"`.
- **`location` is deliberately omitted, not set explicitly.** #8's B3
  worried that an omitted optional attribute reads as `null` against the
  API's real value and forces a replace. True in general, but not for this
  attribute in this provider version: `location`'s schema
  (`internal/services/r2_bucket/schema.go`) pairs `RequiresReplaceIfConfigured()`
  with a custom plan modifier that pins the planned value to prior state
  whenever state exists. Omitting `location` means the replace-trigger never
  fires (nothing configured to compare); setting it explicitly is the
  actually risky path — any mismatch between my guess and the real bucket
  triggers `RequiresReplaceIfConfigured` before the normalizer gets a
  chance to suppress the diff. `jurisdiction` and `storage_class` carry no
  such asymmetry (no forced-replace modifier either way), so both are
  pinned explicitly to the schema's own defaults (`"default"`,
  `"Standard"`) — matching what a console-created bucket already is, with
  nothing in this account's bootstrap history suggesting otherwise.

## Alternatives considered

- **Leave it hand-managed.** Rejected — the whole point of #6/#8: the one
  bucket holding this config's own state is also the one piece with no
  review trail, and the plumbing to manage it already exists.
- **Read `location`/`jurisdiction`/`storage_class` from a live `tofu state
show` and hardcode all three, per #8's literal text.** Rejected for
  `location` specifically once the schema read showed an explicit value is
  the riskier path, not the safer one (see Decision). Kept for
  `jurisdiction`/`storage_class`, where explicit and safe coincide.
- **`state rm` + manual re-`import` via CLI instead of a config `import`
  block.** Rejected — not reviewable as a plan, and this repo's stated
  convention (ADR-0002, README's "Adopting an existing repo") is declarative
  `import {}` blocks over state surgery.

## Consequences

`prevent_destroy` blocks only the tofu path — a Cloudflare-console delete, a
direct R2-API call, or `tofu state rm` followed by a real delete all bypass
it entirely. It's a footgun guard against an accidental `tofu destroy` or a
plan that resolves to a replace, not a backup.

Recovery from an actual bucket loss is re-bootstrap, the same ADR-0002
stance already governs: recreate the bucket out-of-band, re-import,
`TF_STATE_PASSPHRASE` loss already means "re-import everything," not
"unrecoverable." R2 versioning would be the real DR control for accidental
object overwrite/delete inside the bucket, but it's a manual, code-unmanaged
R2 setting outside `cloudflare_r2_bucket`'s schema — **recommended, not
confirmed enabled and not enforced by this config**; verify it by hand in
the R2 dashboard rather than trusting this ADR's word for it.

`account_id` is non-secret (an identifier, not a credential) but is
account-identifying, so its transit through the encrypted state and the
saved-plan artifact (ADR-0007 — a public-repo Actions artifact) is an
accepted defense-in-depth boundary, not a hard guarantee: git history stays
clean of it (the import block interpolates the variable), but state and the
plan artifact are not git history and were never claimed to be.

The `cloudflare` provider now configures on every plan context, not just
zero-resource no-ops — a Dependabot action-bump PR's `tofu-plan` run
exercises it too. No `paths:` guard was added to skip that case; #8 flagged
it as optional and the read-only token (#144) already makes that run cheap
and safe.
