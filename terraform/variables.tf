variable "project_id" {
  description = "The GCP Project ID"
  type        = string
  default     = "duper-project-1"
}

variable "region" {
  description = "Default region for resources"
  type        = string
  default     = "us-central1"
}

variable "domain_name" {
  description = "Custom domain for the proxy"
  type        = string
  default     = "mllllm.com"
}

variable "allowed_ips" {
  description = "List of IP addresses allowed to access API"
  type        = list(string)
  default     = ["104.135.192.52/32", "34.85.101.232/32"]
}

variable "iap_admin_email" {
  description = "Email of the user allowed to access IAP"
  type        = string
  default     = "jjinseo-admin@jjinseo.altostrat.com"
}
