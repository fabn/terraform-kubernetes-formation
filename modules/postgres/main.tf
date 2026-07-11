# Bitnami Postgres addon. The password is generated per instance and stays in
# TF state + the auth Secret, so ephemeral environments need no plaintext
# secret anywhere. Extracted from modules/annamode/database.tf.

locals {
  host = "${var.name}-postgresql"
}

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "pg_auth" {
  metadata {
    name      = "${var.name}-auth"
    namespace = var.namespace
    labels = merge(
      { "app.kubernetes.io/managed-by" = "terraform" },
      var.part_of != null ? { "app.kubernetes.io/part-of" = var.part_of } : {},
    )
  }

  data = {
    password          = random_password.postgres.result
    postgres-password = random_password.postgres.result
  }
}

resource "helm_release" "postgres" {
  name       = var.name
  namespace  = var.namespace
  chart      = "postgresql"
  version    = var.chart_version
  repository = "oci://registry-1.docker.io/bitnamicharts"

  values = [file("${path.module}/postgres-values.yaml")]

  set = [
    {
      name  = "auth.username"
      value = var.username
    },
    {
      name  = "auth.database"
      value = var.database
    },
    {
      name  = "auth.existingSecret"
      value = kubernetes_secret_v1.pg_auth.metadata[0].name
    },
    {
      name  = "primary.persistence.size"
      value = var.storage_size
    },
    {
      name  = "primary.resources.requests.cpu"
      value = var.cpu_requests
    },
    {
      name  = "primary.resources.requests.memory"
      value = var.memory_requests
    },
    {
      name  = "primary.resources.limits.memory"
      value = var.memory_limits
    },
  ]
}
