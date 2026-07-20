# The merged env vars of every enabled addon: plug them straight into the
# formation module (`env` / `secret_env`), Heroku-addon style.

output "env" {
  description = "Merged plaintext config vars of every enabled addon."
  value = merge(
    try(module.postgres[0].env, {}),
    try(module.redis[0].env, {}),
    try(module.memcached[0].env, {}),
  )
}

output "sensitive_env" {
  description = "Merged credential vars of every enabled addon."
  sensitive   = true
  value = merge(
    try(module.postgres[0].sensitive_env, {}),
    try(module.redis[0].sensitive_env, {}),
    try(module.memcached[0].sensitive_env, {}),
  )
}

output "postgres" {
  description = "PostgreSQL addon connection details; null when the addon is not enabled."
  value = local.postgres == null ? null : {
    host     = module.postgres[0].host
    database = coalesce(local.postgres.database, local.db_identifier)
    username = coalesce(local.postgres.username, local.db_identifier)
  }
}

output "redis" {
  description = "Redis addon connection details; null when the addon is not enabled."
  value = local.redis == null ? null : {
    host = module.redis[0].host
  }
}

output "memcached" {
  description = "Memcached addon connection details; null when the addon is not enabled."
  value = local.memcached == null ? null : {
    host = module.memcached[0].host
  }
}
