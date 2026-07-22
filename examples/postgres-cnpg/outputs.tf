output "namespace" {
  description = "Namespace the stack is deployed into"
  value       = module.app.namespace
}

output "database_host" {
  description = "Hostname of the CloudNativePG read-write (primary) Service"
  value       = module.postgres.host
}
