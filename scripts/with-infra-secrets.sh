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
# --gh-admin additionally fetches /infra/gh-admin-token and exports it as
# GITHUB_TOKEN (ADR-0013): `just tofu-apply` and the branch-protection
# bootstrap script ride it; plain `just tofu` deliberately doesn't, so a
# plan process never holds the admin token. Default identity only — the
# iam/ module has no github provider, so --bootstrap never needs it.
#
# usage: scripts/with-infra-secrets.sh [--bootstrap|--gh-admin] <command> [args...]
set -euo pipefail

item=infra-aws-local-apply
gh_admin=""
while [[ ${1:-} == --* ]]; do
  case $1 in
    --bootstrap) item=infra-aws-bootstrap ;;
    --gh-admin) gh_admin=1 ;;
    *)
      echo "with-infra-secrets: unknown flag '$1'" >&2
      exit 1
      ;;
  esac
  shift
done
if [[ -n $gh_admin && $item == infra-aws-bootstrap ]]; then
  echo "with-infra-secrets: --gh-admin and --bootstrap don't combine — iam/ has no github provider" >&2
  exit 1
fi

# Account attribute doesn't prompt; the secret (-w) does — the one gated
# read per item (docs/BOOTSTRAP.md).
aws_key_id="$(security find-generic-password -s "$item" | awk -F'"' '$2 == "acct" {print $4}')"
aws_secret="$(security find-generic-password -s "$item" -w)"
[[ -n "$aws_key_id" && -n "$aws_secret" ]] || {
  echo "with-infra-secrets: Keychain item '$item' missing or incomplete — see docs/BOOTSTRAP.md" >&2
  exit 1
}

# Batched GetParameters; jq -e fails closed on missing/null. These creds ride
# only this call's env — ambient AWS_* stays the R2 backend's (ADR-0010 §#126).
names=(/infra/tf-state-passphrase /infra/r2-apply-access-key-id
  /infra/r2-apply-storage-token /infra/r2-account-id
  /infra/b2-management-key-id /infra/b2-management-key
  /infra/cloudflare-api-token)
[[ -n $gh_admin ]] && names+=(/infra/gh-admin-token)
params="$(AWS_ACCESS_KEY_ID="$aws_key_id" AWS_SECRET_ACCESS_KEY="$aws_secret" \
  AWS_REGION=us-east-1 aws ssm get-parameters --with-decryption --output json \
  --names "${names[@]}")"
if [[ "$(jq -r '.InvalidParameters | length' <<<"$params")" != "0" ]]; then
  echo "with-infra-secrets: missing SSM parameters: $(jq -r '.InvalidParameters | join(" ")' <<<"$params")" >&2
  exit 1
fi
val() { jq -er --arg n "/infra/$1" 'first(.Parameters[] | select(.Name == $n) | .Value)' <<<"$params"; }

passphrase="$(val tf-state-passphrase)"
r2_key="$(val r2-apply-access-key-id)"
r2_token="$(val r2-apply-storage-token)"
r2_account="$(val r2-account-id)"
b2_key_id="$(val b2-management-key-id)"
b2_key="$(val b2-management-key)"
cf_token="$(val cloudflare-api-token)"
values=(passphrase r2_key r2_token r2_account b2_key_id b2_key cf_token)
if [[ -n $gh_admin ]]; then
  gh_admin_token="$(val gh-admin-token)"
  values+=(gh_admin_token)
fi

# Catches ssm.tf's placeholder or an empty value — either would otherwise
# silently sha256/encrypt into a wrong config (ADR-0010's step 4).
for name in "${values[@]}"; do
  [[ -n "${!name}" && "${!name}" != "PLACEHOLDER" ]] || {
    echo "with-infra-secrets: '$name' came back empty or PLACEHOLDER from SSM" >&2
    exit 1
  }
done

export TF_VAR_aws_access_key_id="$aws_key_id"
export TF_VAR_aws_secret_access_key="$aws_secret"

# The b2 provider's native env names (ADR-0017) — the SSM leaf is
# b2-management-key*, remapped here, same as CI's read-ssm-params remap.
export B2_APPLICATION_KEY_ID="$b2_key_id"
export B2_APPLICATION_KEY="$b2_key"

# The cloudflare provider's native env name — no ambient .envrc.local copy
# anymore (#171); this Keychain-gated fetch is now the token's only home.
export CLOUDFLARE_API_TOKEN="$cf_token"

# Sets GITHUB_TOKEN only (never GH_TOKEN) — gh-driving consumers still drop
# GH_TOKEN themselves; gh prefers it over GITHUB_TOKEN (AGENTS.md).
[[ -n $gh_admin ]] && export GITHUB_TOKEN="$gh_admin_token"

# Same derivation .envrc used before this moved out of it (ADR-0002): S3
# secret = sha256(token), endpoint carries account id, built by plain concatenation.
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
