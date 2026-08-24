# ADR-0010's role×path matrix, as code — every role needs both the SSM
# path grant and kms:Decrypt on that tier's key; see ADR-0010's two audit fences.

data "aws_caller_identity" "this" {}

locals {
  # Exact ID-pinned sub claims, never a repo-wide wildcard — see ADR-0010's
  # #163 amendment for the ID-pinning verification and the same-sub residual.
  gh_sub_prefix = "repo:carpet-stain@5483606/infra@1304594349"
  gh_sub_main   = "${local.gh_sub_prefix}:ref:refs/heads/main"
  gh_sub_pr     = "${local.gh_sub_prefix}:pull_request"
  # Environment-gated jobs present :environment:<name>, not the ref — the
  # sub customization is a prefix on GitHub's default claim (ADR-0010).
  gh_sub_dispatch = "${local.gh_sub_prefix}:environment:tofu-apply-dispatch"

  # project-starter-template's own ID-pinned sub (#147, ADR-0010's #163
  # amendment) — its e2e-*.yml workflows are all workflow_dispatch on main.
  pst_sub_prefix = "repo:carpet-stain@5483606/project-starter-template@1305207591"
  pst_sub_main   = "${local.pst_sub_prefix}:ref:refs/heads/main"

  # agents', dotfiles', and agent-memory-server's pr-code-review.yml (#220,
  # #307): all ID-pinned, :pull_request since the trigger is pull_request.
  pr_review_openrouter_subs = [
    "repo:carpet-stain@5483606/agents@1333182579:pull_request",
    "repo:carpet-stain@5483606/dotfiles@247179961:pull_request",
    local.amem_sub_pr,
  ]

  # dotfiles' hosted runtime (#217, dotfiles#596/#576): issue_comment/issues
  # aren't PR-associated, so the sub is the default-branch ref form.
  dotfiles_hosted_runtime_sub = "repo:carpet-stain@5483606/dotfiles@247179961:ref:refs/heads/main"

  # agent-memory-server's own CI-apply seam (#272) — same ID-pinning
  # discipline as infra's own subs above.
  amem_sub_prefix = "repo:carpet-stain@5483606/agent-memory-server@1337947129"
  amem_sub_main   = "${local.amem_sub_prefix}:ref:refs/heads/main"
  amem_sub_pr     = "${local.amem_sub_prefix}:pull_request"
  # Same environment-tail rule as gh_sub_dispatch above.
  amem_sub_dispatch = "${local.amem_sub_prefix}:environment:tofu-apply-dispatch"

  ssm_param_arn = "arn:aws:ssm:us-east-1:${data.aws_caller_identity.this.account_id}:parameter"

  # /cicd/agent-memory/* — split by plan (RO token) vs apply (RW token);
  # neither role gets the other's. See ADR-0010's #272 amendment.
  cicd_amem_param_arn         = "${local.ssm_param_arn}/cicd/agent-memory"
  cicd_amem_plan_read_params  = ["neon-api-key", "tf-state-passphrase", "r2-plan-access-key-id", "r2-plan-storage-token", "r2-account-id"]
  cicd_amem_apply_params      = ["neon-api-key", "tf-state-passphrase", "r2-apply-access-key-id", "r2-apply-storage-token", "r2-account-id"]
  runtime_amem_param_wildcard = "${local.ssm_param_arn}/runtime/agent-memory/*"

  # Read grants mirror plan/apply parity (ADR-0010); DescribeParameters is
  # metadata-only and unscopable, so its wildcard exposes no values.
  infra_read_statements = [
    {
      Sid      = "ReadInfraParameters"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:ListTagsForResource"]
      Resource = "${local.ssm_param_arn}/infra/*"
    },
    {
      Sid      = "DescribeParameterMetadata"
      Effect   = "Allow"
      Action   = "ssm:DescribeParameters"
      Resource = "*"
    },
    {
      Sid      = "DecryptInfraTier"
      Effect   = "Allow"
      Action   = "kms:Decrypt"
      Resource = aws_kms_key.infra_secrets.arn
    },
  ]

  # Write grants shared verbatim with infra-local-apply — same root module,
  # only the credential fence differs (OIDC sub vs Keychain, ADR-0010 §#126).
  infra_write_statements = [
    {
      Sid      = "WriteInfraParameters"
      Effect   = "Allow"
      Action   = ["ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"]
      Resource = "${local.ssm_param_arn}/infra/*"
    },
    {
      Sid      = "EncryptInfraTier"
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
      Resource = aws_kms_key.infra_secrets.arn
    },
  ]
}

# No thumbprint_list: AWS resolves GitHub's OIDC issuer automatically — the
# 2019-era manual thumbprint guidance is obsolete (ADR-0010).
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# --- Tier keys -------------------------------------------------------------
# Default key policy (account root + IAM delegation); per-role grants live below.

resource "aws_kms_key" "infra_secrets" {
  description         = "Encrypts /infra/* SSM parameters — the crown-jewel tier (ADR-0010)"
  enable_key_rotation = true
}

resource "aws_kms_alias" "infra_secrets" {
  name          = "alias/infra-secrets"
  target_key_id = aws_kms_key.infra_secrets.key_id
}

resource "aws_kms_key" "runtime_secrets" {
  description         = "Encrypts /runtime/* SSM parameters — the rotating tier (ADR-0010)"
  enable_key_rotation = true
}

resource "aws_kms_alias" "runtime_secrets" {
  name          = "alias/runtime-secrets"
  target_key_id = aws_kms_key.runtime_secrets.key_id
}

# Separate from alias/runtime-secrets on purpose: folding /cicd in would
# let agent-memory-ssm-read decrypt the state passphrase (ADR-0010 #272).
resource "aws_kms_key" "cicd_secrets" {
  description         = "Encrypts /cicd/* SSM parameters — break-glass-provisioned, consumer-CI-read tier (ADR-0010/ADR-0016, #272)"
  enable_key_rotation = true
}

resource "aws_kms_alias" "cicd_secrets" {
  name          = "alias/cicd-secrets"
  target_key_id = aws_kms_key.cicd_secrets.key_id
}

# --- /cicd/agent-memory/* parameters (#272) ---------------------------------

# Bootstrap-populated (docs/BOOTSTRAP.md §19), same placeholder shape as
# /infra/* (ssm.tf) — but here, not there: this tier is break-glass-only.

locals {
  cicd_amem_parameters = {
    "neon-api-key"           = "Second, account-global Neon API key (#272) — agent-memory-server CI's neon provider; containment/rotation-independent from /infra/neon-api-key, not isolation"
    "tf-state-passphrase"    = "OpenTofu state encryption passphrase for agent-memory-server's own R2 state (#272) — read by both plan and apply, same shape as /infra/tf-state-passphrase"
    "r2-plan-access-key-id"  = "R2 Object-Read-only S3 access key id for agent_memory_tofu_state (#272, plan-read)"
    "r2-plan-storage-token"  = "R2 Object-Read-only token — agent-memory-server's CI sha256s it into the S3 secret (ADR-0002 pattern)"
    "r2-apply-access-key-id" = "R2 Object Read & Write S3 access key id for agent_memory_tofu_state (#272, apply)"
    "r2-apply-storage-token" = "R2 Object Read & Write token — agent-memory-server's CI sha256s it into the S3 secret (ADR-0002 pattern)"
    "r2-account-id"          = "Cloudflare account id — forms agent-memory-server's R2 S3 endpoint, never hardcoded in that public repo"
  }
}

resource "aws_ssm_parameter" "cicd_amem" {
  for_each = local.cicd_amem_parameters

  name        = "/cicd/agent-memory/${each.key}"
  description = each.value
  type        = "SecureString"
  key_id      = aws_kms_alias.cicd_secrets.name
  value       = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [value]
  }
}

# --- CI roles (OIDC-assumed, no standing credential) -----------------------

# tofu-plan.yml (pull_request) and tofu-drift.yml (schedule → branch-ref
# sub): read-only on the crown-jewel tier.
resource "aws_iam_role" "plan_read" {
  name = "infra-plan-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [local.gh_sub_pr, local.gh_sub_main]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "plan_read" {
  name = "read-infra-tier"
  role = aws_iam_role.plan_read.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.infra_read_statements
  })
}

# tofu-apply.yml / tofu-apply-dispatch.yml: plan-read's surface plus
# /infra/* writes; no /runtime/* access either way (ADR-0010's matrix).
resource "aws_iam_role" "apply" {
  name = "infra-apply"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # The dispatch sub is approval-gated, not ref-gated — the
          # environment's reviewer + branch policy are load-bearing (ADR-0010).
          "token.actions.githubusercontent.com:sub" = [local.gh_sub_main, local.gh_sub_dispatch]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "apply" {
  name = "read-write-infra-tier"
  role = aws_iam_role.apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.infra_read_statements, local.infra_write_statements, [
      {
        # Bare us-east-1 pin, no global-service exception — vacuous under
        # this role (#237, #230 N7). Doesn't self-lock: bootstrap edits this policy.
        Sid      = "DenyOutsideHomeRegion"
        Effect   = "Deny"
        Action   = "*"
        Resource = "*"
        Condition = {
          StringNotEquals = { "aws:RequestedRegion" = "us-east-1" }
        }
      },
    ])
  })
}

# vend-token.yml (#124): one parameter by full ARN, not a path wildcard —
# unattended and scheduled, so the audit invariant names it explicitly (ADR-0010).
resource "aws_iam_role" "vend_write" {
  name = "infra-vend-write"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.gh_sub_main
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "vend_write" {
  name = "vend-runtime-token"
  role = aws_iam_role.vend_write.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadAppKeyParameterOnly"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/infra/gh-app-private-key"
      },
      {
        # Encryption-context-bound to this one parameter ARN — a broader
        # /infra/* GetParameter grant elsewhere still couldn't decrypt with this role.
        Sid      = "DecryptAppKeyParameterOnly"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.infra_secrets.arn
        Condition = {
          StringEquals = {
            "kms:EncryptionContext:PARAMETER_ARN" = "${local.ssm_param_arn}/infra/gh-app-private-key"
          }
        }
      },
      {
        Sid      = "WriteVendedTokenOnly"
        Effect   = "Allow"
        Action   = "ssm:PutParameter"
        Resource = "${local.ssm_param_arn}/runtime/vended-token"
      },
      {
        # Dedicated token, not a wider repos: on the vended-token above —
        # #51 keeps infra excluded from that one on purpose (ADR-0024).
        Sid      = "WriteInfraDispatchTokenOnly"
        Effect   = "Allow"
        Action   = "ssm:PutParameter"
        Resource = "${local.ssm_param_arn}/runtime/infra-dispatch-token"
      },
      {
        Sid      = "EncryptRuntimeTier"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# --- Cross-repo consumer roles (OIDC-assumed) ------------------------------

# project-starter-template's e2e-*.yml (#147): trusts its own OIDC sub, pinned
# to the single vended-token ARN, not infra-local-read's /runtime/* wildcard.
resource "aws_iam_role" "pst_e2e_read" {
  name = "project-starter-template-e2e-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.pst_sub_main
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "pst_e2e_read" {
  name = "read-vended-token"
  role = aws_iam_role.pst_e2e_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadVendedTokenOnly"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/runtime/vended-token"
      },
      {
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# agents' and dotfiles' pr-code-review.yml — both subs ID-pinned and
# verified live against real runs (#220, #227).
resource "aws_iam_role" "pr_review_openrouter_read" {
  name = "pr-review-openrouter-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.pr_review_openrouter_subs
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "pr_review_openrouter_read" {
  name = "read-openrouter-key"
  role = aws_iam_role.pr_review_openrouter_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadOpenrouterKeyOnly"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/runtime/openrouter-api-key"
      },
      {
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# dotfiles' hosted runtime (#217, BOOTSTRAP.md §14): fail-loud verification
# of the assumed role is the consuming workflow's job, not this policy's (#227).
resource "aws_iam_role" "dotfiles_hosted_runtime_read" {
  name = "dotfiles-hosted-runtime-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.dotfiles_hosted_runtime_sub
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "dotfiles_hosted_runtime_read" {
  name = "read-agent-credentials"
  role = aws_iam_role.dotfiles_hosted_runtime_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Named allow-list, never /runtime/* (#303). The two Anthropic keys
        # dropped from here, superseded by the OpenRouter grant below.
        Sid    = "ReadAgentCredentialsOnly"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "${local.ssm_param_arn}/runtime/backlog-manager-pat",
          "${local.ssm_param_arn}/runtime/plan-reviewer-pat",
        ]
      },
      {
        # Shared model-inference credential replacing the two per-role
        # Anthropic keys above (dotfiles#576) — see BOOTSTRAP.md §16.
        Sid      = "ReadOpenRouterKeyOnly"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/runtime/openrouter-api-key"
      },
      {
        # The runner's own write identity, not an agent's — #305, same
        # param + precedent as pst_e2e_read's own grant below.
        Sid      = "ReadDispatchTokenOnly"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/runtime/vended-token"
      },
      {
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# dotfiles' board-sync.yml (#301) — own role, not a Sid on
# dotfiles_hosted_runtime_read below; see BOOTSTRAP.md §21 for why.
resource "aws_iam_role" "dotfiles_board_sync_read" {
  name = "dotfiles-board-sync-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.dotfiles_hosted_runtime_sub
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "dotfiles_board_sync_read" {
  name = "read-board-sync-pat"
  role = aws_iam_role.dotfiles_board_sync_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadBoardSyncPatOnly"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/runtime/board-sync-pat"
      },
      {
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# --- GCP Cloud Run dispatch consumer (OIDC-assumed, ADR-0024, #191) --------

# accounts.google.com is an AWS-native principal — literal string, never an
# OIDC-provider ARN; sub is gcp/'s SA numeric unique_id (ADR-0024, #191).
resource "aws_iam_role" "dispatch_read" {
  name = "infra-dispatch-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "accounts.google.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "accounts.google.com:oaud" = "sts.amazonaws.com"
          "accounts.google.com:sub"  = var.gcp_dispatch_service_account_unique_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "dispatch_read" {
  name = "read-infra-dispatch-token"
  role = aws_iam_role.dispatch_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadInfraDispatchTokenOnly"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/runtime/infra-dispatch-token"
      },
      {
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# --- GCP agent-memory Cloud Run consumer (OIDC-assumed, ADR-0026, #240) ----

# Same native-principal + :oaud shape as dispatch_read above (ADR-0024's
# amendment); sub is gcp/'s cloud-run-agent-memory SA numeric unique_id.
resource "aws_iam_role" "agent_memory_ssm_read" {
  name = "agent-memory-ssm-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "accounts.google.com" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "accounts.google.com:oaud" = "sts.amazonaws.com"
          "accounts.google.com:sub"  = var.gcp_agent_memory_service_account_unique_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "agent_memory_ssm_read" {
  name = "read-agent-memory-parameters"
  role = aws_iam_role.agent_memory_ssm_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # A path wildcard, not one ARN: the consumer owns several values
        # here (connection-uri, per-role bearers), all created outside this state (ADR-0026).
        Sid      = "ReadAgentMemoryParameters"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/runtime/agent-memory/*"
      },
      {
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# --- agent-memory-server CI-apply seam (OIDC-assumed, #272) ----------------

# Same shape as infra-plan-read/infra-apply above; no S3 grant — state is
# R2, reached via the token in /cicd, not this role.

resource "aws_iam_role" "agent_memory_plan_read" {
  name = "agent-memory-plan-read"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.amem_sub_pr
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "agent_memory_plan_read" {
  name = "read-cicd-and-runtime-agent-memory"
  role = aws_iam_role.agent_memory_plan_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadCicdAgentMemoryPlanParameters"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = [for p in local.cicd_amem_plan_read_params : "${local.cicd_amem_param_arn}/${p}"]
      },
      {
        Sid      = "DecryptCicdTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.cicd_secrets.arn
      },
      {
        # Consumer-owned, tofu-managed aws_ssm_parameter resources
        # (agent-memory-server's ssm.tf) — a plan refreshes them, read-only.
        Sid      = "ReadRuntimeAgentMemoryParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:ListTagsForResource"]
        Resource = local.runtime_amem_param_wildcard
      },
      {
        # The provider reads metadata on refresh — mirrors the infra roles'
        # statement above; unscopable, exposes names not values.
        Sid      = "DescribeParameterMetadata"
        Effect   = "Allow"
        Action   = "ssm:DescribeParameters"
        Resource = "*"
      },
      {
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

resource "aws_iam_role" "agent_memory_apply" {
  name = "agent-memory-apply"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Same shape as infra-apply: ref sub or the approval-gated
          # environment sub — see that role's comment.
          "token.actions.githubusercontent.com:sub" = [local.amem_sub_main, local.amem_sub_dispatch]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "agent_memory_apply" {
  name = "read-write-cicd-and-runtime-agent-memory"
  role = aws_iam_role.agent_memory_apply.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadCicdAgentMemoryApplyParameters"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = [for p in local.cicd_amem_apply_params : "${local.cicd_amem_param_arn}/${p}"]
      },
      {
        Sid      = "DecryptCicdTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.cicd_secrets.arn
      },
      {
        # Full lifecycle (create/update/delete) on the consumer's own
        # aws_ssm_parameter resources — this role is that tofu's apply identity.
        Sid      = "ReadWriteRuntimeAgentMemoryParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:ListTagsForResource", "ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:RemoveTagsFromResource"]
        Resource = local.runtime_amem_param_wildcard
      },
      {
        # Same refresh-metadata need as plan-read — see that role's statement.
        Sid      = "DescribeParameterMetadata"
        Effect   = "Allow"
        Action   = "ssm:DescribeParameters"
        Resource = "*"
      },
      {
        Sid      = "EncryptRuntimeTier"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.runtime_secrets.arn
      },
      {
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# --- Local identity --------------------------------------------------------

# Single IAM user, not a group (CIS) — keeps the audit invariant's grant holder unambiguous (ADR-0010).
#trivy:ignore:AVD-AWS-0143
resource "aws_iam_user" "local_read" {
  name = "infra-local-read"
}

resource "aws_iam_user_policy" "local_read" {
  name = "read-runtime-tier"
  user = aws_iam_user.local_read.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Explicit allow-list, never /runtime/* — infra-dispatch-token
        # (actions:write on infra) stays out of this key's reach (#243, ADR-0010).
        Sid    = "ReadRuntimeParameters"
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          "${local.ssm_param_arn}/runtime/vended-token",
          "${local.ssm_param_arn}/runtime/backlog-manager-pat",
          "${local.ssm_param_arn}/runtime/plan-reviewer-pat",
          "${local.ssm_param_arn}/runtime/backlog-manager-anthropic-key",
          "${local.ssm_param_arn}/runtime/plan-reviewer-anthropic-key",
          "${local.ssm_param_arn}/runtime/openrouter-api-key",
          "${local.ssm_param_arn}/runtime/agent-memory-backup-key",
          "${local.ssm_param_arn}/runtime/agent-memory/backlog-manager/bearer-tokens",
          "${local.ssm_param_arn}/runtime/agent-memory/backlog-manager/connection-uri",
          "${local.ssm_param_arn}/runtime/board-sync-pat",
        ]
      },
      {
        # Stays key-wide — the per-param SSM grant above is the effective fence (#243).
        Sid      = "DecryptRuntimeTier"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.runtime_secrets.arn
      },
    ]
  })
}

# Same crown-jewel read+write as infra-apply; Keychain-prompt-gated, no iam:*/kms:Put* (ADR-0010 §#126).
#trivy:ignore:AVD-AWS-0143
resource "aws_iam_user" "local_apply" {
  name = "infra-local-apply"
}

resource "aws_iam_user_policy" "local_apply" {
  name = "read-write-infra-tier"
  user = aws_iam_user.local_apply.name
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.infra_read_statements, local.infra_write_statements)
  })
}

# --- Console admin (escalation class) --------------------------------------

# Console-only *:* admin, no access key, MFA-enforced; inline+untagged since infra-bootstrap lacks iam:AttachUserPolicy/TagUser (ADR-0015).
#trivy:ignore:AVD-AWS-0143
resource "aws_iam_user" "console_admin" {
  name = "infra-console-admin"
}

resource "aws_iam_user_policy" "console_admin" {
  name = "console-admin"
  user = aws_iam_user.console_admin.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AdminEverything"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
      {
        # Defense-in-depth against the casual self-key click, not
        # containment — an *:* identity can escalate anyway (ADR-0015).
        Sid      = "DenySelfAccessKey"
        Effect   = "Deny"
        Action   = "iam:CreateAccessKey"
        Resource = "arn:aws:iam::${data.aws_caller_identity.this.account_id}:user/$${aws:username}"
      },
      {
        # These two support no resource scoping — account-level reads.
        Sid      = "AllowEnrollmentAccountReads"
        Effect   = "Allow"
        Action   = ["iam:GetAccountPasswordPolicy", "iam:ListVirtualMFADevices"]
        Resource = "*"
      },
      {
        # DeleteVirtualMFADevice covers abandon-then-retry (a stale device
        # locks re-enrollment); DeactivateMFADevice omitted — recovery is root break-glass (ADR-0015).
        Sid    = "AllowSelfEnrollment"
        Effect = "Allow"
        Action = [
          "iam:ChangePassword",
          "iam:GetUser",
          "iam:ListMFADevices",
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:DeleteVirtualMFADevice",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.this.account_id}:user/$${aws:username}",
          "arn:aws:iam::${data.aws_caller_identity.this.account_id}:mfa/$${aws:username}",
        ]
      },
      {
        # Resource:* is load-bearing — narrower would let reads on other
        # ARNs escape the deny. NotAction = the enrollment set above.
        Sid    = "DenyAllButEnrollmentPreMfa"
        Effect = "Deny"
        NotAction = [
          "iam:ChangePassword",
          "iam:GetAccountPasswordPolicy",
          "iam:GetUser",
          "iam:ListMFADevices",
          "iam:ListVirtualMFADevices",
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:DeleteVirtualMFADevice",
        ]
        Resource = "*"
        Condition = {
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
        }
      },
    ]
  })
}

# --- Account guardrails: S3 Block Public Access (#236, epic #230) ----------

# The org-free preventive freebie — no Organizations/SCP needed for this one.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Account guardrails: IAM Access Analyzer (#235, epic #230) -------------

# type = ACCOUNT is the free external-access analyzer; ORGANIZATION needs
# Organizations (out of scope, #230) and UNUSED_ACCESS is the paid tier.
resource "aws_accessanalyzer_analyzer" "external_access" {
  analyzer_name = "infra-external-access"
  type          = "ACCOUNT"
}

# --- Account guardrails: Budgets (#233, epic #230) --------------------------

# Mirrors BOOTSTRAP.md §3's manual zero-spend template — Tofu-owned now.
# No forecast leg: forecasting a near-zero budget is meaningless.
resource "aws_budgets_budget" "zero_spend" {
  name         = "infra-zero-spend"
  budget_type  = "COST"
  limit_amount = "0.01"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.aws_budget_notification_email]
  }
}

locals {
  # $20/$50/$100 tiers, forecast + actual (#233) — a $20 forecast alone
  # would miss a slow leak the zero-spend budget above already catches.
  aws_budget_alert_tiers = [20, 50, 100]
}

resource "aws_budgets_budget" "spend_alerts" {
  name         = "infra-spend-alerts"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = setproduct(local.aws_budget_alert_tiers, ["ACTUAL", "FORECASTED"])
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value[0]
      threshold_type             = "ABSOLUTE_VALUE"
      notification_type          = notification.value[1]
      subscriber_email_addresses = [var.aws_budget_notification_email]
    }
  }
}

# infra-app-runtime: reserved name/path only, no role, until a workload exists (ADR-0010).
