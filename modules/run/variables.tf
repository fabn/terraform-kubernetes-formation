variable "namespace" {
  description = "Kubernetes namespace where the Deployment lives and the Job runs."
  type        = string
}

variable "deployment" {
  description = "Name of the Deployment to inherit the runtime environment from: envFrom (the content-hash-named Secret/ConfigMap), imagePullSecrets and serviceAccountName are read from its pod template."
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
