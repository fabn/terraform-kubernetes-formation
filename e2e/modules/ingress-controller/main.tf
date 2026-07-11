# Minimal ingress-nginx controller for E2E testing with Kind

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3"
    }
  }
}

variable "namespace" {
  description = "Namespace to deploy the ingress controller"
  type        = string
  default     = "ingress-nginx"
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace_v1.this.metadata[0].name
  repository = "https://kubernetes.github.io/ingress-nginx"
  atomic     = true
  timeout    = 300

  values = [yamlencode({
    controller = {
      hostPort             = { enabled = true }
      service              = { type = "ClusterIP" }
      publishService       = { enabled = false }
      extraArgs            = { "publish-status-address" = "localhost" }
      ingressClassResource = { default = true }
      admissionWebhooks    = { enabled = false }
    }
  })]
}

output "namespace" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}
