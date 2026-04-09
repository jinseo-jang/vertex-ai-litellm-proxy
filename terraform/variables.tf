variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "region" {
  description = "Default region for resources"
  type        = string
  default     = "us-central1"
}

variable "domain_name" {
  description = "Custom domain for the proxy"
  type        = string
}

variable "allowed_ips" {
  description = "List of IP addresses allowed to access API"
  type        = list(string)
}

variable "iap_admin_email" {
  description = "Email of the user allowed to access IAP"
  type        = string
}

variable "litellm_master_key" {
  description = "Master key for LiteLLM proxy authentication"
  type        = string
  sensitive   = true
}

variable "artifact_repo_name" {
  description = "Artifact Registry repository name for the LiteLLM Docker image"
  type        = string
  default     = "litellm-repo"
}

variable "dns_zone_name" {
  description = "Name of the existing Cloud DNS managed zone for the domain"
  type        = string
}
