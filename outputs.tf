output "namespace" {
  value = local.ns
}

output "image" {
  value = var.image
}

output "web_deployment_name" {
  description = "Name of the web process Deployment (equals var.name)."
  value       = var.name
}

output "deployment_names" {
  description = "Map of formation key => Deployment name."
  value       = { for k, p in var.formation : k => (p.web ? var.name : "${var.name}-${k}") }
}

output "secret_name" {
  description = "Name of the shared env Secret (content-hash suffixed)."
  value       = module.secrets.name
}

output "config_map_name" {
  description = "Name of the shared env ConfigMap (content-hash suffixed)."
  value       = module.config.name
}
