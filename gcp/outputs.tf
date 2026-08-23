# Not secret: service account emails and a job name grant nothing by
# themselves — iam/main.tf's trust condition (the SA's unique_id) is the
# actual gate.

output "dispatch_service_account_email" {
  value       = google_service_account.dispatch.email
  description = "Feed `gcloud iam service-accounts describe <this> --format='value(uniqueId)'` into iam/'s TF_VAR_gcp_dispatch_service_account_unique_id (docs/BOOTSTRAP.md §17)."
}

output "job_name" {
  value       = google_cloud_run_v2_job.dispatch.name
  description = "The Cloud Run Job name — for manual `gcloud run jobs execute` verification runs."
}

output "agent_memory_runtime_service_account_email" {
  value       = google_service_account.agent_memory_runtime.email
  description = "The consumer Service's service_account; feed its uniqueId into iam/'s TF_VAR_gcp_agent_memory_service_account_unique_id (docs/BOOTSTRAP.md §18)."
}

output "agent_memory_deploy_service_account_email" {
  value       = google_service_account.agent_memory_deploy.email
  description = "agent-memory-server CI's service_account input to google-github-actions/auth (ADR-0026)."
}

output "agent_memory_wif_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "Full WIF provider resource name — agent-memory-server CI's workload_identity_provider input (ADR-0026)."
}

output "agent_memory_repository_url" {
  value       = "${var.google_region}-docker.pkg.dev/${var.google_project_id}/${google_artifact_registry_repository.agent_memory.repository_id}"
  description = "Image repo base agent-memory-server's CI pushes to (ADR-0026)."
}

output "agent_memory_plan_read_service_account_email" {
  value       = google_service_account.agent_memory_plan_read.email
  description = "agent-memory-server CI's plan-read service_account input to google-github-actions/auth (#272)."
}

output "agent_memory_plan_read_wif_provider" {
  value       = google_iam_workload_identity_pool_provider.github_agent_memory_plan_read.name
  description = "Full WIF provider resource name — agent-memory-server CI's plan-time workload_identity_provider input (#272)."
}

output "agent_memory_edge_invoker_service_account_email" {
  value       = google_service_account.agent_memory_edge_invoker.email
  description = "The Worker's impersonated identity — feed into the out-of-band SA-key creation step (docs/BOOTSTRAP.md §20, ADR-0031, #323)."
}
