# Dragonfly addon. Terraform owns the auth password (generated here and handed
# to the operator through a Secret), so REDIS_URL is a pure expression. The
# operator runs a master + replica(s) and does automatic failover behind a
# stable `<name>` Service, so the app connects with no sentinel awareness.

locals {
  host = var.name
  port = 6379

  auth_secret = "${var.name}-auth"

  labels = merge(
    { "app.kubernetes.io/managed-by" = "terraform" },
    var.part_of != null ? { "app.kubernetes.io/part-of" = var.part_of } : {},
    var.labels,
  )

  # Propagated (spec.labels) onto the operator-managed objects. managed-by is
  # left off: those objects are managed by the operator.
  inherited_labels = merge(
    var.part_of != null ? { "app.kubernetes.io/part-of" = var.part_of } : {},
    var.labels,
  )

  password  = var.auth ? random_password.auth[0].result : null
  redis_url = var.auth ? "redis://:${local.password}@${local.host}:${local.port}" : "redis://${local.host}:${local.port}"

  snapshot = var.snapshot == null ? null : merge(
    { cron = var.snapshot.cron },
    var.snapshot.s3_uri != null ? { dir = var.snapshot.s3_uri } : {},
    var.snapshot.pvc_size != null ? {
      persistentVolumeClaimSpec = {
        accessModes = ["ReadWriteOnce"]
        resources   = { requests = { storage = var.snapshot.pvc_size } }
      }
    } : {},
  )
}

resource "random_password" "auth" {
  count   = var.auth ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "auth" {
  count = var.auth ? 1 : 0
  metadata {
    name      = local.auth_secret
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    password = random_password.auth[0].result
  }
}

# ServiceAccount for the instance pods, so an external identity (EKS Pod
# Identity / IRSA) can grant them S3 access for snapshots.
resource "kubernetes_service_account_v1" "instance" {
  count = var.service_account_name != null ? 1 : 0
  metadata {
    name        = var.service_account_name
    namespace   = var.namespace
    labels      = local.labels
    annotations = var.service_account_annotations
  }
}

resource "kubernetes_manifest" "dragonfly" {
  manifest = {
    apiVersion = "dragonflydb.io/v1alpha1"
    kind       = "Dragonfly"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = local.labels
    }
    spec = merge(
      {
        replicas = var.replicas
        # Dragonfly needs ~256Mi per io-thread; pin the count so memory is
        # predictable (see the memory_mib validation).
        args = ["--proactor_threads=${var.threads}"]
        resources = {
          requests = { cpu = var.cpu_requests, memory = "${var.memory_mib}Mi" }
          limits   = { memory = "${var.memory_mib}Mi" }
        }
      },
      var.image != null ? { image = var.image } : {},
      var.auth ? {
        authentication = { passwordFromSecret = { name = local.auth_secret, key = "password" } }
      } : {},
      var.service_account_name != null ? { serviceAccountName = var.service_account_name } : {},
      length(local.inherited_labels) > 0 ? { labels = local.inherited_labels } : {},
      length(var.annotations) > 0 ? { annotations = var.annotations } : {},
      length(var.node_selector) > 0 ? { nodeSelector = var.node_selector } : {},
      length(var.tolerations) > 0 ? { tolerations = var.tolerations } : {},
      length(var.topology_spread_constraints) > 0 ? { topologySpreadConstraints = var.topology_spread_constraints } : {},
      local.snapshot != null ? { snapshot = local.snapshot } : {},
    )
  }

  # Optionally block until the operator reports the instance Ready.
  dynamic "wait" {
    for_each = var.wait_for_ready ? [1] : []
    content {
      fields = {
        "status.phase" = "Ready"
      }
    }
  }

  timeouts {
    create = var.ready_timeout
  }

  depends_on = [kubernetes_secret_v1.auth, kubernetes_service_account_v1.instance]
}
