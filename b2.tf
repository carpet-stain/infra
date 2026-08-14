# The agent-memory backup bucket (#159, ADR-0018): dotfiles' client
# (dotfiles#542) writes timestamped snapshots. B2 files are inherently
# versioned — no versioning toggle exists (schema-verified, provider
# v0.13.2) — so a same-name upload supersedes, never destroys, and the
# lifecycle rule below is the sole deletion mechanism: current version
# kept indefinitely, superseded versions for 365 days (ADR-0018's RPO
# ceiling). Security is asserted here because trivy has no b2_bucket
# coverage: allPrivate, SSE-B2, file lock deliberately off (a one-way
# door once enabled). Bucket names are global across B2, hence the
# account prefix (non-secret).
resource "b2_bucket" "agent_memory_backups" {
  bucket_name = "carpet-stain-agent-memory-backups"
  bucket_type = "allPrivate"

  default_server_side_encryption {
    mode      = "SSE-B2"
    algorithm = "AES256"
  }

  file_lock_configuration {
    is_file_lock_enabled = false
  }

  lifecycle_rules {
    file_name_prefix             = ""
    days_from_hiding_to_deleting = 365
  }

  lifecycle {
    prevent_destroy = true
  }
}
