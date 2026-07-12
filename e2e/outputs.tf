# E2E Test Outputs
# Expose parent module outputs for test assertions

output "namespace" {
  value = module.formation.namespace
}

output "image" {
  value = module.formation.image
}

output "web_deployment_name" {
  value = module.formation.web_deployment_name
}

output "deployment_names" {
  value = module.formation.deployment_names
}

output "secret_name" {
  value = module.formation.secret_name
}

output "config_map_name" {
  value = module.formation.config_map_name
}
