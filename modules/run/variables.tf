variable "namespace" {
  description = "Kubernetes namespace where the Deployment lives and the Job runs."
  type        = string
}

variable "deployment" {
  description = "Name of the Deployment to inherit the runtime environment from: envFrom (the content-hash-named Secret/ConfigMap), imagePullSecrets, serviceAccountName and the volumes its container mounts are read from its pod template."
  type        = string
}

variable "image" {
  description = "Full image reference (registry/repo:tag) the Job runs. Deliberately explicit rather than read from the Deployment: runs must pin the artifact being released, never whatever tag the Deployment currently points at."
  type        = string
}

variable "command" {
  description = "Command executed by the Job container, e.g. [\"/bin/bash\", \"-lc\", \"bin/rails db:migrate\"]."
  type        = list(string)

  validation {
    condition     = length(var.command) > 0
    error_message = "command must not be empty."
  }
}

variable "init_command" {
  description = "Command for an optional init container sharing the Job's image and env, run before the main container. With backoff_limit = 0 a dependency that is still booting would abort the whole run, so gate on readiness here (e.g. a pg_isready wait loop). Null skips the init container."
  type        = list(string)
  default     = null
  nullable    = true
}

variable "name" {
  description = "Component label and Job name infix: Jobs are created as `<deployment>-<name>-<random>`."
  type        = string
  default     = "run"
}

variable "env" {
  description = "Extra plaintext env vars set on the Job containers, taking precedence over the inherited envFrom."
  type        = map(string)
  default     = {}
}

variable "backoff_limit" {
  description = "Number of retries before the Job is marked failed. One-off tasks (migrations) are rarely safe to blindly re-run, hence no retries by default."
  type        = number
  default     = 0
}

variable "ttl_seconds_after_finished" {
  description = "Seconds a finished Job (and its pods, hence its logs) is kept around before garbage collection."
  type        = number
  default     = 600
}

variable "wait_for_completion" {
  description = "When true, terraform apply blocks until the Job completes and fails when the Job does — the natural gate for release pipelines."
  type        = bool
  default     = true
}

variable "timeout" {
  description = "Create timeout for the Job resource; with wait_for_completion this bounds how long apply waits for the run to finish."
  type        = string
  default     = "10m"
}

variable "active_deadline_seconds" {
  description = "Optional in-cluster deadline for the Job: pods are killed once exceeded. Null leaves the run unbounded on the cluster side (apply is still bounded by var.timeout)."
  type        = number
  default     = null
  nullable    = true
}

# Pod-template only, and unable to win over the module's own labels: the four
# `app.kubernetes.io/*` keys are re-merged last (see main.tf). The Job keeps the
# module's labels untouched, because the label that matters to a pod-level
# admission webhook is the one on the pod it creates.
variable "pod_labels" {
  description = "Extra labels merged onto the run's pod template, not onto the Job. For metadata read by pod-level admission webhooks — `admission.datadoghq.com/enabled = \"true\"` is the motivating one. The module's own `app.kubernetes.io/*` labels always win over these."
  type        = map(string)
  default     = {}
}

# Storage is part of the environment a run inherits, not part of one
# invocation's configuration — see the reasoning in main.tf.
variable "inherit_volumes" {
  description = "Inherit the volumes the Deployment's container mounts, at the same paths. True because the alternative fails silently: the mount path exists inside the image anyway, so a run without the real volume reads an empty directory and writes into the container's ephemeral layer without an error anywhere. Inheriting a volume that cannot be mounted only leaves the pod Pending, which is visible in seconds. Set it to false when inheritance is wrong for a caller, and declare what the run needs through `volumes`."
  type        = bool
  default     = true
}

variable "volumes" {
  description = "Extra volumes mounted into the Job containers (the init container included), in the shape `fabn/workload/kubernetes` uses. Additive to what was inherited; an entry whose `name` matches an inherited volume replaces it. At most one source per entry — none renders an emptyDir. Claims are never created here."
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
