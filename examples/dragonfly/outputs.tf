output "namespace" {
  description = "Namespace the stack is deployed into"
  value       = module.app.namespace
}

output "cache_host" {
  description = "Hostname of the Dragonfly Service (repointed to the master on failover)"
  value       = module.dragonfly.host
}
