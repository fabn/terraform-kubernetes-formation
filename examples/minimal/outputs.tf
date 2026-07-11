output "namespace" {
  description = "Namespace the stack is deployed into"
  value       = module.app.namespace
}

output "deployment_names" {
  description = "Map of formation key => Deployment name"
  value       = module.app.deployment_names
}
