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
  description = "CPU limit per instance. null (default) omits the CPU limit entirely — Burstable QoS, no CFS throttling, recommended for a database. Set it only to enforce a ceiling (e.g. cpu_limits = cpu_requests for Guaranteed QoS)."
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

# --- instance lifecycle (shutdown / failover timings) ------------------------
# CloudNativePG's own defaults (stopDelay 1800s, smartShutdownTimeout 180s,
# switchoverDelay / startDelay 3600s) are tuned for large databases and are
# hostile to fast node lifecycles: stopDelay is copied verbatim onto the pod's
# terminationGracePeriodSeconds, so the 1800s default lets a single instance
# block a node drain (Karpenter / cluster-autoscaler consolidation) for up to
# 30 minutes, and it can never be honoured inside a Spot interruption's
# ~2-minute window anyway. This module therefore ships shorter, drain-friendly
# shutdown defaults; raise them for a large database whose shutdown checkpoint
# needs more time. The remaining timings default to null (operator default) so
# they stay opt-in.

variable "stop_delay" {
  description = "Seconds the operator waits for a graceful (smart then fast) shutdown before killing the instance. CloudNativePG copies this onto the pod's terminationGracePeriodSeconds, so it also bounds how long the instance can delay a node drain. The operator default is 1800; this module lowers it to keep node consolidation and Spot interruptions responsive. Raise it for a large database whose shutdown checkpoint needs more time."
  type        = number
  default     = 300

  validation {
    condition     = var.stop_delay > 0
    error_message = "stop_delay must be > 0."
  }
}

variable "smart_shutdown_timeout" {
  description = "Seconds of stop_delay spent in smart shutdown (waiting for existing connections to close on their own) before escalating to fast shutdown. Persistent application connection pools never close voluntarily, so a large value only delays the inevitable fast shutdown; a small one cuts over quickly. Must be < stop_delay. The operator default is 180; this module lowers it."
  type        = number
  default     = 30

  validation {
    condition     = var.smart_shutdown_timeout >= 0 && var.smart_shutdown_timeout < var.stop_delay
    error_message = "smart_shutdown_timeout must be >= 0 and < stop_delay."
  }
}

variable "switchover_delay" {
  description = "Seconds the operator allows for a planned switchover (former primary shutdown + new primary promotion) before failing it. null uses the operator default (3600). Lower it for more decisive switchovers on small databases."
  type        = number
  default     = null
}

variable "start_delay" {
  description = "Seconds the operator waits for an instance to become ready at startup before considering it failed (drives the startup probe budget). null uses the operator default (3600). Keep it generous when a replica may bootstrap from a large base backup."
  type        = number
  default     = null
}

variable "failover_delay" {
  description = "Seconds the operator waits before triggering a failover after the primary becomes unreachable. null uses the operator default (0, immediate). Raise it to ride out brief primary blips without promoting a replica."
  type        = number
  default     = null
}
