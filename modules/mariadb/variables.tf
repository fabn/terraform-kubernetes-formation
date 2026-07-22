variable "namespace" {
  description = "Kubernetes namespace where the MariaDB instance is created."
  type        = string
}

variable "name" {
  description = "MariaDB CR name. In HA (replicas >= 2) clients connect to the operator-managed `<name>-primary` Service (repointed to the primary on failover); a standalone instance (replicas = 1) is reached on the `<name>` Service."
  type        = string
  default     = "mariadb"
}

variable "database" {
  description = "Name of the application database to create."
  type        = string
}

variable "username" {
  description = "Name of the application user to create (granted all privileges on the database)."
  type        = string
}

variable "part_of" {
  description = "Value of the app.kubernetes.io/part-of label on the managed resources."
  type        = string
  default     = null
}

variable "labels" {
  description = "Extra labels on the MariaDB/Secrets and propagated (spec.inheritMetadata) onto the objects the operator creates."
  type        = map(string)
  default     = {}
}

variable "annotations" {
  description = "Annotations propagated (spec.inheritMetadata) onto the objects the operator creates."
  type        = map(string)
  default     = {}
}

# --- high availability -------------------------------------------------------

variable "replicas" {
  description = "Number of MariaDB instances. 1 = single standalone server (clients use the `<name>` Service); >= 2 = primary + replicas with operator-managed asynchronous replication, and clients use `<name>-primary` (repointed on failover)."
  type        = number
  default     = 2

  validation {
    condition     = var.replicas >= 1
    error_message = "replicas must be >= 1."
  }
}

variable "auto_failover" {
  description = "In replication mode, let the operator promote a replica automatically when the primary goes down, repointing the `<name>-primary` Service. Ignored for a standalone instance."
  type        = bool
  default     = true
}

variable "image" {
  description = "MariaDB container image (e.g. `mariadb:11.4`). null lets the operator pick its default."
  type        = string
  default     = null
}

# --- storage -----------------------------------------------------------------

variable "storage_size" {
  description = "PersistentVolumeClaim size for each instance."
  type        = string
  default     = "5Gi"
}

variable "storage_class" {
  description = "StorageClass for the data volume. null uses the cluster default StorageClass."
  type        = string
  default     = null
}

# --- resources ---------------------------------------------------------------

variable "cpu_requests" {
  description = "CPU request per instance."
  type        = string
  default     = "100m"
}

variable "cpu_limits" {
  description = "CPU limit per instance. null sets no CPU limit (lets MariaDB burst)."
  type        = string
  default     = null
}

variable "memory_requests" {
  description = "Memory request per instance."
  type        = string
  default     = "512Mi"
}

variable "memory_limits" {
  description = "Memory limit per instance. Keep innodb_buffer_pool_size in line with it (exceeding the limit is an OOM-kill)."
  type        = string
  default     = "1Gi"
}

# --- scheduling / hardening --------------------------------------------------

variable "anti_affinity" {
  description = "Require instances to spread across nodes (true HA). Leave false on single-node clusters, or replicas stay Pending."
  type        = bool
  default     = false
}

variable "pod_disruption_budget" {
  description = "PodDisruptionBudget passed verbatim to spec.podDisruptionBudget — mariadb-operator does not manage one automatically. e.g. `{ minAvailable = \"50%\" }`. null omits it."
  type        = any
  default     = null
}

variable "node_selector" {
  description = "nodeSelector for the instance pods."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the instance pods."
  type        = list(any)
  default     = []
}

variable "priority_class_name" {
  description = "PriorityClass for the instance pods."
  type        = string
  default     = null
}

# --- keyless S3 identity -----------------------------------------------------

variable "service_account_name" {
  description = "ServiceAccount for the instance and backup pods (created by this module). Needed for keyless S3 backups via EKS Pod Identity / IRSA. null uses the operator default."
  type        = string
  default     = null
}

variable "service_account_annotations" {
  description = "Annotations for the created ServiceAccount (e.g. the IRSA `eks.amazonaws.com/role-arn` when not using Pod Identity)."
  type        = map(string)
  default     = {}
}

# --- backup ------------------------------------------------------------------

variable "backup" {
  description = <<-EOT
    Scheduled physical backups to an S3-compatible object store (a PhysicalBackup
    CR). Keyless by default: leave credentials_secret_name null and the backup
    Job writes with the pod's ambient IAM identity (EKS Pod Identity / IRSA) via
    service_account_name — no keys to ship. The operator requires an explicit S3
    endpoint, so `region` builds it (`s3.<region>.amazonaws.com`); set
    endpoint_url only to override it for non-AWS S3-compatible stores. Leave null
    to skip backups.
  EOT
  type = object({
    bucket                  = string
    prefix                  = optional(string)
    region                  = string           # required — builds the S3 endpoint (s3.<region>.amazonaws.com)
    endpoint_url            = optional(string) # override the endpoint for non-AWS S3-compatible stores
    credentials_secret_name = optional(string) # null => keyless (Pod Identity / IRSA)
    access_key_id_key       = optional(string, "access-key-id")
    secret_access_key_key   = optional(string, "secret-access-key")
    schedule                = optional(string, "0 3 * * *")
    max_retention           = optional(string, "720h") # 30d
  })
  default = null

  validation {
    condition     = var.backup == null || var.backup.credentials_secret_name != null || var.service_account_name != null
    error_message = "Keyless S3 backup (no credentials_secret_name) requires service_account_name for the Pod Identity/IRSA association."
  }
}

# --- adoption ----------------------------------------------------------------

variable "bootstrap_from" {
  description = <<-EOT
    Adopt an existing database: bootstrap the instance from a logical dump stored
    in S3 (the object must be named `backup.<RFC3339>.sql`, e.g.
    `backup.2026-07-22T10:00:00Z.sql`). Keyless via service_account_name, same as
    backup; `region` builds the S3 endpoint. Set target_recovery_time to pick a
    specific dump when several exist. Only applied when the instance is first
    created.

    Caveat: a full logical dump carries the application user, so the operator's
    User reconcile may fail (`ALTER USER ... Error 1396`) and the app password
    won't match passwordSecretKeyRef. After adopting, reset the app user to match
    the Secret (as root), or take the source dump with data only.
  EOT
  type = object({
    bucket                  = string
    prefix                  = optional(string)
    region                  = string
    endpoint_url            = optional(string)
    credentials_secret_name = optional(string)
    access_key_id_key       = optional(string, "access-key-id")
    secret_access_key_key   = optional(string, "secret-access-key")
    target_recovery_time    = optional(string)
  })
  default = null
}

# --- readiness ---------------------------------------------------------------

variable "wait_for_ready" {
  description = "Block the apply until the operator reports the MariaDB Ready (server up, database created). Off by default; consumers usually gate on their own bootstrap probe."
  type        = bool
  default     = false
}

variable "ready_timeout" {
  description = "How long to wait for the Ready condition when wait_for_ready is set."
  type        = string
  default     = "10m"
}
