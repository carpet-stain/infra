# ADR-0010's role×path matrix, as code. Path is the access boundary
# (/infra/* crown jewels, /runtime/* rotating tier) and every role needs
# both the SSM path grant AND kms:Decrypt on that tier's key — two
# independent fences, so one misconfigured policy can't cross tiers. The
# audit invariant: no identity a local/agent shell holds resolves
# kms:Decrypt on alias/infra-secrets, and local and CI identities share no
# grant.

data "aws_caller_identity" "this" {}

locals {
  # This repo's OIDC sub claims — exact values, never a repo-wide wildcard
  # (ADR-0010). The prefix is GitHub's ID-pinned form (owner and repo ids
  # baked in, immune to rename-resurrection), NOT the plain
  # repo:carpet-stain/infra the older docs show — verified against a live
  # AssumeRoleWithWebIdentity denial and the repo's own
  # GET /repos/{o}/{r}/actions/oidc/customization/sub (sub_claim_prefix).
  # schedule/push/dispatch runs all present the branch-ref sub; only
  # pull_request differs. Residual, accepted for now: every main-branch
  # workflow presents the same sub, so apply/vend/drift are
  # indistinguishable to the trust policy — revisit if a workflow with a
  # lesser trust tier ever runs on main.
  gh_sub_prefix = "repo:carpet-stain@5483606/infra@1304594349"
  gh_sub_main   = "${local.gh_sub_prefix}:ref:refs/heads/main"
  gh_sub_pr     = "${local.gh_sub_prefix}:pull_request"

  ssm_param_arn = "arn:aws:ssm:us-east-1:${data.aws_caller_identity.this.account_id}:parameter"

  # The full crown-jewel read surface — shared verbatim by plan and apply
  # (a plan refreshes every /infra/* parameter, so their read grants are
  # identical; write is the only difference, ADR-0010).
  # DescribeParameters supports no resource scoping — metadata-only, so
  # the wildcard grants names/types, never values.
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
}

# No thumbprint_list: AWS trusts GitHub's OIDC issuer via its own CA store
# for this provider and manages the pinning itself — the 2019-era manual
# thumbprint guidance is obsolete (ADR-0010).
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# --- Tier keys -------------------------------------------------------------
# Default key policy (account root + IAM delegation): the per-role grants
# live in each role's inline policy below, where they're reviewable next to
# the SSM path grant they pair with.

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

# tofu-apply.yml (push to main) and tofu-apply-dispatch.yml
# (workflow_dispatch on main): plan-read's surface plus /infra/* writes.
# No /runtime/* access in either direction — the vended-token parameter is
# deliberately not a tofu resource, so nothing CI applies ever touches the
# rotating tier (the matrix's row holds exactly).
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
    Version = "2012-10-17"
    Statement = concat(local.infra_read_statements, [
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
    ])
  })
}

# vend-token.yml (#124): the narrowest crown-jewel read that exists — one
# parameter by full ARN, not a path wildcard (Bitwarden's Project grant
# couldn't express this; IAM can, ADR-0010), plus write on exactly the one
# runtime parameter it publishes. Unattended and scheduled, yet holding
# kms:Decrypt against the crown-jewel key for that ARN — the audit
# invariant names this role explicitly, not just infra-local-read.
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
        # SSM encrypts each SecureString under an encryption context of
        # its own parameter ARN, so this Decrypt grant is cryptographically
        # pinned to the App-key parameter — even a new GetParameter grant
        # elsewhere in /infra/* couldn't decrypt with this role.
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

# --- Local identity --------------------------------------------------------

# The dedicated local/agent-shell identity (ADR-0010): an IAM user, not a
# role — a laptop has no OIDC sub claim to federate from. Runtime tier
# only; by construction it can't resolve kms:Decrypt on the crown-jewel
# key. Its access key is created by hand in the console and Keychain-gated
# (dotfiles' swap is #125) — never tofu-managed, so no long-lived
# credential lands in any state file.
# Direct user policy is the point, not an oversight: one user, no group to
# manage, and CIS's group indirection would only blur which identity holds
# the runtime-tier grant the audit invariant checks.
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

# infra-app-runtime stays a reserved name and path convention only
# (/runtime/<app>/*) — no role, no policy, until a workload exists to
# design against (ADR-0010, Simplicity First).
