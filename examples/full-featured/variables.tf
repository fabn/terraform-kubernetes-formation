variable "registry_username" {
  description = "Username for the registry imagePullSecret."
  type        = string
  default     = "example"
}

variable "registry_password" {
  description = "Token for the registry imagePullSecret (e.g. a GitHub PAT with read:packages)."
  type        = string
  sensitive   = true
  default     = "example-token"
}
