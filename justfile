# Hand-maintained, not a copier overlay: this repo is a one-off (ADR-0002).
# Formerly split across justfile.base/justfile.lang to mirror
# project-starter-template's composable-overlay structure (ADR-0020 there);
# collapsed since infra never composes a second file in (#21).

# Run every pre-commit check (CI's lint job runs `just lint --tag base`;
# tofu.yml runs `just lint --tag lang`).
lint *args:
    lefthook run pre-commit --all-files {{ args }}

# Create a numbered ADR from the template: `just adr "Short decision title"`.
adr *args:
    scripts/new-adr.sh {{ args }}

# Auto-format markdown with prettier (fixes what md-format only checks).
# Manual, deliberately NOT a lefthook job: `just lint` (and CI's lint job) run
# `lefthook run pre-commit --all-files`, and `prettier --write` always exits 0
# — hooking it would make md-format stop gating format in CI (dotfiles#406).
# Scoped via git ls-files to tracked markdown only, mirroring md-format's
# excludes. Ported via project-starter-template#30 (#101).
format:
    git ls-files -z '*.md' ':!:CHANGELOG.md' ':!:.claude/agent-memory/**' | xargs -0 prettier --write

# Run OpenTofu (init, plan, state, ...). The backend passphrase + R2 creds are
# fetched from SSM at invocation via the Keychain-gated wrapper (#126,
# ADR-0010; the never-ambient rule is #59/ADR-0009) — expect one Keychain
# "Allow" prompt (infra-aws-local-apply). GITHUB_TOKEN comes from the
# routine GH_TOKEN alias (.envrc), unchanged.
tofu *args:
    scripts/with-infra-secrets.sh tofu {{ args }}

# The IAM/OIDC/KMS bootstrap module (ADR-0010): separate state in the same
# R2 bucket, applied only locally with the bootstrap key — never by CI.
# Same wrapper in --bootstrap mode (Keychain prompt: infra-aws-bootstrap);
# reactivate the break-glass key in the console first, deactivate after
# (docs/BOOTSTRAP.md). No GitHub token needed (no github provider in iam/).
tofu-iam *args:
    scripts/with-infra-secrets.sh --bootstrap tofu -chdir=iam {{ args }}

# Apply under the admin token fetched from gated SSM (ADR-0013) —
# mutations need Administration, which the routine GH_TOKEN deliberately
# lacks. One Keychain prompt covers backend secrets and admin token both.
tofu-apply *args:
    scripts/with-infra-secrets.sh --gh-admin tofu apply {{ args }}

# gcp/ (ADR-0024, #191): no AWS IAM/KMS in this module, so the routine
# --bootstrap-free wrapper is enough for the R2 backend creds — same
# Keychain prompt as `tofu`. GCP auth rides gcloud's Application Default
# Credentials (docs/BOOTSTRAP.md §17), not this script.
tofu-gcp *args:
    scripts/with-infra-secrets.sh tofu -chdir=gcp {{ args }}

# List recipes when invoked with no arguments.
_default:
    @just --list
