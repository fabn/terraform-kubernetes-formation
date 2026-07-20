# In-cluster addons wrapper, formation-style: one `addons` map entry per
# backing service, each deployed as an instance of the matching submodule
# under ../. The merged `env` / `sensitive_env` outputs plug straight into the
# formation module's `env` / `secret_env` inputs, Heroku-addon style.
#
# The companion of fabn/addons/aws (managed AWS backing services): same map
# shape, same env contract, so a stack swaps in-cluster for cloud by pointing
# at the other module. Each submodule stays usable individually (and exposes
# more knobs than the wrapper); the wrapper covers the common case of one
# stack with a set of sized addons.

locals {
  postgres  = lookup(var.addons, "postgres", null)
  redis     = lookup(var.addons, "redis", null)
  memcached = lookup(var.addons, "memcached", null)

  # Size presets (mini is the Heroku-style default). mini mirrors the
  # submodule defaults; small mirrors a typical small-prod stack.
  postgres_presets = {
    mini   = { storage_size = "5Gi", cpu_requests = "50m", memory_requests = "128Mi", memory_limits = "384Mi" }
    small  = { storage_size = "10Gi", cpu_requests = "250m", memory_requests = "256Mi", memory_limits = "512Mi" }
    medium = { storage_size = "20Gi", cpu_requests = "500m", memory_requests = "512Mi", memory_limits = "1Gi" }
    large  = { storage_size = "50Gi", cpu_requests = "1000m", memory_requests = "1Gi", memory_limits = "2Gi" }
  }
  redis_presets = {
    mini   = { max_memory = 256, cpu_requests = "10m", persistence_size = "1Gi" }
    small  = { max_memory = 512, cpu_requests = "20m", persistence_size = "2Gi" }
    medium = { max_memory = 1024, cpu_requests = "50m", persistence_size = "4Gi" }
    large  = { max_memory = 2048, cpu_requests = "100m", persistence_size = "8Gi" }
  }
  memcached_presets = {
    mini   = { max_memory = 256, cpu_requests = "10m", memory_requests = "64Mi" }
    small  = { max_memory = 512, cpu_requests = "20m", memory_requests = "96Mi" }
    medium = { max_memory = 1024, cpu_requests = "50m", memory_requests = "160Mi" }
    large  = { max_memory = 2048, cpu_requests = "100m", memory_requests = "320Mi" }
  }

  # Resolved plan per enabled addon (never null: size defaults to mini).
  postgres_plan  = local.postgres == null ? null : local.postgres_presets[coalesce(local.postgres.size, "mini")]
  redis_plan     = local.redis == null ? null : local.redis_presets[coalesce(local.redis.size, "mini")]
  memcached_plan = local.memcached == null ? null : local.memcached_presets[coalesce(local.memcached.size, "mini")]

  # The postgres database/user default to the stack name (RFC1035-ish: dashes
  # to underscores for a valid identifier).
  db_identifier = replace(var.name, "-", "_")
}

module "postgres" {
  count  = local.postgres != null ? 1 : 0
  source = "../postgres"

  namespace = var.namespace
  name      = "${var.name}-postgres"
  part_of   = var.name

  database = coalesce(local.postgres.database, local.db_identifier)
  username = coalesce(local.postgres.username, local.db_identifier)

  storage_size    = coalesce(local.postgres.storage_size, local.postgres_plan.storage_size)
  cpu_requests    = coalesce(local.postgres.cpu_requests, local.postgres_plan.cpu_requests)
  memory_requests = coalesce(local.postgres.memory_requests, local.postgres_plan.memory_requests)
  memory_limits   = coalesce(local.postgres.memory_limits, local.postgres_plan.memory_limits)
}

module "redis" {
  count  = local.redis != null ? 1 : 0
  source = "../redis"

  namespace = var.namespace
  name      = "${var.name}-redis"

  max_memory       = coalesce(local.redis.max_memory, local.redis_plan.max_memory)
  cpu_requests     = coalesce(local.redis.cpu_requests, local.redis_plan.cpu_requests)
  persistence_size = coalesce(local.redis.persistence_size, local.redis_plan.persistence_size)
  # coalesce keeps an explicit `false`: only null falls through to the default.
  persistence_enabled  = coalesce(local.redis.persistence_enabled, true)
  delete_pvc_on_delete = coalesce(local.redis.delete_pvc_on_delete, false)
}

module "memcached" {
  count  = local.memcached != null ? 1 : 0
  source = "../memcached"

  namespace = var.namespace
  name      = "${var.name}-memcached"

  max_memory      = coalesce(local.memcached.max_memory, local.memcached_plan.max_memory)
  cpu_requests    = coalesce(local.memcached.cpu_requests, local.memcached_plan.cpu_requests)
  memory_requests = coalesce(local.memcached.memory_requests, local.memcached_plan.memory_requests)
}
