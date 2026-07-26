# Temporary — adopts the pre-existing golden-ratio-dual-gate repo and its
# GitHub-seeded default labels that collide with the canonical set (#22).
# README's "Adopting an existing repo" pattern. Delete this file once
# `tofu apply` has run and a subsequent `tofu plan` shows zero diff.

import {
  to = github_repository.this["golden-ratio-dual-gate"]
  id = "golden-ratio-dual-gate"
}

import {
  for_each = toset([
    "bug",
    "documentation",
    "duplicate",
    "enhancement",
    "good first issue",
    "wontfix",
    "epic",
    "spike",
    "priority: high",
    "priority: medium",
    "priority: low",
  ])

  to = github_issue_label.this["golden-ratio-dual-gate:${each.value}"]
  id = "golden-ratio-dual-gate:${each.value}"
}
