# ADR-0010's role×path matrix, as code — every role needs both the SSM
# path grant and kms:Decrypt on that tier's key; see ADR-0010's two audit fences.

data "aws_caller_identity" "this" {}

locals {
  # Exact ID-pinned sub claims, never a repo-wide wildcard — see ADR-0010's
  # #163 amendment for the ID-pinning verification and the same-sub residual.
  gh_sub_prefix = "repo:carpet-stain@5483606/infra@1304594349"
  gh_sub_main   = "${local.gh_sub_prefix}:ref:refs/heads/main"
  gh_sub_pr     = "${local.gh_sub_prefix}:pull_request"

  # project-starter-template's own ID-pinned sub (#147, ADR-0010's #163
  # amendment) — its e2e-*.yml workflows are all workflow_dispatch on main.
  pst_sub_prefix = "repo:carpet-stain@5483606/project-starter-template@1305207591"
  pst_sub_main   = "${local.pst_sub_prefix}:ref:refs/heads/main"

  # agents' and dotfiles' pr-code-review.yml (#220): both ID-pinned,
  # :pull_request (no :ref) since the trigger is pull_request, not a branch.
  pr_review_openrouter_subs = [
    "repo:carpet-stain@5483606/agents@1333182579:pull_request",
    "repo:carpet-stain@5483606/dotfiles@247179961:pull_request",
  ]

  ssm_param_arn = "arn:aws:ssm:us-east-1:${data.aws_caller_identity.this.account_id}:parameter"

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
          "token.actions.githubusercontent.com:sub" = local.gh_sub_main
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "apply" {
  name = "read-write-infra-tier"
  role = aws_iam_role.apply.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = concat(local.infra_read_statements, local.infra_write_statements)
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

# agents' and dotfiles' pr-code-review.yml — dotfiles' OIDC sub isn't
# ID-pinned yet, so its AssumeRoleWithWebIdentity denies until flipped (#220).
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
        Sid      = "ReadRuntimeParameters"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "${local.ssm_param_arn}/runtime/*"
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

# infra-app-runtime: reserved name/path only, no role, until a workload exists (ADR-0010).
