output "namespace" {
  description = "Namespace the stack is deployed into"
  value       = module.app.namespace
}

output "deployment_names" {
  description = "Map of formation key => Deployment name"
  value       = module.app.deployment_names
}

output "database_host" {
  description = "Hostname of the Postgres primary Service"
  value       = module.postgres.host
}

output "redis_host" {
  description = "Hostname of the Redis master Service"
  value       = module.redis.host
}
