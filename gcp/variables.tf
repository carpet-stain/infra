# Inputs fed at apply time via TF_VAR_* — same avoid-landing-in-source
# discipline as the root module's variables.tf. The bootstrap ordering in
# docs/BOOTSTRAP.md §17 resolves the chicken-and-egg between this module
# and iam/'s infra-dispatch-read role (each needs the other's output).

variable "google_project_id" {
  type        = string
  nullable    = false
  description = <<-EOT
    GCP project id hosting the dispatch Cloud Run Job, Cloud Scheduler job,
    and Artifact Registry repo (ADR-0024, #191). Created by hand with
    billing enabled before this module's first apply (docs/BOOTSTRAP.md §17).
  EOT

  validation {
    condition     = length(var.google_project_id) > 0
    error_message = "Must be set — every SA email in this module and the ones read by hand for iam/'s unique_id vars (BOOTSTRAP.md §17/§18) is built from it, so an empty value would resolve against the wrong project instead of refusing to plan (#257)."
  }
}

variable "google_region" {
  type        = string
  default     = "us-central1"
  description = "GCP region for every resource in this module — Cloud Run Job, Artifact Registry, Cloud Scheduler."
}

variable "aws_dispatch_role_arn" {
  type        = string
  nullable    = false
  description = <<-EOT
    iam/'s dispatch_read_role_arn output — the Cloud Run Job's AWS_ROLE_ARN
    env, assumed via GCP-to-AWS OIDC federation (ADR-0024). Populated after
    iam/'s apply, not before — see the bootstrap ordering note above.
  EOT
}

variable "dispatch_image" {
  type        = string
  nullable    = false
  description = <<-EOT
    Full Artifact Registry image ref
    (<region>-docker.pkg.dev/<project>/infra-dispatch/dispatch-vend-token:<tag>)
    for gcp/dispatch/'s container, built and pushed before this module's
    Cloud Run Job resource can apply (docs/BOOTSTRAP.md §17) — Tofu doesn't
    build images, only references one that already exists in the registry.
  EOT
}

variable "agent_memory_deploy_sub" {
  type        = string
  nullable    = false
  description = <<-EOT
    Exact GitHub OIDC subject claim allowed to impersonate the
    agent-memory deploy SA — agent-memory-server's main-branch sub in
    ADR-0010's ID-pinned form. Build it from the repo id
    (`gh api repos/carpet-stain/agent-memory-server --jq .id`) once that
    repo exists (docs/BOOTSTRAP.md §18, ADR-0026).
  EOT

  validation {
    condition     = can(regex("^repo:carpet-stain@5483606/agent-memory-server@[0-9]+:ref:refs/heads/main$", var.agent_memory_deploy_sub))
    error_message = "Must be the ID-pinned main-branch sub repo:carpet-stain@5483606/agent-memory-server@<repo-id>:ref:refs/heads/main — a wrong or empty value refuses to plan rather than deploying nothing silently (#227)."
  }
}

variable "agent_memory_plan_read_sub" {
  type        = string
  nullable    = false
  description = <<-EOT
    Exact GitHub OIDC subject claim allowed to impersonate the
    agent-memory plan-read SA — agent-memory-server's pull_request sub, a
    distinct WIF provider from agent_memory_deploy_sub's main-branch one
    (#272, so a PR-triggered plan-read job can never present the
    apply-only sub).
  EOT

  validation {
    condition     = can(regex("^repo:carpet-stain@5483606/agent-memory-server@[0-9]+:pull_request$", var.agent_memory_plan_read_sub))
    error_message = "Must be the ID-pinned pull_request sub repo:carpet-stain@5483606/agent-memory-server@<repo-id>:pull_request — a wrong or empty value refuses to plan rather than deploying nothing silently (#227)."
  }
}

variable "agent_memory_service_name" {
  type        = string
  nullable    = false
  description = <<-EOT
    The consumer's Cloud Run Service name (agent-memory-server's own
    `agent-memory-<role>` shape, ADR-0031, #323) that
    google_cloud_run_v2_service_iam_member.agent_memory_edge_invoker_can_run
    binds against. Out-of-state target — this module doesn't create or
    read the Service, so there's no resource reference to catch a typo.
  EOT

  validation {
    condition     = can(regex("^agent-memory-[a-z0-9-]+$", var.agent_memory_service_name))
    error_message = "Must match the consumer's agent-memory-<role> Service name shape — a wrong or empty value refuses to plan rather than 404ing at apply (#227)."
  }
}
