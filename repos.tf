# Config-as-data: routine changes happen here, not in main.tf's resources.
# One entry per managed repo; the canonical label set applies to every
# managed repo, except `repo_labels` below, which is scoped to one repo
# apiece (#13, #106). Governance invariants (rebase-merge only, branch
# cleanup) are fixed in main.tf, not per-repo data — see ADR-0011/ADR-0022.

locals {
  repos = {
    agent-memory-server = {
      # Stood up empty like `agents` (#248) — infra#240's WIF deploy trust keys
      # on this repo's Actions OIDC subject, so it must exist first.
      description           = "Hosted per-role agent memory — MCP-over-HTTP server (TypeScript) on Neon Postgres, plus its deploy IaC and consumer-side Neon TF (ADR-0046)"
      visibility            = "public"
      auto_init             = true
      has_issues            = true
      has_projects          = false
      has_wiki              = false
      has_discussions       = false
      allow_auto_merge      = true
      extra_required_checks = ["test"]
      reusable_guards       = true # composed contexts — pst#104 phase 2
      topics = [
        "ai-agents",
        "mcp",
        "agent-memory",
      ]
    }

    agents = {
      # Stood up empty (dotfiles#563, #177) — auto_init seeds main before the
      # ruleset applies, so there's no unprotected window before content lands.
      description           = "Shared AI-agent definitions — personas, universal rules, skills, the memory contract. Provider-neutral markdown, consumed per-project"
      visibility            = "public"
      auto_init             = true
      has_issues            = true
      has_projects          = false
      has_wiki              = false
      has_discussions       = false
      allow_auto_merge      = true
      extra_required_checks = []
      topics = [
        "ai-agents",
        "agent-definitions",
      ]
    }

    deal-finder = {
      description           = "Marketplace-monitoring for secondhand PC parts: polls sources, filters against an in-progress build's needs, LLM-judges fit/price, notifies (never transacts)"
      visibility            = "public"
      has_issues            = true
      has_projects          = false
      has_wiki              = false
      has_discussions       = false
      allow_auto_merge      = true
      extra_required_checks = []
      topics                = []
    }

    dotfiles = {
      description      = "Personal configuration for zsh, NeoVim, ZelliJ and other tools"
      visibility       = "public"
      has_issues       = true
      has_projects     = true
      has_wiki         = false
      has_discussions  = false
      allow_auto_merge = true
      # dotfiles.pr-guards.yml's issue-link job (#449) hasn't propagated to every
      # repo's workflow yet — per-repo here, not main.tf's shared check list.
      extra_required_checks = ["guards / issue link"]
      topics = [
        "configuration-management",
        "dotfiles",
        "dotfiles-linux",
        "dotfiles-macos",
        "dotfiles-manager",
        "ghostty",
        "linux",
        "lua",
        "macos",
        "neovim",
        "zellij",
        "zsh",
      ]
    }

    golden-ratio-dual-gate = {
      description           = "SPY/TIP dual-gate trend-timed leveraged portfolio: research, backtest, and (eventually) Schwab-connected execution"
      visibility            = "public"
      has_issues            = true
      has_projects          = true
      has_wiki              = false
      has_discussions       = false
      allow_auto_merge      = false
      extra_required_checks = []
      topics = [
        "backtesting",
        "leveraged-etfs",
        "portfolio-management",
        "python",
        "quantitative-finance",
        "trading-strategy",
      ]
    }

    infra = {
      description           = "GitHub account governance as code — repos, labels, rulesets (OpenTofu)"
      visibility            = "public"
      has_issues            = true
      has_projects          = false
      has_wiki              = false
      has_discussions       = false
      allow_auto_merge      = true
      extra_required_checks = []
      topics = [
        "opentofu",
        "infrastructure-as-code",
        "repos-as-code",
      ]
    }

    project-starter-template = {
      description           = "Copier toolkit for scaffolding governed repos — git-flow base + language overlays"
      visibility            = "public"
      has_issues            = true
      has_projects          = false
      has_wiki              = false
      has_discussions       = false
      allow_auto_merge      = true
      extra_required_checks = []
      topics = [
        "git-flow",
        "template",
        "project-template",
        "copier",
        "uv",
        "ruff",
      ]
    }

    template-e2e = {
      # Live-e2e sandbox (project-starter-template#42/#47) — App-token CSV
      # additions are a required follow-up PR here, not bundled (AGENTS.md's #127).
      description           = "Permanent sandbox for project-starter-template's live e2e — rendered git-flow output pushed, verified, and discarded per run; not a real project"
      visibility            = "public"
      has_issues            = true
      has_projects          = false
      has_wiki              = false
      has_discussions       = false
      allow_auto_merge      = true
      extra_required_checks = []
      topics = [
        "e2e",
        "sandbox",
        "project-starter-template",
      ]
    }
  }

  # Deliberation-agent machine accounts — see #172/ADR-0035.
  collaborators = {
    "carpet-stain-backlog-manager" = { permission = "pull" }
    "carpet-stain-plan-reviewer"   = { permission = "pull" }
  }

  labels = {
    "agent-ready"         = { color = "2EA043", description = "Mechanical + verifiable; an autonomous agent can implement it without human judgment" }
    "architecture"        = { color = "1D76DB", description = "Architecturally significant — requires an ADR" }
    "blocked"             = { color = "000000", description = "Not actionable until a dependency clears (reason in a comment / native blocked-by)" }
    "bug"                 = { color = "d73a4a", description = "Something isn't working" }
    "documentation"       = { color = "0075ca", description = "Improvements or additions to documentation" }
    "duplicate"           = { color = "cfd3d7", description = "This issue or pull request already exists" }
    "enhancement"         = { color = "a2eeef", description = "New feature or request" }
    "epic"                = { color = "5319E7", description = "Large multi-part effort" }
    "good first issue"    = { color = "7057ff", description = "Good for newcomers" }
    "needs-plan-review"   = { color = "5319E7", description = "Needs architectural review before implementation" }
    "needs-review"        = { color = "FEF2C0", description = "Requests the advisory PR review (pr-code-review.yml) — independent of the architecture/ADR label" }
    "plan-approved"       = { color = "0E8A16", description = "Plan has been reviewed and approved" }
    "priority: high"      = { color = "B60205", description = "Groom/act on soon" }
    "priority: low"       = { color = "C5DEF5", description = "Someday / low urgency" }
    "priority: medium"    = { color = "FBCA04", description = "Normal queue" }
    "spike"               = { color = "0E8A16", description = "Question + concrete deliverable, never open-ended" }
    "theme: agent-config" = { color = "006B75", description = "Claude agent rules, skills, and AGENTS.md" }
    "theme: credentials"  = { color = "BF8700", description = "Token/credential scoping, storage, and loading" }
    "theme: testing"      = { color = "1D76DB", description = "CI, e2e, and local workflow-run infrastructure" }
    "wontfix"             = { color = "ffffff", description = "This will not be worked on" }
  }

  # Labels scoped to a single repo (main.tf's repo_only, #106's audit) — each
  # entry's domain ties it to exactly one managed repo. Generalizes #104's one-off.
  repo_labels = {
    infra = {
      "theme: cloudflare" = { color = "F38020", description = "Cloudflare account surface — provider, zones, DNS, R2, stores" }
      "tofu-drift"        = { color = "d73a4a", description = "Auto-managed by tofu-drift.yml (#87) — open while main has drift, closes once a plan is clean" }
    }
    dotfiles = {
      "release-watch"      = { color = "0E8A16", description = "Flagged by the automated dependency release watcher" }
      "theme: tool-review" = { color = "8250DF", description = "Evaluate modern tool/plugin replacements" }
      "theme: xdg-hygiene" = { color = "D93F0B", description = "$HOME cleanliness / XDG compliance" }
      "upstream-review"    = { color = "5319E7", description = "Ideas from the z0rc/dotfiles fork worth considering" }
    }
  }
}
