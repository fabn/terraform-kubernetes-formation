# One fabn/workload/kubernetes instance per formation entry. The web process
# keeps the bare app name (Heroku-like: `myapp` + `myapp-worker`), gets
# the Service/Ingress/probes; every other process runs headless with
# `service_type = null` — a containerPort may still be declared (e.g. an
# in-process metrics exporter reached on the pod IP by autodiscovery checks).
module "process" {
  source  = "fabn/workload/kubernetes"
  version = ">= 0.8.2, < 1.0.0"

  for_each = var.formation

  name      = each.value.web ? var.name : "${var.name}-${each.key}"
  namespace = local.ns
  image     = var.image
  # Autoscaled processes forward a null count so the field is omitted from
  # the manifest and the external autoscaler (HPA, KEDA) keeps ownership.
  # scale_to_zero is autoscaled too: its ScaledObject owns the 0..N count.
  replicas = each.value.autoscaled || each.value.scale_to_zero != null ? null : each.value.replicas

  command = each.value.command
  args    = each.value.args
  ports   = each.value.ports

  service_type = each.value.web ? "ClusterIP" : null

  startup_probe_path              = each.value.startup_probe_path
  http_probe_path                 = each.value.http_probe_path
  startup_probe_timeout_seconds   = each.value.startup_probe_timeout_seconds
  startup_probe_failure_threshold = each.value.startup_probe_failure_threshold
  probe_timeout_seconds           = each.value.probe_timeout_seconds
  probe_failure_threshold         = each.value.probe_failure_threshold

  node_affinity               = each.value.node_affinity
  node_selector               = each.value.node_selector
  pod_affinity                = each.value.pod_affinity
  pod_anti_affinity           = each.value.pod_anti_affinity
  anti_affinity               = each.value.anti_affinity
  topology_spread_constraints = each.value.topology_spread_constraints

  pdb_enabled = each.value.pdb_enabled
  pdb_config  = each.value.pdb_config

  cpu_requests    = each.value.cpu_requests
  memory_requests = each.value.memory_requests
  memory_limits   = each.value.memory_limits

  image_pull_secrets = module.registry_credentials.name
  secret_refs        = [module.secrets.name]
  config_map_refs    = [module.config.name]

  # A scale-to-zero web renders no direct Ingress: the host is owned by the
  # interceptor Ingress (keda-http.tf) so live traffic goes through the proxy,
  # not straight to the scaled-to-zero Service. The ClusterIP Service stays —
  # it is the interceptor's forward target.
  ingress_hostnames   = each.value.web && each.value.scale_to_zero == null ? [var.domain] : []
  ingress_class_name  = var.ingress_class_name
  ingress_annotations = each.value.web && each.value.scale_to_zero == null ? var.ingress_annotations : {}
  alb                 = each.value.web && each.value.scale_to_zero == null ? var.alb : null

  datadog_enabled  = var.datadog_enabled
  datadog_ust_tags = local.datadog_ust_tags
  datadog_log_config = {
    service = local.datadog_service
    source  = coalesce(each.value.datadog_source, each.value.web ? "rails" : each.key)
  }
  datadog_checks = each.value.datadog_checks
}
