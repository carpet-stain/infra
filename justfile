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

# Run OpenTofu (init, plan, state, ...). The backend passphrase + R2 creds are
# fetched from Bitwarden at invocation via the Keychain-gated wrapper (#59,
# ADR-0009) — expect a Keychain "Allow" prompt — not exported ambiently.
# GITHUB_TOKEN comes from the routine GH_TOKEN alias (.envrc), unchanged.
tofu *args:
    scripts/with-infra-secrets.sh tofu {{ args }}

# Apply under the elevated session token — mutations need Administration,
# which the routine GH_TOKEN deliberately lacks — with the same
# Keychain-gated backend-secret fetch wrapped around it.
tofu-apply *args:
    scripts/with-infra-secrets.sh env GITHUB_TOKEN="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token)" tofu apply {{ args }}

# List recipes when invoked with no arguments.
_default:
    @just --list
