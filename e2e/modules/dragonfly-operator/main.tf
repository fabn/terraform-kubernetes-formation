# Installs the Dragonfly operator so the dragonfly addon's CR has its CRD +
# controller. E2E scaffolding only: real clusters install the operator once,
# out of band. atomic makes helm wait for the operator to be healthy before the
# addon applies.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

resource "helm_release" "dragonfly_operator" {
  name             = "dragonfly-operator"
  namespace        = "dragonfly-system"
  create_namespace = true
  chart            = "dragonfly-operator"
  version          = "v1.6.1"
  repository       = "oci://ghcr.io/dragonflydb/dragonfly-operator/helm"
  atomic           = true
}

output "namespace" {
  value = helm_release.dragonfly_operator.namespace
}
