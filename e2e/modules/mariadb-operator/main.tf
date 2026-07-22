# Installs the mariadb-operator (CRDs chart first, then the controller) so the
# mariadb addon's MariaDB CR has its CRD + controller + webhook. E2E scaffolding
# only: real clusters install the operator once, out of band (the managed
# companion in the infra repo). atomic makes helm wait for each release to be
# healthy before the next step applies.
#
# Charts come from the OCI registry (the legacy https://helm.mariadb.com repo is
# deprecated), pinned to the same version the infra repo installs so the E2E
# exercises the real CR schema.

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
  version          = "26.6.0"
  repository       = "oci://ghcr.io/mariadb-operator/charts"
  atomic           = true
}

resource "helm_release" "operator" {
  name       = "mariadb-operator"
  namespace  = "mariadb-system"
  chart      = "mariadb-operator"
  version    = "26.6.0"
  repository = "oci://ghcr.io/mariadb-operator/charts"
  atomic     = true

  depends_on = [helm_release.crds]
}

output "namespace" {
  value = helm_release.operator.namespace
}
