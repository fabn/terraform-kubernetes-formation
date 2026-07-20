variable "namespace" {
  description = "Kubernetes namespace where the addons are deployed."
  type        = string
}

variable "name" {
  description = "Stack name (e.g. `myapp-staging`). Addon resources are named `<name>-<addon>`; the postgres database/user default to the stack name."
  type        = string

  validation {
    condition     = length(var.name) > 0
    error_message = "name must not be empty."
  }
}

# Heroku-style addon map: one entry per backing service, e.g.
#
#   addons = {
#     postgres = { size = "small" }
#     redis    = { size = "mini" }
#   }
#
# `size` picks a preset plan (mini, small, medium, large — mini being the
# default) that sizes the k8s requests/limits/volumes. Any explicit knob
# (storage_size, max_memory, cpu_requests, …) overrides the preset for that
# field, Heroku-addon style. Knobs beyond these live on the submodules, meant
# to be used directly for those cases.
#
# The `addons` map is intentionally the same shape as the AWS addons companion
# (fabn/addons/aws): a stack swaps in-cluster for managed by pointing at the
# other module with the same map (network inputs aside).
variable "addons" {
  description = "Map of addon name => addon spec. Supported addons: postgres, redis, memcached."
  type = map(object({
    size = optional(string) # mini | small | medium | large

    # all addons: raw resource overrides (win over the preset).
    cpu_requests    = optional(string)
    memory_requests = optional(string) # postgres/memcached (redis derives it from max_memory)
    memory_limits   = optional(string) # postgres only

    # redis/memcached: item/maxmemory cap in megabytes.
    max_memory = optional(number)

    # postgres only.
    database     = optional(string)
    username     = optional(string)
    storage_size = optional(string)

    # redis only.
    persistence_enabled  = optional(bool)
    persistence_size     = optional(string)
    delete_pvc_on_delete = optional(bool)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, spec in var.addons : contains(["postgres", "redis", "memcached"], k)])
    error_message = "Supported addons are: postgres, redis, memcached."
  }

  validation {
    # coalesce over `spec.size == null || …`: some Terraform versions do not
    # short-circuit `||` in a validation condition and evaluate contains(list,
    # null), which errors ("argument must not be null"). A null size means the
    # mini default, which is valid, so fold it in before the membership check.
    condition     = alltrue([for k, spec in var.addons : contains(["mini", "small", "medium", "large"], coalesce(spec.size, "mini"))])
    error_message = "size must be one of: mini, small, medium, large."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : (spec.storage_size == null && spec.memory_limits == null && spec.database == null && spec.username == null) || k == "postgres"])
    error_message = "storage_size, memory_limits, database and username only apply to the postgres addon."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : (spec.persistence_enabled == null && spec.persistence_size == null && spec.delete_pvc_on_delete == null) || k == "redis"])
    error_message = "persistence_enabled, persistence_size and delete_pvc_on_delete only apply to the redis addon."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : spec.max_memory == null || contains(["redis", "memcached"], k)])
    error_message = "max_memory only applies to the redis and memcached addons."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : spec.memory_requests == null || contains(["postgres", "memcached"], k)])
    error_message = "memory_requests only applies to the postgres and memcached addons (redis derives it from max_memory)."
  }
}
