# ---------------------------------------------------------------------------
# Network Configuration
# ---------------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  name                    = "${var.hostname}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.hostname}-subnet"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.vpc.id
  region        = var.gcp_region
}

resource "google_compute_firewall" "allow_http_https" {
  name    = "allow-http-https"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server", "https-server"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Restrict this in production if possible
  target_tags   = ["ssh-server"]
}

# ---------------------------------------------------------------------------
# Static IP
# ---------------------------------------------------------------------------

resource "google_compute_address" "static_ip" {
  name   = "${var.hostname}-ip"
  region = var.gcp_region
}

# ---------------------------------------------------------------------------
# GCE Instance (AlmaLinux 10 equivalent / e2-small)
# ---------------------------------------------------------------------------

resource "google_compute_instance" "blog" {
  name         = var.hostname
  machine_type = "e2-small"
  zone         = var.gcp_zone

  tags = ["http-server", "https-server", "ssh-server"]

  boot_disk {
    initialize_params {
      image = "almalinux-cloud/almalinux-9" # Update to Alma 10 when available
      size  = 20
    }
  }

  network_interface {
    network    = google_compute_network.vpc.name
    subnetwork = google_compute_subnetwork.subnet.name

    access_config {
      nat_ip = google_compute_address.static_ip.address
    }
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  service_account {
    scopes = ["cloud-platform"]
  }
}

# ---------------------------------------------------------------------------
# DNS Records (Imported from Current State)
# ---------------------------------------------------------------------------

resource "google_dns_managed_zone" "public" {
  name     = "public"
  dns_name = "${var.domain}."
}

resource "google_dns_record_set" "root_a" {
  name         = "${var.domain}."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.public.name
  rrdatas      = [google_compute_address.static_ip.address]
}

resource "google_dns_record_set" "www_cname" {
  name         = "www.${var.domain}."
  type         = "CNAME"
  ttl          = 300
  managed_zone = google_dns_managed_zone.public.name
  rrdatas      = ["${var.domain}."]
}

resource "google_dns_record_set" "mail_a" {
  name         = "mail.${var.domain}."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.public.name
  rrdatas      = ["194.195.211.88"] # Preserving current mail record
}

# ---------------------------------------------------------------------------
# Artifact Registry for Container Images
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "repo" {
  location      = var.gcp_region
  repository_id = "dev-blog"
  description   = "Docker repository for dev-blog"
  format        = "DOCKER"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-last-3"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }

  cleanup_policies {
    id     = "delete-others"
    action = "DELETE"
    condition {
      tag_state = "ANY"
    }
  }
}

# ---------------------------------------------------------------------------
# Cloud Build Trigger
# ---------------------------------------------------------------------------

resource "google_cloudbuild_trigger" "daily_build" {
  name        = "daily-blog-build"
  description = "Triggered by Scheduler at 6 AM CT"

  filename = "cloudbuild.yaml"

  # Link this to your repository (Requires manual connection in GCP Console once)
  # or use a generic trigger if pushing source.
  trigger_template {
    branch_name = "main"
    repo_name   = "dev-blog" # Update this to your repo name
  }

  substitutions = {
    _BUCKET = google_storage_bucket.content.name
    _REGION = var.gcp_region
    _REPO   = google_artifact_registry_repository.repo.repository_id
  }
}

# ---------------------------------------------------------------------------
# Service Account for Scheduler
# ---------------------------------------------------------------------------

resource "google_service_account" "scheduler_sa" {
  account_id   = "blog-scheduler-sa"
  display_name = "Service Account for Cloud Scheduler"
}

resource "google_project_iam_member" "scheduler_build_editor" {
  project = var.gcp_project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${google_service_account.scheduler_sa.email}"
}

# ---------------------------------------------------------------------------
# Cloud Scheduler Job
# ---------------------------------------------------------------------------

resource "google_cloud_scheduler_job" "daily_trigger" {
  name             = "daily-6am-build-trigger"
  description      = "Triggers the blog build every day at 6 AM CT"
  schedule         = "0 6 * * *"
  time_zone        = "America/Chicago"
  attempt_deadline = "320s"

  http_target {
    http_method = "POST"
    uri         = "https://cloudbuild.googleapis.com/v1/projects/${var.gcp_project_id}/locations/global/triggers/${google_cloudbuild_trigger.daily_build.trigger_id}:run"
    
    oauth_token {
      service_account_email = google_service_account.scheduler_sa.email
    }

    body = base64encode(jsonencode({
      branchName = "main"
    }))
  }
}

# ---------------------------------------------------------------------------
# Secret Manager for Backup Credentials
# ---------------------------------------------------------------------------

resource "google_secret_manager_secret" "restic_password" {
  secret_id = "restic-password"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "r2_access_key" {
  secret_id = "r2-access-key-id"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "r2_secret_key" {
  secret_id = "r2-secret-access-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "restic_repo" {
  secret_id = "restic-repository"
  replication {
    auto {}
  }
}

# ---------------------------------------------------------------------------
# Cloud Function for Restic Backup
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "function_source" {
  name     = "${var.gcp_project_id}-function-source"
  location = var.gcp_region
}

resource "google_service_account" "backup_sa" {
  account_id   = "blog-backup-sa"
  display_name = "Service Account for Backup Function"
}

resource "google_cloudfunctions2_function" "backup" {
  name        = "blog-restic-backup"
  location    = var.gcp_region
  description = "Runs restic backup on GCS object change"

  build_config {
    runtime     = "python311"
    entry_point = "run_backup"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = "backup-source.zip"
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "512Mi"
    timeout_seconds    = 540
    service_account_email = google_service_account.backup_sa.email

    environment_variables = {
      SOURCE_BUCKET = "gs://${google_storage_bucket.content.name}"
    }

    secret_environment_variables {
      key        = "RESTIC_PASSWORD"
      project_id = var.gcp_project_id
      secret     = google_secret_manager_secret.restic_password.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "AWS_ACCESS_KEY_ID"
      project_id = var.gcp_project_id
      secret     = google_secret_manager_secret.r2_access_key.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "AWS_SECRET_ACCESS_KEY"
      project_id = var.gcp_project_id
      secret     = google_secret_manager_secret.r2_secret_key.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "RESTIC_REPOSITORY"
      project_id = var.gcp_project_id
      secret     = google_secret_manager_secret.restic_repo.secret_id
      version    = "latest"
    }
  }

  event_trigger {
    trigger_region = var.gcp_region
    event_type     = "google.cloud.storage.object.v1.finalized"
    retry_policy   = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.backup_sa.email
    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.content.name
    }
  }
}

# ---------------------------------------------------------------------------
# IAM for Backup Function
# ---------------------------------------------------------------------------

resource "google_project_iam_member" "backup_storage_viewer" {
  project = var.gcp_project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.backup_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "backup_secrets" {
  for_each = toset([
    google_secret_manager_secret.restic_password.id,
    google_secret_manager_secret.r2_access_key.id,
    google_secret_manager_secret.r2_secret_key.id,
    google_secret_manager_secret.restic_repo.id
  ])
  secret_id = each.key
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.backup_sa.email}"
}

# Grant Eventarc permission to trigger the function
resource "google_project_iam_member" "eventarc_pubsub_publisher" {
  project = var.gcp_project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

data "google_project" "project" {}
