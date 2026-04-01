import os

with open('terraform_litellm/main.tf', 'r') as f:
    content = f.read()

# 1. Update egress to ALL_TRAFFIC to force all external requests through VPC (and thus PSC)
content = content.replace('egress = "PRIVATE_RANGES_ONLY"', 'egress = "ALL_TRAFFIC"')

# 2. Append PSC and DNS resources
psc_code = """
# ------------------------------------------------------------------------------
# 9. Private Service Connect (PSC) for Google APIs
# ------------------------------------------------------------------------------
resource "google_compute_global_address" "psc_api_ip" {
  name         = "google-api-psc-ip-tf"
  project      = var.project_id
  purpose      = "PRIVATE_SERVICE_CONNECT"
  network      = "projects/${var.project_id}/global/networks/default"
  address_type = "INTERNAL"
}

resource "google_compute_global_forwarding_rule" "psc_api_forwarding_rule" {
  name                  = "google-api-psc-rule-tf"
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
"""

if "# 9. Private Service Connect" not in content:
    content += psc_code

with open('terraform_litellm/main.tf', 'w') as f:
    f.write(content)

print("Updated main.tf successfully.")
