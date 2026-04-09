terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------------------
# 0. 프로젝트 네트워크 기본 설정
# ------------------------------------------------------------------------------
resource "google_compute_project_default_network_tier" "default" {
  project      = var.project_id
  network_tier = "PREMIUM"
}

# ------------------------------------------------------------------------------
# 1. IAM 및 서비스 계정
# ------------------------------------------------------------------------------
resource "google_service_account" "proxy_sa" {
  account_id   = "litellm-proxy-sa-tf"
  display_name = "LiteLLM Proxy Service Account (TF)"
}

resource "google_project_iam_member" "vertex_ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.proxy_sa.email}"
}

resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.proxy_sa.email}"
}

# ------------------------------------------------------------------------------
# 2. Cloud Run 서비스
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "proxy" {
  name     = "litellm-proxy-tf"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" # 외부 직접 호출 차단 (LB 필수)

  template {
    service_account = google_service_account.proxy_sa.email
    
    vpc_access {
      network_interfaces {
        network    = "default"
        subnetwork = "default"
      }
      egress = "ALL_TRAFFIC"
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_repo_name}/litellm-proxy:latest"
      ports {
        container_port = 8080
      }
      
      env {
        name  = "LITELLM_MASTER_KEY"
        value = var.litellm_master_key
      }
      
      env {
        name  = "FORCE_REDEPLOY"
        value = "9"
      }
      
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = "database-url"
            version = "latest"
          }
        }
      }
      
      resources {
        limits = {
          cpu    = "4"
          memory = "8192Mi"
        }
      }
    }
  }
}

# Load Balancer가 Cloud Run을 호출할 수 있도록 허용
resource "google_cloud_run_service_iam_binding" "invoker" {
  location = google_cloud_run_v2_service.proxy.location
  project  = google_cloud_run_v2_service.proxy.project
  service  = google_cloud_run_v2_service.proxy.name
  role     = "roles/run.invoker"
  members  = ["allUsers"]
}

# ------------------------------------------------------------------------------
# 3. Serverless NEG (부하 분산기와 Cloud Run 연결)
# ------------------------------------------------------------------------------
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "litellm-proxy-neg-tf"
  network_endpoint_type = "SERVERLESS"
  region                = var.region
  cloud_run {
    service = google_cloud_run_v2_service.proxy.name
  }
}

# ------------------------------------------------------------------------------
# 4. Cloud Armor 정책 (API 경로 보호)
# ------------------------------------------------------------------------------
resource "google_compute_security_policy" "api_policy" {
  name        = "litellm-api-policy-tf"
  description = "Block all except allowed IP"

  rule {
    action   = "allow"
    priority = "1000"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = var.allowed_ips
      }
    }
    description = "Allow user IP"
  }

  rule {
    action   = "deny(403)"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default deny all"
  }
}

# ------------------------------------------------------------------------------
# 5. 백엔드 서비스 (IAP용 및 API용 분리)
# ------------------------------------------------------------------------------
resource "google_compute_backend_service" "iap_backend" {
  name                  = "litellm-proxy-backend-tf"
  load_balancing_scheme = "EXTERNAL"
  protocol              = "HTTPS"
  
  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }

  iap {
    # oauth2_client_id 설정이 비어있으면 프로젝트 기본 IAP 설정을 따름
    oauth2_client_id     = "" 
    oauth2_client_secret = ""
  }
}

# IAP 접근 권한 부여
resource "google_iap_web_backend_service_iam_member" "iap_accessor" {
  project             = var.project_id
  web_backend_service = google_compute_backend_service.iap_backend.name
  role                = "roles/iap.httpsResourceAccessor"
  member              = "user:${var.iap_admin_email}"
}

resource "google_compute_backend_service" "api_backend" {
  name                  = "litellm-api-backend-tf"
  load_balancing_scheme = "EXTERNAL"
  protocol              = "HTTPS"
  security_policy       = google_compute_security_policy.api_policy.id

  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }
}

# ------------------------------------------------------------------------------
# 6. 라우팅 (URL Map)
# ------------------------------------------------------------------------------
resource "google_compute_url_map" "url_map" {
  name            = "litellm-proxy-url-map-tf"
  default_service = google_compute_backend_service.iap_backend.id

  host_rule {
    hosts        = [var.domain_name]
    path_matcher = "litellm-matcher"
  }

  path_matcher {
    name            = "litellm-matcher"
    default_service = google_compute_backend_service.iap_backend.id

    path_rule {
      paths   = ["/ui", "/ui/*"]
      service = google_compute_backend_service.iap_backend.id
    }
    path_rule {
      paths   = ["/v1", "/v1/*", "/key", "/key/*", "/vertex_ai", "/vertex_ai/*"]
      service = google_compute_backend_service.api_backend.id
    }
  }
}

# ------------------------------------------------------------------------------
# 7. 프론트엔드 (IP, SSL, Proxy, Forwarding Rule)
# ------------------------------------------------------------------------------
resource "google_compute_global_address" "default" {
  name         = "litellm-proxy-ip-tf"
}

resource "google_compute_managed_ssl_certificate" "default" {
  name = "litellm-proxy-cert-tf"

  managed {
    domains = [var.domain_name]
  }
}

resource "google_compute_target_https_proxy" "default" {
  name             = "litellm-proxy-https-proxy-tf"
  url_map          = google_compute_url_map.url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.default.id]
}

resource "google_compute_global_forwarding_rule" "default" {
  name                  = "litellm-proxy-forwarding-rule-tf"
  target                = google_compute_target_https_proxy.default.id
  port_range            = "443"
  ip_address            = google_compute_global_address.default.address
  load_balancing_scheme = "EXTERNAL"
}

# ------------------------------------------------------------------------------
# 8. Cloud DNS 연동
# ------------------------------------------------------------------------------
data "google_dns_managed_zone" "env_dns_zone" {
  name = var.dns_zone_name
}

resource "google_dns_record_set" "a_record" {
  name         = "${var.domain_name}."
  managed_zone = data.google_dns_managed_zone.env_dns_zone.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.default.address]
}
# ------------------------------------------------------------------------------
# 9. Private Service Connect (PSC) for Google APIs
# ------------------------------------------------------------------------------
resource "google_compute_global_address" "psc_api_ip" {
  name         = "google-api-psc-ip-tf"
  project      = var.project_id
  purpose      = "PRIVATE_SERVICE_CONNECT"
  network      = "projects/${var.project_id}/global/networks/default"
  address_type = "INTERNAL"
  address      = "192.168.255.240"
}

resource "google_compute_global_forwarding_rule" "psc_api_forwarding_rule" {
  name                  = "pscgoogleapistf"
  project               = var.project_id
  target                = "all-apis"
  network               = "projects/${var.project_id}/global/networks/default"
  ip_address            = google_compute_global_address.psc_api_ip.id
  load_balancing_scheme = ""
}

resource "google_dns_managed_zone" "private_googleapis" {
  name        = "private-googleapis-zone-tf"
  project     = var.project_id
  dns_name    = "googleapis.com."
  description = "Private DNS zone for Google APIs via PSC"
  visibility  = "private"
  
  private_visibility_config {
    networks {
      network_url = "projects/${var.project_id}/global/networks/default"
    }
  }
}

resource "google_dns_record_set" "googleapis_a_record_wildcard" {
  name         = "*.googleapis.com."
  project      = var.project_id
  managed_zone = google_dns_managed_zone.private_googleapis.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.psc_api_ip.address]
}

resource "google_dns_record_set" "googleapis_a_record_root" {
  name         = "googleapis.com."
  project      = var.project_id
  managed_zone = google_dns_managed_zone.private_googleapis.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.psc_api_ip.address]
}
