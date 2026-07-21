# Installs the CloudNativePG operator so the postgres-cnpg addon's Cluster CR
# has its CRD + controller. E2E scaffolding only: real clusters install the
# operator once, out of band (the managed companion in the infra repo). atomic
# makes helm wait for the operator to be healthy before the addon applies.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

resource "helm_release" "cnpg" {
  name             = "cnpg"
  namespace        = "cnpg-system"
  create_namespace = true
  chart            = "cloudnative-pg"
  repository       = "https://cloudnative-pg.github.io/charts"
  atomic           = true
}

output "namespace" {
  value = helm_release.cnpg.namespace
}
