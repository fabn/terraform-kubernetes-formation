variable "namespace" {
  description = "Kubernetes namespace where the Deployment lives and the CronJob is created."
  type        = string
}

variable "deployment" {
  description = "Name of the Deployment to inherit the runtime environment from: envFrom (the content-hash-named Secret/ConfigMap), imagePullSecrets, serviceAccountName and the volumes its container mounts are read from its pod template."
  type        = string
}

variable "image" {
  description = "Full image reference (registry/repo:tag) each tick runs. Explicit rather than read from the Deployment, so the schedule is a deterministic part of the plan instead of a live-cluster read that changes whenever the Deployment rolls."
  type        = string
}

variable "command" {
  description = "Command executed on every tick, e.g. [\"/bin/bash\", \"-lc\", \"bin/rails runner ...\"]."
  type        = list(string)

  validation {
    condition     = length(var.command) > 0
    error_message = "command must not be empty."
  }
}

variable "schedule" {
  description = "Cron expression in the standard five-field form, e.g. \"*/5 * * * *\"."
  type        = string

  validation {
    condition     = length(split(" ", trimspace(var.schedule))) == 5 || startswith(trimspace(var.schedule), "@")
    error_message = "schedule must be a five-field cron expression or one of the @ shorthands (@hourly, @daily, ...)."
  }
}

variable "name" {
  description = "Component label and CronJob name suffix: the CronJob is created as `<deployment>-<name>`."
  type        = string
  default     = "cron"
}

variable "timezone" {
  description = "IANA time zone the schedule is interpreted in (Kubernetes >= 1.27). Null leaves it at the kube-controller-manager's zone, which is UTC on a managed control plane — set it when a task must line up with local business hours across DST."
  type        = string
  default     = null
  nullable    = true
}

variable "concurrency_policy" {
  description = "What happens when a tick is due while the previous one still runs: Forbid (skip), Replace (kill the running one), Allow (overlap). Forbid by default — a task that overruns its period is far more often a slow run to wait out than one to duplicate, and Allow turns a single slow tick into an unbounded pile-up."
  type        = string
  default     = "Forbid"

  validation {
    condition     = contains(["Allow", "Forbid", "Replace"], var.concurrency_policy)
    error_message = "concurrency_policy must be one of Allow, Forbid, Replace."
  }
}

variable "starting_deadline_seconds" {
  description = "How late a missed tick may still start. Null means no deadline: after a control-plane outage the controller fires every schedule it missed. Set it to something near the period to make a missed tick simply skip."
  type        = number
  default     = null
  nullable    = true
}

variable "suspend" {
  description = "Stop firing new ticks while leaving the CronJob in place. The switch to reach for during a maintenance window or a cutover freeze, instead of destroying and recreating the resource."
  type        = bool
  default     = false
}

variable "successful_jobs_history_limit" {
  description = "Completed Jobs kept for inspection. One is usually enough: a frequent schedule turns the Kubernetes default of three into steady clutter in the namespace."
  type        = number
  default     = 1
}

variable "failed_jobs_history_limit" {
  description = "Failed Jobs kept for inspection — the ones whose logs are actually worth reading."
  type        = number
  default     = 1
}

variable "backoff_limit" {
  description = "Retries before a tick is marked failed. Zero by default: a recurring task gets its retry from the next tick, and an immediate retry doubles the work of anything not idempotent."
  type        = number
  default     = 0
}

variable "ttl_seconds_after_finished" {
  description = "Seconds a finished Job (and its pods, hence its logs) is kept before garbage collection. Interacts with the history limits — whichever comes first wins."
  type        = number
  default     = 600
}

variable "active_deadline_seconds" {
  description = "In-cluster deadline for a single tick: its pods are killed once exceeded. Worth setting below the schedule period, so a hung run cannot block every later tick under the default Forbid policy."
  type        = number
  default     = null
  nullable    = true
}

variable "env" {
  description = "Extra plaintext env vars set on the container, taking precedence over the inherited envFrom."
  type        = map(string)
  default     = {}
}

# Pod-template only, and unable to win over the module's own labels: the four
# `app.kubernetes.io/*` keys are re-merged last (see main.tf). The CronJob and
# the Job keep the module's labels untouched, because the label that matters to
# a pod-level admission webhook is the one on the pod it creates.
variable "pod_labels" {
  description = "Extra labels merged onto the pod template of every tick, not onto the CronJob or the Job. For metadata read by pod-level admission webhooks — `admission.datadoghq.com/enabled = \"true\"` is the motivating one. The module's own `app.kubernetes.io/*` labels always win over these."
  type        = map(string)
  default     = {}
}

variable "cpu_requests" {
  description = "CPU request for the tick container."
  type        = string
  default     = "50m"
}

variable "memory_requests" {
  description = "Memory request for the tick container."
  type        = string
  default     = "128Mi"
}

variable "memory_limits" {
  description = "Memory limit for the tick container. Null renders no limit."
  type        = string
  default     = "512Mi"
  nullable    = true
}

# Storage is part of the environment a tick inherits, not part of one
# invocation's configuration — see the reasoning in main.tf.
variable "inherit_volumes" {
  description = "Inherit the volumes the Deployment's container mounts, at the same paths. True because the alternative fails silently: the mount path exists inside the image anyway, so a tick without the real volume reads an empty directory and writes into the container's ephemeral layer without an error anywhere. Inheriting a volume that cannot be mounted only leaves the pod Pending, which is visible in seconds. Set it to false when inheritance is wrong for a caller, and declare what the tick needs through `volumes`."
  type        = bool
  default     = true
}

variable "volumes" {
  description = "Extra volumes mounted into the tick container, in the shape `fabn/workload/kubernetes` uses. Additive to what was inherited; an entry whose `name` matches an inherited volume replaces it. At most one source per entry — none renders an emptyDir. Claims are never created here."
  type = list(object({
    name                    = string
    mount_path              = string
    sub_path                = optional(string)
    read_only               = optional(bool, false)
    secret                  = optional(string)
    config_map              = optional(string)
    persistent_volume_claim = optional(string)
    mode                    = optional(string)
  }))
  default = []

  validation {
    condition = alltrue([
      for volume in var.volumes :
      length([for source in [volume.secret, volume.config_map, volume.persistent_volume_claim] : source if source != null]) <= 1
    ])
    error_message = "Each volume sets at most one of secret, config_map, persistent_volume_claim; setting none renders an emptyDir."
  }
}
