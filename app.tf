# GitHub App credential propagation — registration and installation
# membership are both manual, UI-only steps; see AGENTS.md's Credentials
# section (ADR-0004) for why and #29/#30 for the bootstrap record.

# The App's private key lives in SSM at /infra/gh-app-private-key (ssm.tf,
# ADR-0010) — its former Bitwarden home (ADR-0008) is fully decommissioned.

# Superseded by the SSM-stored key above (#47) — destroy=false forgets
# management without an API call; the native secret was deleted by hand.
removed {
  from = github_actions_secret.app_private_key

  lifecycle {
    destroy = false
  }
}

# Not tofu-managed: no App-minted token can refresh a github_actions_variable
# (AGENTS.md's Structure section). Set by hand if missing (ADR-0013).
removed {
  from = github_actions_variable.app_client_id

  lifecycle {
    destroy = false
  }
}
