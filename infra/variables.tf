variable "vultr_api_key" {
  description = "Vultr API key. Provide via TF_VAR_vultr_api_key env var."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Vultr region code."
  type        = string
  default     = "sea" # Seattle, WA
}

variable "plan" {
  description = "Vultr instance plan."
  type        = string
  default     = "vc2-1c-2gb"
}

variable "os_name_filter" {
  description = "Substring to match an OS name in the Vultr OS catalog."
  type        = string
  default     = "AlmaLinux 10"
}

variable "hostname" {
  description = "Hostname / label for the instance."
  type        = string
  default     = "dev-blog"
}

variable "ssh_key_ids" {
  description = "List of pre-existing Vultr SSH key IDs to inject."
  type        = list(string)
  default     = []
}

variable "backup_hour_utc" {
  description = "Hour of day (UTC, 0-23) for the daily automated backup."
  type        = number
  default     = 8
}

variable "tags" {
  description = "Tags to apply to the instance."
  type        = list(string)
  default     = ["dev_blog", "managed-by=opentofu"]
}
