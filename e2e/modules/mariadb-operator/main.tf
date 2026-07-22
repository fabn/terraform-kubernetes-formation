# Installs the mariadb-operator (CRDs chart first, then the controller) so the
# mariadb addon's MariaDB CR has its CRD + controller + webhook. E2E scaffolding
# only: real clusters install the operator once, out of band (the managed
# companion in the infra repo). atomic makes helm wait for each release to be
# healthy before the next step applies.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

resource "helm_release" "crds" {
  name             = "mariadb-operator-crds"
  namespace        = "mariadb-system"
  create_namespace = true
  chart            = "mariadb-operator-crds"
  repository       = "https://helm.mariadb.com/mariadb-operator"
  atomic           = true
}

resource "helm_release" "operator" {
  name       = "mariadb-operator"
  namespace  = "mariadb-system"
  chart      = "mariadb-operator"
  repository = "https://helm.mariadb.com/mariadb-operator"
  atomic     = true

  depends_on = [helm_release.crds]
}

output "namespace" {
  value = helm_release.operator.namespace
}
