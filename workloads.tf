# One fabn/workload/kubernetes instance per formation entry. The web process
# keeps the bare app name (Heroku-like: `myapp` + `myapp-worker`), gets
# the Service/Ingress/probes; every other process runs headless with
# `service_type = null` — a containerPort may still be declared (e.g. an
# in-process metrics exporter reached on the pod IP by autodiscovery checks).
module "process" {
  source  = "fabn/workload/kubernetes"
  version = "~> 0.6"

  for_each = var.formation

  name      = each.value.web ? var.name : "${var.name}-${each.key}"
  namespace = local.ns
  image     = var.image
  replicas  = each.value.replicas

  command = each.value.command
  args    = each.value.args
  ports   = each.value.ports

  service_type = each.value.web ? "ClusterIP" : null

  startup_probe_path = each.value.startup_probe_path
  http_probe_path    = each.value.http_probe_path

  cpu_requests    = each.value.cpu_requests
  memory_requests = each.value.memory_requests
  memory_limits   = each.value.memory_limits

  image_pull_secrets = module.registry_credentials.name
  secret_refs        = [module.secrets.name]
  config_map_refs    = [module.config.name]

  ingress_hostnames   = each.value.web ? [var.domain] : []
  ingress_class_name  = var.ingress_class_name
  ingress_annotations = each.value.web ? var.ingress_annotations : {}
  alb                 = each.value.web ? var.alb : null

  datadog_enabled  = var.datadog_enabled
  datadog_ust_tags = local.datadog_ust_tags
  datadog_log_config = {
    service = local.datadog_service
    source  = coalesce(each.value.datadog_source, each.value.web ? "rails" : each.key)
  }
  datadog_checks = each.value.datadog_checks
}
