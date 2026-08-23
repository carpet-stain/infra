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

# Security by default for every managed repo — split out because the
# provider deprecated the inline vulnerability_alerts argument (#253).
resource "github_repository_vulnerability_alerts" "this" {
  for_each = local.repos

  repository = github_repository.this[each.key].name
}

# Authoritative per-repo label set — syncs against live labels on first
# apply, no temporary import block for GitHub's seeded defaults (#254).
resource "github_issue_labels" "this" {
  for_each = local.repos

  repository = github_repository.this[each.key].name

  dynamic "label" {
    for_each = local.repo_label_sets[each.key]
    content {
      name = label.key
      # local.labels mixes case; lower() keeps the comparison against
      # GitHub's lowercased hex from perpetually diffing.
      color       = lower(label.value.color)
      description = label.value.description
    }
  }

  lifecycle {
    precondition {
      # No lint catches this — the API 422s at apply time otherwise.
      condition     = length([for name, attrs in local.repo_label_sets[each.key] : name if length(attrs.description) > 100]) == 0
      error_message = "GitHub caps label descriptions at 100 characters: ${join(", ", [for name, attrs in local.repo_label_sets[each.key] : name if length(attrs.description) > 100])}."
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

# Detach state without deleting live labels — github_issue_labels.this
# adopts them via its authoritative first-apply read (#254).
removed {
  from = github_issue_label.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = github_issue_label.repo_only

  lifecycle {
    destroy = false
  }
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

      # extra_required_checks (repos.tf) stays per-repo — an unscoped check that
      # never reports blocks merge forever. Composed contexts: pst ADR-0004/#110.
      dynamic "required_check" {
        for_each = concat(["guards / single commit", "guards / conventional commit", "guards / adr guard"], each.value.extra_required_checks)
        content {
          context = required_check.value
        }
      }
    }
  }
}

data "github_user" "owner" {
  username = "carpet-stain"
}

# Approval gate for tofu-apply-dispatch.yml — load-bearing for infra-apply's
# ref-less :environment: sub trust, not just UX (#246; ADR-0010).
resource "github_repository_environment" "tofu_apply_dispatch" {
  repository  = github_repository.this["infra"].name
  environment = "tofu-apply-dispatch"

  reviewers {
    users = [data.github_user.owner.id]
  }

  # The environment sub is branch-blind — without this, any branch's run
  # could at least enter the approval queue.
  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

# agent-memory-server's twin — as-code so recreating the name-keyed
# environment can't shed the reviewer while the sub stays trusted (ADR-0010).
resource "github_repository_environment" "amem_tofu_apply_dispatch" {
  repository  = github_repository.this["agent-memory-server"].name
  environment = "tofu-apply-dispatch"

  reviewers {
    users = [data.github_user.owner.id]
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}
