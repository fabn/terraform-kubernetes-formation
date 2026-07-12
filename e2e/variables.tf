# E2E Test Variables
# Subset of variables from parent module needed for E2E tests

variable "name" {
  description = "Application name"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
}

variable "environment" {
  description = "Logical environment name"
  type        = string
  default     = "e2e"
}

variable "image" {
  description = "Container image shared by every process"
  type        = string
}

variable "domain" {
  description = "Public hostname served by the web process ingress"
  type        = string
  default     = null
  nullable    = true
}

variable "create_namespace" {
  description = "Whether to create the namespace"
  type        = bool
  default     = true
}

variable "registry_username" {
  description = "Username for the registry imagePullSecret"
  type        = string
  default     = "e2e"
}

variable "registry_password" {
  description = "Token for the registry imagePullSecret"
  type        = string
  sensitive   = true
  default     = "e2e-dummy-token"
}

variable "formation" {
  description = "Map of process name => process spec"
  type = map(object({
    command            = optional(list(string), [])
    args               = optional(list(string), [])
    replicas           = optional(number, 1)
    cpu_requests       = optional(string, "50m")
    memory_requests    = optional(string, "128Mi")
    memory_limits      = optional(string, "512Mi")
    web                = optional(bool, false)
    ports              = optional(map(number), {})
    startup_probe_path = optional(string)
    http_probe_path    = optional(string)
    datadog_source     = optional(string)
    datadog_checks     = optional(any, {})
  }))
}

variable "env" {
  description = "Plaintext env vars for every process"
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Sensitive env vars for every process"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "ingress_annotations" {
  description = "Extra annotations on the web process ingress"
  type        = map(string)
  default     = {}
}
