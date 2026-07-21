variable "namespace" {
  description = "Kubernetes namespace where the Cluster is created."
  type        = string
}

variable "name" {
  description = "CloudNativePG Cluster name. Clients connect to the primary through the operator-managed `<name>-rw` Service."
  type        = string
  default     = "pg"
}

variable "database" {
  description = "Name of the application database to create (initdb)."
  type        = string
}

variable "username" {
  description = "Name of the application role that owns the database (initdb owner)."
  type        = string
}

variable "part_of" {
  description = "Value of the app.kubernetes.io/part-of label on the managed resources."
  type        = string
  default     = null
}

variable "labels" {
  description = "Extra labels set on the Cluster/Secret and propagated by the operator (spec.inheritedMetadata) onto every object it creates — Pods, Services, PVCs, the PDB, etc."
  type        = map(string)
  default     = {}
}

variable "annotations" {
  description = "Annotations propagated by the operator (spec.inheritedMetadata) onto every object it creates."
  type        = map(string)
  default     = {}
}

variable "instances" {
  description = "Number of PostgreSQL instances (1 = single primary, >=2 = primary + replicas). Anti-affinity `required` needs at least as many nodes as instances, or replicas stay Pending."
  type        = number
  default     = 1

  validation {
    condition     = var.instances >= 1
    error_message = "instances must be >= 1."
  }
}

variable "image_name" {
  description = "Postgres container image. null lets the operator pick its default (matching its supported major version)."
  type        = string
  default     = null
}

variable "wait_for_ready" {
  description = "Block the apply until the operator reports the Cluster healthy (Postgres up, database initialised). Off by default: most composition roots let the operator reconcile asynchronously and gate on their own bootstrap probe. Turn on when the apply must not return before the database is usable."
  type        = bool
  default     = false
}

variable "ready_timeout" {
  description = "How long to wait for the healthy phase when wait_for_ready is set."
  type        = string
  default     = "10m"
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

# --- resources (QoS) ---------------------------------------------------------
# requests == limits yields QoS Guaranteed, which is what CloudNativePG
# recommends for database workloads (no eviction, PG_OOM_ADJUST_VALUE=0). The
# CPU limit defaults to the CPU request to stay Guaranteed; set cpu_limits
# explicitly (or to a higher value) only to trade Guaranteed for headroom.

variable "cpu_requests" {
  description = "CPU request per instance."
  type        = string
  default     = "50m"
}

variable "cpu_limits" {
  description = "CPU limit per instance. null pins it to cpu_requests (QoS Guaranteed)."
  type        = string
  default     = null
}

variable "memory_requests" {
  description = "Memory request per instance."
  type        = string
  default     = "256Mi"
}

variable "memory_limits" {
  description = "Memory limit per instance. Exceeding it is an OOM-kill, so keep shared_buffers/work_mem in line with it."
  type        = string
  default     = "512Mi"
}

# --- high availability -------------------------------------------------------

variable "enable_pdb" {
  description = "Let the operator manage PodDisruptionBudgets (one for the primary, one for the replicas) so a node drain never takes the primary and always leaves a replica. CloudNativePG defaults this on; expose it so single-instance/dev stacks can disable the blocking PDB."
  type        = bool
  default     = true
}

# --- scheduling --------------------------------------------------------------

variable "enable_pod_anti_affinity" {
  description = "Spread instances across nodes."
  type        = bool
  default     = true
}

variable "pod_anti_affinity_type" {
  description = "`required` (hard, true HA) or `preferred` (soft, fits single-node/dev)."
  type        = string
  default     = "preferred"

  validation {
    condition     = contains(["required", "preferred"], var.pod_anti_affinity_type)
    error_message = "pod_anti_affinity_type must be `required` or `preferred`."
  }
}

variable "topology_key" {
  description = "Topology key the anti-affinity spreads on (per-node by default; use a zone key where zones exist)."
  type        = string
  default     = "kubernetes.io/hostname"
}

variable "node_selector" {
  description = "nodeSelector for the instance pods (e.g. a dedicated DB node pool)."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the instance pods (e.g. the `dedicated=database:NoSchedule` taint on a DB node pool)."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Equal")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

variable "priority_class_name" {
  description = "PriorityClass for the instance pods."
  type        = string
  default     = null
}

# --- backup (barman-cloud plugin, S3-compatible object store) ----------------
# Requires the barman-cloud plugin installed cluster-wide (see the
# cloudnative-pg operator module). Leave null to skip backups entirely.

variable "backup" {
  description = <<-EOT
    Continuous backup + PITR to an S3-compatible object store via the
    barman-cloud plugin. When set, the module creates an ObjectStore, wires it
    into the Cluster as the WAL archiver, and schedules base backups.

    Credentials: set credentials_secret_name for static keys; leave it null to
    inherit the pod's ambient IAM identity (inheritFromIAMRole) — e.g. AWS S3
    with EKS Pod Identity or IRSA, no keys to ship. endpoint_url is only needed
    for non-AWS S3-compatible stores; omit it for native AWS S3.
  EOT
  type = object({
    destination_path        = string           # s3://<bucket>/<path>
    endpoint_url            = optional(string) # non-AWS S3-compatible endpoint; omit for AWS S3
    credentials_secret_name = optional(string) # null => inheritFromIAMRole (Pod Identity / IRSA)
    access_key_id_key       = optional(string, "ACCESS_KEY_ID")
    secret_access_key_key   = optional(string, "SECRET_ACCESS_KEY")
    retention_policy        = optional(string, "30d")
    schedule                = optional(string, "0 0 3 * * *") # 6-field cron (with seconds)
    compression             = optional(string, "gzip")
  })
  default = null
}
