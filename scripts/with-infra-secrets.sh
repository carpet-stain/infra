#!/usr/bin/env bash
# Run a command with infra's elevated backend secrets fetched from Bitwarden
# at invocation — never exported ambiently into the shell (#59, ADR-0009).
# The state passphrase and R2 read/write credentials used to live as plaintext
# in .envrc.local, exported by direnv to every shell that entered this repo,
# agent shells included (the dotfiles#160 exposure the epic exists to close).
# Now they live only in Bitwarden's `infra` Project, reached through an
# infra-read machine-account token in the macOS login Keychain that is
# deliberately NOT granted an app ACL entry — so each read prompts (gated): an
# interactive human clicks Allow, a non-interactive/agent shell fails closed.
#
# usage: scripts/with-infra-secrets.sh <command> [args...]   (see justfile)
set -euo pipefail

: "${TF_VAR_bws_infra_project_id:?set in .envrc.local — the infra Bitwarden Project UUID}"

# The one gated line: the machine-account token, behind the Keychain ACL (no
# -A when it was added), so this prompts interactively and errors with no TTY.
bws_token="$(security find-generic-password -s infra-bws -w)"
[[ -n "$bws_token" ]] || {
  echo "with-infra-secrets: empty Keychain item 'infra-bws' — run the setup in .envrc.local.example" >&2
  exit 1
}

# The provider reads BW_*, the `bws` CLI reads BWS_* — same token, both homes
# (the two-prefix trap the repo flags everywhere).
export BW_ACCESS_TOKEN="$bws_token"
export BWS_ACCESS_TOKEN="$bws_token"

# One list call, then pick by key — no per-secret UUID to track locally.
# jq -e exits non-zero on a missing/null value, so set -e fails closed here.
# --color no: bws ≥2.x syntax-highlights JSON even into a pipe, which jq
# rejects as garbage — force it off rather than trust TTY detection.
secrets="$(bws secret list "$TF_VAR_bws_infra_project_id" --output json --color no)"
val() { jq -er --arg k "$1" 'first(.[] | select(.key == $k) | .value)' <<<"$secrets"; }

passphrase="$(val TF_STATE_PASSPHRASE)"
r2_key="$(val R2_APPLY_ACCESS_KEY_ID)"
r2_token="$(val R2_APPLY_STORAGE_TOKEN)"
r2_account="$(val R2_ACCOUNT_ID)"

# jq -e above fails closed on a missing key; this catches a present-but-empty
# value, which would otherwise sha256/encrypt into a silently-wrong config.
for name in passphrase r2_key r2_token r2_account; do
  [[ -n "${!name}" ]] || {
    echo "with-infra-secrets: '$name' came back empty from Bitwarden" >&2
    exit 1
  }
done

# The AWS bootstrap/break-glass key (ADR-0010, docs/BOOTSTRAP.md §9) — the
# second gated Keychain item: access key id rides the account attribute,
# the secret is the password (only the -w read prompts). Fed to the aws
# provider as explicit TF_VARs, never AWS_* env: those names carry the R2
# backend credentials below, and explicit provider config is the one slot
# that outranks the env chain.
aws_bootstrap_key_id="$(security find-generic-password -s infra-aws-bootstrap | awk -F'"' '$2 == "acct" {print $4}')"
aws_bootstrap_secret="$(security find-generic-password -s infra-aws-bootstrap -w)"
[[ -n "$aws_bootstrap_key_id" && -n "$aws_bootstrap_secret" ]] || {
  echo "with-infra-secrets: Keychain item 'infra-aws-bootstrap' missing or incomplete — see docs/BOOTSTRAP.md §9" >&2
  exit 1
}
export TF_VAR_aws_access_key_id="$aws_bootstrap_key_id"
export TF_VAR_aws_secret_access_key="$aws_bootstrap_secret"

# Derive the R2 S3 pair, endpoint, and enforced encryption exactly as .envrc
# did before these moved out of it (ADR-0002): the S3 secret is sha256 of the
# token value, the endpoint carries the account id, and TF_ENCRYPTION is built
# by plain concatenation so no key material lands in a tracked file.
export AWS_ACCESS_KEY_ID="$r2_key"
AWS_SECRET_ACCESS_KEY="$(printf '%s' "$r2_token" | shasum -a 256 | cut -d' ' -f1)"
export AWS_SECRET_ACCESS_KEY
export AWS_ENDPOINT_URL_S3="https://${r2_account}.r2.cloudflarestorage.com"
export TF_ENCRYPTION='
key_provider "pbkdf2" "state" {
  passphrase = "'"$passphrase"'"
}
method "aes_gcm" "state" {
  keys = key_provider.pbkdf2.state
}
state {
  method   = method.aes_gcm.state
  enforced = true
}
plan {
  method   = method.aes_gcm.state
  enforced = true
}'

exec "$@"
