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

  values = [
    templatefile("${path.module}/postgres-values.yaml", {
      storageSize    = var.storage_size
      cpuRequests    = var.cpu_requests
      memoryRequests = var.memory_requests
      memoryLimits   = var.memory_limits
    })
  ]

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
  ]
}
