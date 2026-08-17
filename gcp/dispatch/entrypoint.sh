#!/usr/bin/env sh
# Reads AWS_ROLE_ARN from the Job's env (gcp/main.tf). Every other
# credential is minted fresh each run — nothing persists, nothing is
# logged (ADR-0024, #191).
set -eu

# The metadata server mints this service account's own OIDC identity
# token — no key material anywhere (gcp/main.tf's cloud-run-dispatch SA
# needs no extra grant to speak as itself).
gcp_token=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=sts.amazonaws.com")

token_file=$(mktemp)
trap 'rm -f "$token_file"' EXIT
printf '%s' "$gcp_token" >"$token_file"

# aws-cli's native web-identity credential provider — the same mechanism
# aws-actions/configure-aws-credentials uses for GitHub's OIDC token, fed a
# GCP-issued one instead (iam/main.tf's infra-dispatch-read role).
export AWS_WEB_IDENTITY_TOKEN_FILE="$token_file"
export AWS_ROLE_ARN
export AWS_ROLE_SESSION_NAME="cloud-run-dispatch"
export AWS_DEFAULT_REGION="us-east-1"

dispatch_token=$(aws ssm get-parameter --name /runtime/infra-dispatch-token \
  --with-decryption --query Parameter.Value --output text)

status=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer ${dispatch_token}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/carpet-stain/infra/actions/workflows/vend-token.yml/dispatches" \
  -d '{"ref":"main"}')

if [ "$status" != "204" ]; then
  echo "workflow_dispatch failed: HTTP ${status}" >&2
  exit 1
fi

echo "dispatched vend-token.yml (HTTP ${status})"
