variable "namespace" {
  description = "Kubernetes namespace where memcached is deployed."
  type        = string
}

variable "name" {
  description = "Deployment/Service name."
  type        = string
  default     = "memcached"
}

variable "image" {
  description = "Memcached image."
  type        = string
  default     = "memcached:1.6-alpine"
}

variable "max_memory" {
  description = "Memcached item memory cap in megabytes (-m); memory limits derive from it."
  type        = number
  default     = 256
}

variable "cpu_requests" {
  description = "CPU request for the memcached container."
  type        = string
  default     = "10m"
}

variable "memory_requests" {
  description = "Memory request for the memcached container."
  type        = string
  default     = "64Mi"
}

variable "labels" {
  description = "Extra labels applied to the memcached resources and propagated to the pods. Use for Datadog Unified Service Tagging (tags.datadoghq.com/env, /service, /version), which the Datadog agent reads from pod labels."
  type        = map(string)
  default     = {}
}
