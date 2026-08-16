# GitHub API-level governance for the repos in local.repos — repository
# settings, labels, branch rulesets. Working-tree files stay each repo's
# own; this boundary and the whole stack are recorded in ADR-0002 (and in
# the source repo's ADR-0022/0024, where this config originated).

# Visibility is deliberate per-repo data (dotfiles is public on purpose),
# so trivy's blanket repos-should-be-private check doesn't apply.
#trivy:ignore:GIT-0001
resource "github_repository" "this" {
  for_each = local.repos

  name         = each.key
  description  = each.value.description
  visibility   = each.value.visibility
  topics       = each.value.topics
  has_issues   = each.value.has_issues
  has_projects = each.value.has_projects
  has_wiki     = each.value.has_wiki

  has_discussions  = each.value.has_discussions
  allow_auto_merge = each.value.allow_auto_merge

  # Create-time only — see the agents entry for why a new repo needs it.
  # Defaults to null, not false, so entries without the key stay diff-free.
  auto_init = lookup(each.value, "auto_init", null)

  # Rebase-merge-only discipline: invariant for every managed repo, so
  # fixed here rather than per-repo data.
  allow_merge_commit     = false
  allow_squash_merge     = false
  allow_rebase_merge     = true
  delete_branch_on_merge = true
  allow_update_branch    = false

  web_commit_signoff_required = false

  # Security by default for every managed repo.
  vulnerability_alerts = true

  # Destroying a managed repo archives it instead of deleting it — removal
  # from the map must never be able to destroy history.
  archive_on_destroy = true

  lifecycle {
    # Two different reasons behind one list, both unmanaged on purpose —
    # see ADR-0002's #88 amendment for the read-tier plan-token finding.
    ignore_changes = [
      squash_merge_commit_title,
      squash_merge_commit_message,
      allow_auto_merge,
      allow_rebase_merge,
      delete_branch_on_merge,
      merge_commit_title,
      merge_commit_message,
    ]
  }
}

# The canonical label set on every managed repo, keyed "repo:label".
resource "github_issue_label" "this" {
  for_each = {
    for pair in setproduct(keys(local.repos), keys(local.labels)) :
    "${pair[0]}:${pair[1]}" => { repo = pair[0], label = pair[1] }
  }

  repository  = github_repository.this[each.value.repo].name
  name        = each.value.label
  color       = local.labels[each.value.label].color
  description = local.labels[each.value.label].description

  lifecycle {
    precondition {
      # No lint catches this — the API 422s at apply time otherwise, one
      # label at a time, across every managed repo.
      condition     = length(local.labels[each.value.label].description) <= 100
      error_message = "GitHub caps label descriptions at 100 characters: \"${each.value.label}\" is ${length(local.labels[each.value.label].description)}."
    }
  }
}

# Deliberation-agent collaborator grants — see #172/ADR-0035. Push-prevention
# is structural (main branch protection), not a withheld role.
resource "github_repository_collaborator" "this" {
  for_each = {
    for pair in setproduct(keys(local.repos), keys(local.collaborators)) :
    "${pair[0]}:${pair[1]}" => { repo = pair[0], username = pair[1] }
  }

  repository = github_repository.this[each.value.repo].name
  username   = each.value.username
  permission = local.collaborators[each.value.username].permission
}

# Repo-specific labels (#13, #106, repos.tf's repo_labels) — outside the
# canonical for_each above so they don't land on every managed repo.
resource "github_issue_label" "repo_only" {
  for_each = {
    for pair in flatten([
      for repo, labels in local.repo_labels : [
        for name, attrs in labels : merge(attrs, { key = "${repo}:${name}", repo = repo, name = name })
      ]
    ]) : pair.key => pair
  }

  repository  = github_repository.this[each.value.repo].name
  name        = each.value.name
  color       = each.value.color
  description = each.value.description

  lifecycle {
    precondition {
      condition     = length(each.value.description) <= 100
      error_message = "GitHub caps label descriptions at 100 characters: \"${each.value.name}\" is ${length(each.value.description)}."
    }
  }
}

# Reattach state to the renamed/generalized resource (#106) — a plain rename
# would delete each label from its repo for one apply cycle before recreating it.
moved {
  from = github_issue_label.infra_only["theme: cloudflare"]
  to   = github_issue_label.repo_only["infra:theme: cloudflare"]
}

moved {
  from = github_issue_label.this["infra:tofu-drift"]
  to   = github_issue_label.repo_only["infra:tofu-drift"]
}

moved {
  from = github_issue_label.this["dotfiles:release-watch"]
  to   = github_issue_label.repo_only["dotfiles:release-watch"]
}

moved {
  from = github_issue_label.this["dotfiles:theme: tool-review"]
  to   = github_issue_label.repo_only["dotfiles:theme: tool-review"]
}

moved {
  from = github_issue_label.this["dotfiles:theme: xdg-hygiene"]
  to   = github_issue_label.repo_only["dotfiles:theme: xdg-hygiene"]
}

moved {
  from = github_issue_label.this["dotfiles:upstream-review"]
  to   = github_issue_label.repo_only["dotfiles:upstream-review"]
}

# The `protect main` ruleset on every managed repo: rebase-merge only, required
# PR checks (strict:true explained below) — needs GitHub Pro on private repos (ADR-0002).
resource "github_repository_ruleset" "this" {
  for_each = local.repos

  name        = "protect main"
  repository  = github_repository.this[each.key].name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      allowed_merge_methods             = ["rebase"]
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_approving_review_count   = 0
      required_review_thread_resolution = false
    }

    required_status_checks {
      # Buys nothing for code correctness (rebase-merge replays regardless) but
      # tofu-plan.yml's SHA-keyed artifact (ADR-0003) depends on it — see there.
      strict_required_status_checks_policy = true
      do_not_enforce_on_create             = false

      # extra_required_checks (repos.tf) is per-repo on purpose: an unscoped
      # required check with no run ever reported blocks merge forever, account-wide.
      dynamic "required_check" {
        for_each = concat(["single commit", "conventional commit", "adr guard"], each.value.extra_required_checks)
        content {
          context = required_check.value
        }
      }
    }
  }
}
