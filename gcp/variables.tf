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
