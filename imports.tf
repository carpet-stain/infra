# Temporary — adopts agents' GitHub-seeded default labels that collide
# with the canonical set. README's "Adding a repo" pattern (#177).
# Delete this file once `tofu apply` has run and a subsequent `tofu plan`
# shows zero diff.

import {
  for_each = toset([
    "bug",
    "documentation",
    "duplicate",
    "enhancement",
    "good first issue",
    "wontfix",
  ])

  to = github_issue_label.this["agents:${each.value}"]
  id = "agents:${each.value}"
}
