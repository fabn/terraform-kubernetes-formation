output "interceptor_route_name" {
  description = "Name of the InterceptorRoute (in the app namespace)."
  value       = var.name
}

output "scaled_object_name" {
  description = "Name of the external-push ScaledObject (in the app namespace)."
  value       = "${var.deployment_name}-http"
}

output "ingress_name" {
  description = "Name of the interceptor Ingress (in the interceptor namespace)."
  value       = kubernetes_ingress_v1.interceptor.metadata[0].name
}
