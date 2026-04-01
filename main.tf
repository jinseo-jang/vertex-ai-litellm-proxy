provider "google" {
  project = "duper-project-1"
  region  = "us-central1"
}

# Artifact Registry for Docker images
resource "google_artifact_registry_repository" "repo" {
  location      = "us-central1"
  repository_id = "litellm-repo"
  description   = "Docker repository for LiteLLM proxy"
  format        = "DOCKER"
}

# Secret Manager Secrets
resource "google_secret_manager_secret" "litellm_master_key" {
  secret_id = "litellm-master-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "database_url" {
  secret_id = "database-url"
  replication {
    auto {}
  }
}

# Cloud SQL Instance
resource "google_sql_database_instance" "litellm_db" {
  name             = "litellm-proxy-db-v1"
  database_version = "POSTGRES_15"
  region           = "us-central1"
  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled = true
    }
  }
  deletion_protection = false
}

resource "google_sql_database" "database" {
  name     = "litellm"
  instance = google_sql_database_instance.litellm_db.name
}

resource "google_sql_user" "users" {
  name     = "litellm_user"
  instance = google_sql_database_instance.litellm_db.name
  password = "secure-password-1234" # Production should use Secret Manager
}

# IAM for Cloud Run
resource "google_service_account" "proxy_sa" {
  account_id   = "litellm-proxy-sa"
  display_name = "LiteLLM Proxy Service Account"
}

resource "google_project_iam_member" "vertex_ai_user" {
  project = "duper-project-1"
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.proxy_sa.email}"
}

resource "google_project_iam_member" "secret_accessor" {
  project = "duper-project-1"
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.proxy_sa.email}"
}

# Note: Cloud Run resource is defined but will be updated after image build
