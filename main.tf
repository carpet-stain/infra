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
    #
    # The other five (#88): GitHub's GET /repos omits every merge-setting
    # field for a credential without write-tier repo access — confirmed
    # empirically against this exact App-token config, not just read from
    # docs. tofu-plan.yml's administration:read token gets them back as
    # null, which the provider then diffs against these true/true/true
    # config values on every single PR, a permanent 3-change floor with no
    # real drift underneath. There's no read-tier permission that fixes
    # this — granting write to the plan token would defeat #59's whole
    # point (a compromised plan step could then rewrite repo settings).
    # Unmanaged past initial creation; the "protect main" ruleset's
    # allowed_merge_methods = ["rebase"] is the actual rebase-only
    # enforcement, a harder gate than these convenience toggles.
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

# Repo-specific labels (#13) — deliberately outside the canonical for_each
# above, since local.infra_labels shouldn't land on every managed repo.
# One-off for now, not a general per-repo-scoping mechanism.
resource "github_issue_label" "infra_only" {
  for_each = local.infra_labels

  repository  = github_repository.this["infra"].name
  name        = each.key
  color       = each.value.color
  description = each.value.description

  lifecycle {
    precondition {
      condition     = length(each.value.description) <= 100
      error_message = "GitHub caps label descriptions at 100 characters: \"${each.key}\" is ${length(each.value.description)}."
    }
  }
}

# The `protect main` ruleset on every managed repo: rebase-merge only, no
# deletion or force-push, required PR checks with strict:true (see the
# required_status_checks block below for why). Requires GitHub Pro on
# private repos — every repo in the map is public today.
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
      # strict:true — rebase-merge replays onto current main regardless, so
      # this buys nothing for code correctness, but tofu-plan.yml's
      # SHA-keyed plan artifact (ADR-0003) does depend on it: without
      # strict mode, a merge can replay onto a main that moved since the
      # last push, landing a different SHA than the one last planned. That
      # degrades safely (the apply workflow's escape hatch, #26, catches a
      # missing artifact either way) but forcing a fresh plan up front is
      # cheaper than reaching for the escape hatch after the fact.
      strict_required_status_checks_policy = true
      do_not_enforce_on_create             = false

      # single commit/conventional commit/adr guard ship in pr-guards.yml on
      # every managed repo; extra_required_checks (repos.tf) adds any
      # checks a specific repo requires that haven't propagated to every
      # repo's workflow yet — see dotfiles' entry for why that scoping
      # matters (a required check with no run ever reported blocks merge
      # forever, account-wide, if added here unscoped).
      dynamic "required_check" {
        for_each = concat(["single commit", "conventional commit", "adr guard"], each.value.extra_required_checks)
        content {
          context = required_check.value
        }
      }
    }
  }
}
