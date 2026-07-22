output "namespace" {
  description = "Namespace the stack is deployed into"
  value       = module.app.namespace
}

output "database_host" {
  description = "Hostname of the MariaDB primary Service the app connects to"
  value       = module.mariadb.host
}
