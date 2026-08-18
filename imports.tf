# Temporary — adopts agent-memory-server's GitHub-seeded default labels
# that collide with the canonical set. README's "Adding a repo" pattern.
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

  to = github_issue_label.this["agent-memory-server:${each.value}"]
  id = "agent-memory-server:${each.value}"
}
