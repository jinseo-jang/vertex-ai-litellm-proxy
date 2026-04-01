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

variable "allowed_ip" {
  description = "IP address allowed to access API"
  type        = string
  default     = "112.168.208.241/32"
}

variable "iap_admin_email" {
  description = "Email of the user allowed to access IAP"
  type        = string
  default     = "jjinseo-admin@jjinseo.altostrat.com"
}
