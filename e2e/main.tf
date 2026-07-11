# E2E Test Module
# This module references the parent formation module for testing

module "formation" {
  source = "../"

  name        = var.name
  namespace   = var.namespace
  environment = var.environment
  image       = var.image
  domain      = var.domain

  create_namespace = var.create_namespace

  registry_username = var.registry_username
  registry_password = var.registry_password

  formation = var.formation

  env        = var.env
  secret_env = var.secret_env

  ingress_annotations = var.ingress_annotations
}
