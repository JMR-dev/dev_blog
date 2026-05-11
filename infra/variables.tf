variable "gcp_project_id" {
  type        = string
  description = "The GCP Project ID"
  default     = "dev-blog-494815"
}

variable "gcp_region" {
  type        = string
  description = "GCP region"
  default     = "us-central1"
}

variable "gcp_zone" {
  type        = string
  description = "GCP zone"
  default     = "us-central1-a"
}

variable "hostname" {
  type        = string
  description = "The hostname for the instance"
  default     = "dev-blog"
}

variable "domain" {
  type        = string
  description = "The primary domain name"
  default     = "jasonmross.dev"
}
