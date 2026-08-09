# ARNs the CI workflows assume via configure-aws-credentials — seeded once
# as repo variables (docs/BOOTSTRAP.md §10). Not secret: a role ARN grants
# nothing; the trust policy's sub conditions are the gate.

output "plan_role_arn" {
  value       = aws_iam_role.plan_read.arn
  description = "Seed as vars.AWS_PLAN_ROLE_ARN — tofu-plan.yml / tofu-drift.yml."
}

output "apply_role_arn" {
  value       = aws_iam_role.apply.arn
  description = "Seed as vars.AWS_APPLY_ROLE_ARN — tofu-apply.yml / tofu-apply-dispatch.yml."
}

output "vend_role_arn" {
  value       = aws_iam_role.vend_write.arn
  description = "Seed as vars.AWS_VEND_ROLE_ARN when #124 rewrites vend-token.yml."
}

output "pst_e2e_read_role_arn" {
  value       = aws_iam_role.pst_e2e_read.arn
  description = "Seed as vars.AWS_VEND_READ_ROLE_ARN on project-starter-template — its e2e-*.yml workflows (#147)."
}
