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

output "pr_review_openrouter_read_role_arn" {
  value       = aws_iam_role.pr_review_openrouter_read.arn
  description = "Seed as vars.AWS_OPENROUTER_ROLE_ARN on agents, dotfiles, and agent-memory-server — their pr-code-review.yml workflows (#220, #307)."
}

output "dotfiles_hosted_runtime_read_role_arn" {
  value       = aws_iam_role.dotfiles_hosted_runtime_read.arn
  description = "Seed as vars.AWS_HOSTED_RUNTIME_ROLE_ARN on dotfiles — its hosted agent runtime workflow (#217, dotfiles#576)."
}

output "dispatch_read_role_arn" {
  value       = aws_iam_role.dispatch_read.arn
  description = "Feed into gcp/'s TF_VAR_aws_dispatch_role_arn — the Cloud Run Job's AWS_ROLE_ARN env (ADR-0024, #191)."
}

output "agent_memory_ssm_read_role_arn" {
  value       = aws_iam_role.agent_memory_ssm_read.arn
  description = "The memory Service's AWS_ROLE_ARN env — consumed by agent-memory-server's deploy (ADR-0026, #240)."
}

output "agent_memory_plan_read_role_arn" {
  value       = aws_iam_role.agent_memory_plan_read.arn
  description = "agent-memory-server's CI plan-read role ARN — its tofu-plan workflow (#272)."
}

output "agent_memory_apply_role_arn" {
  value       = aws_iam_role.agent_memory_apply.arn
  description = "agent-memory-server's CI apply role ARN — its tofu-apply workflow (#272)."
}
