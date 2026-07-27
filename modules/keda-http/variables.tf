variable "name" {
  description = "Name for the InterceptorRoute and the scaling trigger reference (the web process key, e.g. \"web\")."
  type        = string
}

variable "namespace" {
  description = "Application namespace where the target Deployment/Service and the InterceptorRoute/ScaledObject live."
  type        = string
}

variable "host" {
  description = "Public host routed through the interceptor (the app's public domain)."
  type        = string
}

variable "target_service" {
  description = "Name of the web Service the interceptor forwards ready traffic to."
  type        = string
}

variable "target_port" {
  description = "Port of the web Service the interceptor forwards to."
  type        = number
}

variable "deployment_name" {
  description = "Name of the web Deployment the ScaledObject scales 0..N."
  type        = string
}

variable "min_replicas" {
  description = "Minimum replicas. 0 = scale to zero. Production should keep >= 1."
  type        = number
  default     = 0
}

variable "max_replicas" {
  description = "Maximum replicas the ScaledObject scales up to."
  type        = number
  default     = 1
}

variable "concurrency_target" {
  description = "Target concurrent requests per replica — the interceptor's scaling metric."
  type        = number
  default     = 100
}

variable "cooldown_period" {
  description = "Seconds to wait idle before scaling back toward min_replicas."
  type        = number
  default     = 60
}

variable "readiness_timeout" {
  description = "How long the interceptor buffers a request while the backend scales from zero. Per-route timeouts require add-on >= 0.15."
  type        = string
  default     = "90s"
}

variable "request_timeout" {
  description = "Total request lifecycle timeout on the interceptor."
  type        = string
  default     = "120s"
}

variable "interceptor_namespace" {
  description = "Namespace where the KEDA HTTP add-on control plane (interceptor proxy + external scaler) is installed."
  type        = string
  default     = "keda"
}

variable "ingress_class_name" {
  description = "IngressClass for the interceptor Ingress. Null uses the cluster default (the ALB class on EKS Auto Mode)."
  type        = string
  default     = null
  nullable    = true
}

variable "alb" {
  description = "ALB wiring for the interceptor Ingress. The Ingress joins the app's shared ALB via the same IngressClass and load_balancer_name — EKS Auto Mode groups by IngressClassParams, not the group.name annotation, so no group.name is set. Null renders a plain (non-ALB) Ingress."
  type = object({
    load_balancer_name = optional(string)
    listen_ports       = optional(list(map(number)), [{ HTTPS = 443 }])
  })
  default  = null
  nullable = true
}
