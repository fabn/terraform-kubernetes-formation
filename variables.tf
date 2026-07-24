variable "name" {
  description = "Application name. Drives workload names (the web process is named `<name>`, other processes `<name>-<process>`), secret/config prefixes and default Datadog service."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace to deploy into (created by the module unless create_namespace = false)."
  type        = string
}

variable "create_namespace" {
  description = "When false, the caller owns the namespace resource — needed when addons must exist in the namespace before this module's inputs are computable (composition roots)."
  type        = bool
  default     = true
}

variable "environment" {
  description = "Logical environment name (e.g. staging, production, review-pr-123). Used for namespace labels and as the default Datadog env tag."
  type        = string
}

variable "image" {
  description = "Full image reference (registry/repo:tag) shared by every process in the formation. Tag resolution (latest release, :latest, per-PR tag) is the caller's concern."
  type        = string
}

variable "domain" {
  description = "Public hostname served by the web process ingress. Required when the formation defines a web process."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.domain != null || length([for k, p in var.formation : k if p.web]) == 0
    error_message = "domain is required when the formation defines a web process."
  }
}

# Heroku-style process formation: one entry per process type, deployed as an
# instance of fabn/workload/kubernetes. At most one entry may set `web = true`
# (a single `domain` feeds a single ingress, and the web process takes the
# bare app name); it gets the Service + Ingress + HTTP probes, every other
# process runs headless (no Service) and is restarted by the kubelet on
# process exit. Worker-only stacks (queue consumers, schedulers) simply omit
# the web entry.
#
# `autoscaled = true` hands the replica count over to an external autoscaler
# (HPA, KEDA): the process is deployed with `replicas = null` so Terraform
# never manages — or reverts on the next apply — the live count. `replicas`
# is ignored for such processes. An explicit flag rather than a nullable
# `replicas`: an object-type attribute with a default would silently turn an
# explicit null back into the default.
variable "formation" {
  description = "Map of process name => process spec. The web process serves HTTP behind the ingress; non-web processes (worker, metrics, ...) run without a Service."
  type = map(object({
    command            = optional(list(string), [])
    args               = optional(list(string), [])
    replicas           = optional(number, 1)
    autoscaled         = optional(bool, false)
    cpu_requests       = optional(string, "50m")
    memory_requests    = optional(string, "128Mi")
    memory_limits      = optional(string, "512Mi")
    web                = optional(bool, false)
    ports              = optional(map(number), {})
    startup_probe_path = optional(string)
    http_probe_path    = optional(string)
    # Probe tuning. Defaults are more permissive than Kubernetes' own
    # (timeoutSeconds 1, failureThreshold 3): this module is shaped around
    # Rails + Sidekiq, whose cold boot — eager load + a JIT compiling the
    # first request — routinely blows a 1s probe. Startup gets a laxer budget
    # than the steady-state liveness/readiness probe. Set a value to override.
    startup_probe_timeout_seconds   = optional(number, 5)
    startup_probe_failure_threshold = optional(number, 30)
    probe_timeout_seconds           = optional(number, 3)
    probe_failure_threshold         = optional(number)
    datadog_source                  = optional(string)
    datadog_checks                  = optional(any, {})
    # Optional node affinity for this process: `required` match expressions are
    # ANDed into one hard node-selector term, `preferred` are soft/weighted.
    # E.g. require capacity-type In [spot] + instance-category NotIn [t], prefer
    # arch In [arm64]. Passed through to fabn/workload/kubernetes.
    node_affinity = optional(object({
      required = optional(list(object({
        key      = string
        operator = string
        values   = optional(list(string), [])
      })), [])
      preferred = optional(list(object({
        weight   = number
        key      = string
        operator = string
        values   = optional(list(string), [])
      })), [])
    }))
    # Exact-match node selector and pod affinity (co-location), also passed
    # through to fabn/workload/kubernetes. node_affinity covers set-based node
    # placement; these round out the placement surface.
    node_selector = optional(map(string))
    pod_affinity = optional(object({
      required = optional(list(object({
        topology_key = string
        namespaces   = optional(list(string))
        match_labels = optional(map(string), {})
        match_expressions = optional(list(object({
          key      = string
          operator = string
          values   = optional(list(string), [])
        })), [])
      })), [])
      preferred = optional(list(object({
        weight       = number
        topology_key = string
        namespaces   = optional(list(string))
        match_labels = optional(map(string), {})
        match_expressions = optional(list(object({
          key      = string
          operator = string
          values   = optional(list(string), [])
        })), [])
      })), [])
    }))
    # Raw pod anti-affinity (spread) rules, same shape as pod_affinity. This is
    # the escape hatch for arbitrary topology keys / label selectors; it is
    # additive to the `anti_affinity` shorthand below — both render into the
    # same pod_anti_affinity block when set together. Passed through verbatim.
    pod_anti_affinity = optional(object({
      required = optional(list(object({
        topology_key = string
        namespaces   = optional(list(string))
        match_labels = optional(map(string), {})
        match_expressions = optional(list(object({
          key      = string
          operator = string
          values   = optional(list(string), [])
        })), [])
      })), [])
      preferred = optional(list(object({
        weight       = number
        topology_key = string
        namespaces   = optional(list(string))
        match_labels = optional(map(string), {})
        match_expressions = optional(list(object({
          key      = string
          operator = string
          values   = optional(list(string), [])
        })), [])
      })), [])
    }))
    # Pod anti-affinity strategy for spreading this process's own replicas
    # across nodes: "soft" (preferred, best-effort) or "hard" (required, one
    # replica per node — a replica stays Pending when nodes run out). Defaults
    # to "soft", matching fabn/workload/kubernetes. A top-level optional
    # attribute cannot forward an explicit null (Terraform coerces it back to
    # the default), so disabling anti-affinity is not exposed here — soft
    # spreading is always at least a preference. For arbitrary rules beyond
    # host-level spread, use the raw `pod_anti_affinity` above (additive).
    anti_affinity = optional(string, "soft")
    # Topology spread constraints for even distribution across topology domains
    # (zones, nodes). Each entry sets max_skew + topology_key + when_unsatisfiable
    # ("DoNotSchedule"/"ScheduleAnyway"), optional min_domains; label_selector
    # defaults to the workload's own pod labels. Passed through verbatim.
    topology_spread_constraints = optional(list(object({
      max_skew           = number
      topology_key       = string
      when_unsatisfiable = string
      min_domains        = optional(number)
      label_selector = optional(object({
        match_labels = optional(map(string), {})
        match_expressions = optional(list(object({
          key      = string
          operator = string
          values   = optional(list(string), [])
        })), [])
      }))
    })))
    # PodDisruptionBudget for this process, guarding availability during
    # voluntary disruptions (node drains, rollouts). `pdb_enabled` creates the
    # PDB; `pdb_config` sets the budget (defaults to max_unavailable = "1" in
    # fabn/workload/kubernetes). Set min_available or max_unavailable, not both.
    pdb_enabled = optional(bool, false)
    pdb_config = optional(object({
      min_available   = optional(string)
      max_unavailable = optional(string, "1")
    }))
  }))

  validation {
    condition     = length([for k, p in var.formation : k if p.web]) <= 1
    error_message = "At most one formation entry may set web = true."
  }

  validation {
    condition     = alltrue([for p in var.formation : contains(["soft", "hard"], p.anti_affinity)])
    error_message = "anti_affinity must be \"soft\" or \"hard\"."
  }

  validation {
    condition = alltrue([
      for p in var.formation : p.topology_spread_constraints == null ? true : alltrue([
        for c in p.topology_spread_constraints : contains(["DoNotSchedule", "ScheduleAnyway"], c.when_unsatisfiable)
      ])
    ])
    error_message = "topology_spread_constraints when_unsatisfiable must be \"DoNotSchedule\" or \"ScheduleAnyway\"."
  }
}

variable "env" {
  description = "Plaintext env vars for every process (rendered into a ConfigMap). Framework runtime vars (e.g. RAILS_ENV) belong here — the module adds nothing framework-specific."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Sensitive env vars for every process (rendered into a Secret). SECRET_KEY_BASE is generated by the module unless provided here."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "registry_server" {
  description = "Container registry host for the imagePullSecret."
  type        = string
  default     = "ghcr.io"
}

variable "registry_username" {
  description = "Username for the registry imagePullSecret."
  type        = string
}

variable "registry_password" {
  description = "Password/token for the registry imagePullSecret (e.g. a GitHub PAT with read:packages)."
  type        = string
  sensitive   = true
}

variable "ingress_class_name" {
  description = "IngressClass for the web process ingress."
  type        = string
  default     = "nginx"
}

variable "ingress_annotations" {
  description = "Extra annotations on the web process ingress (cache headers, snippets, ...)."
  type        = map(string)
  default     = {}
}

variable "alb" {
  description = "Configure the web process Ingress for an AWS ALB (EKS Auto Mode or AWS Load Balancer Controller), passed through to fabn/workload/kubernetes: TLS terminates on the ALB, so in-cluster TLS and the ACME annotation are suppressed. Set to {} to accept all defaults; on shared (group) ALBs set load_balancer_name, which must carry the same value on every Ingress of the group. Combine with ingress_class_name = null when the ALB class is the cluster default."
  type = object({
    load_balancer_name = optional(string)
    healthcheck_path   = optional(string, "/")
    listen_ports       = optional(list(map(number)), [{ HTTPS = 443 }])
  })
  default  = null
  nullable = true
}

variable "namespace_labels" {
  description = "Extra labels merged onto the namespace."
  type        = map(string)
  default     = {}
}

variable "datadog_enabled" {
  description = "Enable Datadog UST tags + log collection annotations on every process."
  type        = bool
  default     = false
}

variable "datadog_service" {
  description = "Datadog service tag. Defaults to the app name so all processes roll up under one service."
  type        = string
  default     = null
}

variable "datadog_env" {
  description = "Datadog env tag. Defaults to var.environment."
  type        = string
  default     = null
}

variable "datadog_team" {
  description = "Datadog team tag."
  type        = string
  default     = null
}
