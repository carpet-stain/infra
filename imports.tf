# Temporary — adopts deal-finder's GitHub-seeded default labels that
# collide with the canonical set (#75). README's "Adding a repo" pattern.
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

  to = github_issue_label.this["deal-finder:${each.value}"]
  id = "deal-finder:${each.value}"
}
