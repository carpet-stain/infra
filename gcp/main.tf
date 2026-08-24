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

# --- agent-memory bootstrap (ADR-0026, #240) -------------------------------
# Identities only — the Service itself is consumer-owned (ADR-0026's boundary).

resource "google_artifact_registry_repository" "agent_memory" {
  repository_id = "agent-memory"
  format        = "DOCKER"
  location      = var.google_region
  description   = "agent-memory-server's image — the hosted MCP memory endpoint (ADR-0026, #240)."

  depends_on = [google_project_service.artifactregistry]
}

# Its unique_id pins iam/'s agent-memory-ssm-read trust — same shape as
# cloud-run-dispatch above (docs/BOOTSTRAP.md §18).
resource "google_service_account" "agent_memory_runtime" {
  account_id   = "cloud-run-agent-memory"
  display_name = "Cloud Run agent-memory service — federates to AWS agent-memory-ssm-read (ADR-0026, #240)"
}

# WIF token exchange (sts) + SA impersonation (iamcredentials) for the
# keyless deploy path below.
resource "google_project_service" "sts" {
  service            = "sts.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iamcredentials" {
  service            = "iamcredentials.googleapis.com"
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.sts]
}

# The deploy sub with GitHub's environment tail — approval-gated, not
# ref-gated (ADR-0010's dispatch amendment).
locals {
  agent_memory_dispatch_sub = replace(var.agent_memory_deploy_sub, ":ref:refs/heads/main", ":environment:tofu-apply-dispatch")
}

# attribute_condition duplicates the SA binding's subject pin on purpose —
# a future too-wide binding still can't trust a sub outside it (#227 fail-loud).
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  attribute_condition = "assertion.sub == '${var.agent_memory_deploy_sub}' || assertion.sub == '${local.agent_memory_dispatch_sub}'"
}

resource "google_service_account" "agent_memory_deploy" {
  account_id   = "agent-memory-deploy"
  display_name = "agent-memory-server CI deploy via GitHub WIF (ADR-0026, #240)"
}

resource "google_service_account_iam_member" "agent_memory_deploy_wif" {
  service_account_id = google_service_account.agent_memory_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/${var.agent_memory_deploy_sub}"

  depends_on = [google_project_service.iamcredentials]
}

# Impersonation is subject-pinned twice (provider condition + binding) —
# the dispatch sub needs both, like the main-ref sub above.
resource "google_service_account_iam_member" "agent_memory_deploy_wif_dispatch" {
  service_account_id = google_service_account.agent_memory_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/${local.agent_memory_dispatch_sub}"

  depends_on = [google_project_service.iamcredentials]
}

# Project scope, not resource: run.developer on the one Service would need
# it to pre-exist, and the consumer creates it (ADR-0026's bounded-blast-radius call).
resource "google_project_iam_member" "agent_memory_deploy_run" {
  project = var.google_project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.agent_memory_deploy.email}"
}

resource "google_artifact_registry_repository_iam_member" "agent_memory_deploy_push" {
  repository = google_artifact_registry_repository.agent_memory.name
  location   = var.google_region
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.agent_memory_deploy.email}"
}

# run.developer alone can't deploy a Service that runs as another SA —
# actAs on the runtime SA is the missing half.
resource "google_service_account_iam_member" "agent_memory_deploy_act_as_runtime" {
  service_account_id = google_service_account.agent_memory_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.agent_memory_deploy.email}"
}

# --- agent-memory-server plan-read (ADR-0010/ADR-0016's /cicd seam, #272) --

# A distinct WIF provider, not a widening of github-oidc above: its
# attribute_condition pins the PR sub only, never the deploy main-branch one.
resource "google_iam_workload_identity_pool_provider" "github_agent_memory_plan_read" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc-amem-plan-read"
  display_name                       = "GitHub OIDC (amem plan-read)"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }

  attribute_condition = "assertion.sub == '${var.agent_memory_plan_read_sub}'"
}

resource "google_service_account" "agent_memory_plan_read" {
  account_id   = "agent-memory-plan-read"
  display_name = "agent-memory-server CI plan-read via GitHub WIF (#272)"
}

resource "google_service_account_iam_member" "agent_memory_plan_read_wif" {
  service_account_id = google_service_account.agent_memory_plan_read.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/${var.agent_memory_plan_read_sub}"

  depends_on = [google_project_service.iamcredentials]
}

# Project scope, same reasoning as agent_memory_deploy_run above — the
# Service doesn't exist yet in this project's tofu.
resource "google_project_iam_member" "agent_memory_plan_read_run" {
  project = var.google_project_id
  role    = "roles/run.viewer"
  member  = "serviceAccount:${google_service_account.agent_memory_plan_read.email}"
}

# --- agent-memory edge invoker (ADR-0031, #323) -----------------------------
# Mints the ID token Cloud Run's IAM check reads — replaces the never-built allUsers path (empty IAM policy, verified live).

resource "google_service_account" "agent_memory_edge_invoker" {
  account_id   = "agent-memory-edge-invoker"
  display_name = "Cloudflare Worker edge invoker for agent-memory (ADR-0031, #323)"
}

# Targets a Service this module doesn't manage (ADR-0026's boundary) — a
# wrong or empty agent_memory_service_name must refuse to plan, not 404 at apply (#227).
resource "google_cloud_run_v2_service_iam_member" "agent_memory_edge_invoker_can_run" {
  project  = var.google_project_id
  location = var.google_region
  name     = var.agent_memory_service_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.agent_memory_edge_invoker.email}"
}

# --- Account guardrails: GCS public-access prevention (#278, epic #230) ----

# Project-scoped org policy — no GCP Organization needed (#230's org-free stance).
resource "google_org_policy_policy" "storage_public_access_prevention" {
  name   = "projects/${var.google_project_id}/policies/storage.publicAccessPrevention"
  parent = "projects/${var.google_project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}
