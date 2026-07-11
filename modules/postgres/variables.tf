variable "namespace" {
  description = "Kubernetes namespace where the chart is installed."
  type        = string
}

variable "name" {
  description = "Helm release name. Clients connect to the `<name>-postgresql` Service."
  type        = string
  default     = "pg"
}

variable "database" {
  description = "Name of the database to create."
  type        = string
}

variable "username" {
  description = "Name of the database user to create."
  type        = string
}

variable "part_of" {
  description = "Value of the app.kubernetes.io/part-of label on the auth Secret."
  type        = string
  default     = null
}

variable "chart_version" {
  description = "Bitnami postgresql chart version."
  type        = string
  default     = "16.6.7"
}

variable "storage_size" {
  description = "PersistentVolumeClaim size for the Postgres primary."
  type        = string
  default     = "5Gi"
}

variable "cpu_requests" {
  description = "CPU request for the Postgres primary pod."
  type        = string
  default     = "50m"
}

variable "memory_requests" {
  description = "Memory request for the Postgres primary pod."
  type        = string
  default     = "128Mi"
}

variable "memory_limits" {
  description = "Memory limit for the Postgres primary pod."
  type        = string
  default     = "384Mi"
}
