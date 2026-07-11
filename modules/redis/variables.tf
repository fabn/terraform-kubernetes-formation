variable "namespace" {
  description = "Kubernetes namespace where the chart is installed."
  type        = string
}

variable "name" {
  description = "Helm release name. Clients connect to the `<name>-master` Service."
  type        = string
  default     = "redis"
}

variable "chart_version" {
  description = "Bitnami redis Helm chart version."
  type        = string
  default     = "20.1.7"
}

variable "cpu_requests" {
  description = "CPU request for the redis-master container."
  type        = string
  default     = "10m"
}

variable "max_memory" {
  description = "Redis maxmemory directive in megabytes. Drives commonConfiguration's `maxmemory` AND k8s memory requests/limits (limits = ceil(max_memory * 1.25)Mi)."
  type        = number
  default     = 256
}

variable "persistence_enabled" {
  description = "When true, the master PVC is created. Disable for ephemeral environments."
  type        = bool
  default     = true
}

variable "persistence_size" {
  description = "Master PVC size."
  type        = string
  default     = "1Gi"
}

variable "delete_pvc_on_delete" {
  description = "When true, the PVC is deleted alongside the chart release. Leave false for production-grade data, true for short-lived envs."
  type        = bool
  default     = false
}
