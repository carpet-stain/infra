# 0011. GitHub Actions holds no stored Secret — Variables-only, values in SSM

Date: 2026-08-09

## Status

Accepted. Complements ADR-0010 (does not supersede).

## Context

ADR-0010 makes CI credential-less via OIDC and puts every machine secret in
SSM, but never states categorically that GitHub _Secrets_ are banned as a
store. Post-#119 the end-state is true by construction, not enforced — a
future workflow can re-add a Secret and quietly break it.

## Decision

GitHub Actions holds no repository/environment Secret except the built-in
`GITHUB_TOKEN`. Non-secret pointers (secret IDs, client IDs, project IDs)
live in GitHub **Variables**; every secret _value_ lives in SSM, read via an
IAM role. Enforced by #143's CI check (`scripts/check-workflow-secrets.sh`,
run as a lefthook `base` job).

## Alternatives considered

- **ADR-0010 + review only** — rejected: prose nobody enforces.
- **Ban `GITHUB_TOKEN` too** — rejected: it's the built-in, auto-scoped,
  per-job token every job uses.

## Consequences

New workflows route secrets through SSM+IAM; the check is the guardrail, the
ADR the walkable _why_.
