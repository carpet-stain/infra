#!/usr/bin/env bash
# Fails on any `secrets.<name>` reference in a workflow other than the
# built-in GITHUB_TOKEN. Why: ADR-0011 — GitHub Actions holds no stored
# Secret; secret values live in SSM read via an IAM role, non-secret
# pointers in Variables. Runs as a lefthook base job (`just lint` locally,
# lint.yml in CI).
#
# usage: scripts/check-workflow-secrets.sh [workflow.yml ...]
set -euo pipefail

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  files=(.github/workflows/*.yml)
fi

rc=0
for f in "${files[@]}"; do
  # Matches the name pattern anywhere, comments included — a comment naming
  # a specific stored secret is stale prose worth flagging too. Prose like
  # "secrets.*" doesn't match.
  while read -r name; do
    if [[ $name != "secrets.GITHUB_TOKEN" ]]; then
      echo "error: $f references $name — Actions holds no stored Secret (ADR-0011); put the value in SSM, non-secret pointers in Variables" >&2
      rc=1
    fi
  done < <(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' "$f" || true)
done
exit $rc
