#!/usr/bin/env bash
# Run a command with infra's elevated backend secrets fetched from SSM at
# invocation — never exported ambiently into the shell (#59/ADR-0009 for the
# never-ambient rule, #126/ADR-0010 for the store). The state passphrase and
# R2 read/write credentials live in /infra/* SSM parameters, reached through
# an IAM access key in the macOS login Keychain that is deliberately NOT
# granted an app ACL entry — so each read prompts (gated): an interactive
# human clicks Allow, a non-interactive/agent shell fails closed. The prompt
# is the fence ADR-0010's #126 amendment names: no silently-readable local
# identity resolves kms:Decrypt on the crown-jewel tier.
#
# Two identities, one flag:
#   default      infra-aws-local-apply (Keychain: infra-aws-local-apply) —
#                routine root-module plans/applies.
#   --bootstrap  infra-bootstrap (Keychain: infra-aws-bootstrap) — the
#                break-glass key, for `just tofu-iam` only; reactivate it in
#                the console first (docs/BOOTSTRAP.md), deactivate after.
#
# usage: scripts/with-infra-secrets.sh [--bootstrap] <command> [args...]
set -euo pipefail

item=infra-aws-local-apply
if [[ ${1:-} == --bootstrap ]]; then
  item=infra-aws-bootstrap
  shift
fi

# The one gated read per item shape (infra-aws-bootstrap's precedent,
# docs/BOOTSTRAP.md): access key id rides the account attribute (attribute
# reads don't prompt), the secret is the password (-w prompts).
aws_key_id="$(security find-generic-password -s "$item" | awk -F'"' '$2 == "acct" {print $4}')"
aws_secret="$(security find-generic-password -s "$item" -w)"
[[ -n "$aws_key_id" && -n "$aws_secret" ]] || {
  echo "with-infra-secrets: Keychain item '$item' missing or incomplete — see docs/BOOTSTRAP.md" >&2
  exit 1
}

# One batched GetParameters, then pick by name. jq -e exits non-zero on a
# missing/null value, so set -e fails closed. Credentials ride only this
# call's environment — the ambient AWS_* names are claimed by the R2 backend
# below, and the aws provider gets these same values as explicit TF_VARs
# (the one slot that outranks the env chain).
params="$(AWS_ACCESS_KEY_ID="$aws_key_id" AWS_SECRET_ACCESS_KEY="$aws_secret" \
  AWS_REGION=us-east-1 aws ssm get-parameters --with-decryption --output json \
  --names /infra/tf-state-passphrase /infra/r2-apply-access-key-id \
  /infra/r2-apply-storage-token /infra/r2-account-id)"
if [[ "$(jq -r '.InvalidParameters | length' <<<"$params")" != "0" ]]; then
  echo "with-infra-secrets: missing SSM parameters: $(jq -r '.InvalidParameters | join(" ")' <<<"$params")" >&2
  exit 1
fi
val() { jq -er --arg n "/infra/$1" 'first(.Parameters[] | select(.Name == $n) | .Value)' <<<"$params"; }

passphrase="$(val tf-state-passphrase)"
r2_key="$(val r2-apply-access-key-id)"
r2_token="$(val r2-apply-storage-token)"
r2_account="$(val r2-account-id)"

# jq -e above fails closed on a missing name; this catches ssm.tf's shell
# placeholder or an empty value, either of which would otherwise
# sha256/encrypt into a silently-wrong config (docs/BOOTSTRAP.md's
# population step).
for name in passphrase r2_key r2_token r2_account; do
  [[ -n "${!name}" && "${!name}" != "PLACEHOLDER" ]] || {
    echo "with-infra-secrets: '$name' came back empty or PLACEHOLDER from SSM" >&2
    exit 1
  }
done

export TF_VAR_aws_access_key_id="$aws_key_id"
export TF_VAR_aws_secret_access_key="$aws_secret"

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
