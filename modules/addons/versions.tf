terraform {
  required_version = ">= 1.9"

  # Declares the whole subtree's providers: kubernetes (memcached workload),
  # helm (postgres/redis Bitnami charts) and random (postgres password).
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
