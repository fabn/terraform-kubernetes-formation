# Per-app wiring for the KEDA HTTP add-on (request-based scale-to-zero of a web
# process). The add-on control plane — operator, interceptor proxy, external
# scaler and the http.keda.sh CRDs — is assumed already installed cluster-wide
# in var.interceptor_namespace. This emits the three per-app objects:
#
#   1. InterceptorRoute (http.keda.sh/v1beta1) — routes the host to the target
#      Service and declares the concurrency scaling metric + timeouts.
#   2. ScaledObject (keda.sh/v1alpha1, external-push) — owns the 0..N replica
#      scaling of the target Deployment, driven by the add-on's external scaler.
#   3. Ingress in the interceptor namespace — puts the host on the app's shared
#      ALB pointing at the interceptor proxy Service (which lives in that same
#      namespace, so the Ingress must too). Live traffic is buffered here during
#      a cold start instead of hitting the scaled-to-zero app directly.
locals {
  # Stable Service names/ports of the add-on control plane (chart
  # keda-add-ons-http). The interceptor proxy takes live traffic on 8080 and
  # exposes its readiness on the admin port 9090; the external scaler serves the
  # scaling gRPC on 9090.
  interceptor_proxy_service = "keda-add-ons-http-interceptor-proxy"
  interceptor_proxy_port    = 8080
  interceptor_admin_port    = 9090
  external_scaler_service   = "keda-add-ons-http-external-scaler"
  external_scaler_grpc_port = 9090

  scaler_address = "${local.external_scaler_service}.${var.interceptor_namespace}:${local.external_scaler_grpc_port}"
}

# 1. Routing + scaling metric for the interceptor.
resource "kubernetes_manifest" "interceptor_route" {
  manifest = {
    apiVersion = "http.keda.sh/v1beta1"
    kind       = "InterceptorRoute"
    metadata = {
      name      = var.name
      namespace = var.namespace
    }
    spec = {
      target = {
        service = var.target_service
        port    = var.target_port
      }
      rules = [{ hosts = [var.host] }]
      scalingMetric = {
        concurrency = {
          targetValue = var.concurrency_target
        }
      }
      # Per-route timeouts exist only from add-on 0.15 (the 0.14 CRD has no
      # spec.timeouts and rejects this field).
      timeouts = {
        readiness = var.readiness_timeout
        request   = var.request_timeout
      }
    }
  }
}

# 2. The actual 0..N scaler for the web Deployment, fed by the external scaler.
resource "kubernetes_manifest" "scaled_object" {
  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "${var.deployment_name}-http"
      namespace = var.namespace
    }
    spec = {
      scaleTargetRef = {
        apiVersion = "apps/v1"
        kind       = "Deployment"
        name       = var.deployment_name
      }
      minReplicaCount = var.min_replicas
      maxReplicaCount = var.max_replicas
      cooldownPeriod  = var.cooldown_period
      triggers = [{
        type = "external-push"
        metadata = {
          scalerAddress    = local.scaler_address
          interceptorRoute = var.name
        }
      }]
    }
  }

  depends_on = [kubernetes_manifest.interceptor_route]
}

# 3. Host -> interceptor proxy on the app's shared ALB. Lives in the interceptor
# namespace (same as the proxy Service — the ALB controller requires the backend
# Service in the Ingress's own namespace). Joins the app's ALB via the same
# IngressClass + load_balancer_name; on EKS Auto Mode grouping is by
# IngressClassParams, so no group.name annotation is set.
resource "kubernetes_ingress_v1" "interceptor" {
  metadata {
    name      = "${var.namespace}-http-interceptor"
    namespace = var.interceptor_namespace
    annotations = var.alb == null ? {} : {
      "alb.ingress.kubernetes.io/load-balancer-name" = var.alb.load_balancer_name
      "alb.ingress.kubernetes.io/listen-ports"       = jsonencode(var.alb.listen_ports)
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      # The proxy serves app traffic on 8080; health-check it on the admin port
      # so the target group stays healthy regardless of per-route state.
      "alb.ingress.kubernetes.io/healthcheck-port" = tostring(local.interceptor_admin_port)
      "alb.ingress.kubernetes.io/healthcheck-path" = "/livez"
      "alb.ingress.kubernetes.io/success-codes"    = "200"
    }
  }

  spec {
    ingress_class_name = var.ingress_class_name

    rule {
      host = var.host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = local.interceptor_proxy_service
              port {
                number = local.interceptor_proxy_port
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.interceptor_route]
}
