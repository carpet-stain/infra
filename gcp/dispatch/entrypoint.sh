#!/usr/bin/env sh
# Reads AWS_ROLE_ARN from the Job's env (gcp/main.tf). Every other
# credential is minted fresh each run — nothing persists, nothing is
# logged (ADR-0024, #191). Response bodies are only printed on a
# non-success status, and never for a call whose success body is itself
# a bearer credential (the metadata token, the dispatch token).
set -eu

echo "requesting a GCP identity token from the metadata server"
token_file=$(mktemp)
trap 'rm -f "$token_file"' EXIT
http_code=$(curl -sS -w '%{http_code}' -o "$token_file" \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=sts.amazonaws.com")
if [ "$http_code" != "200" ]; then
  echo "metadata server identity request failed: HTTP ${http_code}" >&2
  cat "$token_file" >&2
  exit 1
fi

# aws-cli's native web-identity credential provider — the same mechanism
# aws-actions/configure-aws-credentials uses for GitHub's OIDC token, fed a
# GCP-issued one instead (iam/main.tf's infra-dispatch-read role).
echo "assuming infra-dispatch-read via AWS web identity federation"
export AWS_WEB_IDENTITY_TOKEN_FILE="$token_file"
export AWS_ROLE_ARN
export AWS_ROLE_SESSION_NAME="cloud-run-dispatch"
export AWS_DEFAULT_REGION="us-east-1"

echo "reading /runtime/infra-dispatch-token"
dispatch_token=$(aws ssm get-parameter --name /runtime/infra-dispatch-token \
  --with-decryption --query Parameter.Value --output text)

echo "dispatching vend-token.yml"
status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
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
