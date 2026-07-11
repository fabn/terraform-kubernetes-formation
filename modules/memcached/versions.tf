terraform {
  required_version = ">= 1.9"

  # No direct kubernetes resources here, but the workload child module
  # inherits the default kubernetes provider from this declaration.
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}
