output "namespace" {
  value = local.ns
}

output "image" {
  value = var.image
}

output "web_deployment_name" {
  description = "Name of the web process Deployment (equals var.name); null when the formation has no web process."
  value       = one([for k, p in var.formation : var.name if p.web])
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
