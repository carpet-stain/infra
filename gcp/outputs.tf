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
