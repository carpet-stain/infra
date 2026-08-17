# GCP side of #191's fix (ADR-0024): a Cloud Scheduler tick every 5 min
# invokes a Cloud Run Job that federates keyless into AWS (OIDC, no
# standing GCP or AWS credential — see iam/main.tf's infra-dispatch-read)
# and reads /runtime/infra-dispatch-token to workflow_dispatch
# vend-token.yml — a caller GitHub's own throttled schedule: trigger can't
# be, because GitHub's scheduler is the thing being routed around.

locals {
  job_name = "vend-token-dispatch"
}

# --- APIs --------------------------------------------------------------

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudscheduler" {
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# --- Artifact Registry -------------------------------------------------

# Tofu references the image tag, it doesn't build it — built and pushed
# by hand, docs/BOOTSTRAP.md §17 (ADR-0014 §3's docker-push exit path).
resource "google_artifact_registry_repository" "dispatch" {
  repository_id = "infra-dispatch"
  format        = "DOCKER"
  location      = var.google_region
  description   = "gcp/dispatch/'s image — the vend-token dispatch job (ADR-0024, #191)."

  depends_on = [google_project_service.artifactregistry]
}

# --- The Job's own identity ---------------------------------------------

# No extra IAM binding needed — a Job's attached SA mints its own OIDC
# token; serviceAccountTokenCreator is only for impersonating a different one.
resource "google_service_account" "dispatch" {
  account_id   = "cloud-run-dispatch"
  display_name = "Cloud Run dispatch job — federates to AWS infra-dispatch-read (ADR-0024, #191)"
}

# --- The Job -------------------------------------------------------------

resource "google_cloud_run_v2_job" "dispatch" {
  name     = local.job_name
  location = var.google_region

  # Redeployable, stateless batch job (ADR-0024's checklist #9) — nothing
  # here is worth Cloud Run's delete-protection friction.
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.dispatch.email
      max_retries     = 1
      timeout         = "60s"

      containers {
        image = var.dispatch_image

        env {
          name  = "AWS_ROLE_ARN"
          value = var.aws_dispatch_role_arn
        }
      }
    }
  }

  depends_on = [google_project_service.run]
}

# --- Cloud Scheduler's invoking identity ----------------------------------

resource "google_service_account" "scheduler_invoker" {
  account_id   = "scheduler-dispatch-invoker"
  display_name = "Cloud Scheduler invoker for the dispatch job (ADR-0024, #191)"
}

# Scoped to this one job, not a project-wide run role.
resource "google_cloud_run_v2_job_iam_member" "scheduler_can_run" {
  project  = var.google_project_id
  location = var.google_region
  name     = google_cloud_run_v2_job.dispatch.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler_invoker.email}"
}

# --- Cloud Scheduler -------------------------------------------------------

resource "google_cloud_scheduler_job" "dispatch" {
  name      = "vend-token-dispatch-tick"
  region    = var.google_region
  schedule  = "*/5 * * * *"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    # Google's documented Cloud Scheduler-to-Cloud-Run-Jobs URI shape —
    # no live project to plan against here; verify at first apply (ADR-0024).
    uri = "https://${var.google_region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.google_project_id}/jobs/${local.job_name}:run"

    oauth_token {
      service_account_email = google_service_account.scheduler_invoker.email
    }
  }

  retry_config {
    retry_count = 1
  }

  depends_on = [
    google_project_service.cloudscheduler,
    google_cloud_run_v2_job_iam_member.scheduler_can_run,
  ]
}
