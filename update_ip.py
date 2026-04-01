with open('terraform_litellm/main.tf', 'r') as f:
    content = f.read()

old_str = """resource "google_compute_global_address" "psc_api_ip" {
  name         = "google-api-psc-ip-tf"
  project      = var.project_id
  purpose      = "PRIVATE_SERVICE_CONNECT"
  network      = "projects/${var.project_id}/global/networks/default"
  address_type = "INTERNAL"
}"""

new_str = """resource "google_compute_global_address" "psc_api_ip" {
  name         = "google-api-psc-ip-tf"
  project      = var.project_id
  purpose      = "PRIVATE_SERVICE_CONNECT"
  network      = "projects/${var.project_id}/global/networks/default"
  address_type = "INTERNAL"
  address      = "10.255.255.254"
}"""

content = content.replace(old_str, new_str)

with open('terraform_litellm/main.tf', 'w') as f:
    f.write(content)
