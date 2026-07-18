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

  # Legacy flag; matches the live default — leaving it unmodeled would null
  # it on the first post-import apply.
  has_downloads = true

  has_discussions  = each.value.has_discussions
  allow_auto_merge = each.value.allow_auto_merge

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
    # Inert while squash-merge is off, and GitHub's create API stores its
    # own defaults for them regardless of what's sent — pinning them makes
    # every fresh repo drift once. Unmanaged on purpose.
    ignore_changes = [
      squash_merge_commit_title,
      squash_merge_commit_message,
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
}

# The `protect main` ruleset on every managed repo: rebase-merge only, no
# deletion or force-push, required PR checks with strict:false. Requires
# GitHub Pro on private repos — every repo in the map is public today.
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
      # strict:false — rebase-merge already replays onto current main at
      # merge time, so "branch up to date" would only force CI re-runs.
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false

      required_check {
        context = "single commit"
      }
      required_check {
        context = "conventional commit"
      }
      required_check {
        context = "adr guard"
      }
    }
  }
}
