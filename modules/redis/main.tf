# Redis addon: standalone Bitnami chart, no sentinel / replica / metrics,
# inheriting the bitnamilegacy image trick that lets chart >= 15.x pull from
# the legacy registry (global.security.allowInsecureImages + image.repository
# overrides). Auth is disabled in-cluster, so there are no credentials to
# output.

resource "helm_release" "redis" {
  namespace  = var.namespace
  name       = var.name
  chart      = "redis"
  version    = var.chart_version
  timeout    = 300
  repository = "oci://registry-1.docker.io/bitnamicharts"

  values = [
    templatefile("${path.module}/redis-values.yaml", {
      persistenceEnabled = var.persistence_enabled
      persistenceSize    = var.persistence_size
      deletePvcOnDelete  = var.delete_pvc_on_delete
      cpuRequests        = var.cpu_requests
      maxMemory          = "${var.max_memory}mb"
      memoryRequests     = "${var.max_memory}Mi"
      memoryLimits       = "${ceil(var.max_memory * 1.25)}Mi"
    })
  ]
}
