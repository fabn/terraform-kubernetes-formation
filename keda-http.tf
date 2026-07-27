# Request-based scale-to-zero for the web process, opted into per-app via
# `formation.<web>.scale_to_zero`. Emits the per-app KEDA HTTP objects
# (InterceptorRoute + external-push ScaledObject + interceptor Ingress) that the
# cluster-wide add-on control plane consumes. See modules/keda-http.
locals {
  # The single web process key, if the formation has one (the web validation
  # guarantees at most one). null when there is no web process.
  web_key = one([for k, p in var.formation : k if p.web])

  # Opt-in only when the web process sets scale_to_zero.
  scale_to_zero = local.web_key == null ? null : var.formation[local.web_key].scale_to_zero
}

module "keda_http" {
  source = "./modules/keda-http"
  count  = local.scale_to_zero == null ? 0 : 1

  name      = local.web_key
  namespace = local.ns
  host      = var.domain

  # The web workload's Deployment and Service both take the bare app name.
  target_service  = var.name
  target_port     = var.formation[local.web_key].ports["http"]
  deployment_name = var.name

  min_replicas       = local.scale_to_zero.min_replicas
  max_replicas       = local.scale_to_zero.max_replicas
  concurrency_target = local.scale_to_zero.concurrency_target
  cooldown_period    = local.scale_to_zero.cooldown_period
  readiness_timeout  = local.scale_to_zero.readiness_timeout
  request_timeout    = local.scale_to_zero.request_timeout

  # Join the same shared ALB as the app would have: same IngressClass (the
  # cluster default when null) and load_balancer_name.
  ingress_class_name = var.ingress_class_name
  alb                = var.alb

  # The Deployment/Service must exist before the InterceptorRoute targets them.
  depends_on = [module.process]
}
