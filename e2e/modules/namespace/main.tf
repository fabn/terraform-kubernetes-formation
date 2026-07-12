# Minimal namespace holder for addon E2E tests (addons expect the namespace
# to exist — in real compositions the caller owns it).

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.0"
    }
  }
}

variable "name" {
  description = "Namespace name"
  type        = string
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.name
  }
}

output "name" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}
