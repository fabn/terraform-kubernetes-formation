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

variable "annotations" {
  description = "Extra annotations propagated to the memcached pods. Use for Datadog autodiscovery of the memcached integration and log collection (ad.datadoghq.com/<container>.*)."
  type        = map(string)
  default     = {}
}

# Scheduling, mirroring the postgres-cnpg and dragonfly addons. Without these a
# stack that pins every workload to a dedicated (tainted) node pool still gets
# its memcached scheduled on the default pool, since the pod has neither the
# selector nor the toleration — silently breaking the isolation the pool exists
# for.
variable "node_selector" {
  description = "nodeSelector for the memcached pods."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the memcached pods (e.g. the NoSchedule taint on a dedicated node pool)."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Equal")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}
