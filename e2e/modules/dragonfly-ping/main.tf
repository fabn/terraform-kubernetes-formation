# Connectivity check: a Job that AUTHs and PINGs the Dragonfly Service, proving
# the addon's REDIS_URL host and password actually work end to end. The apply
# blocks on the Job completing; a wrong host/password fails the PING, the Job
# never completes, and the run fails.

terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "namespace" {
  type = string
}

variable "name" {
  type = string # Dragonfly instance name == Service host
}

variable "auth_secret" {
  type = string # Secret holding the password under key `password`
}

resource "kubernetes_manifest" "ping" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = "${var.name}-ping"
      namespace = var.namespace
    }
    spec = {
      backoffLimit = 3
      template = {
        spec = {
          restartPolicy = "Never"
          containers = [{
            name    = "ping"
            image   = "redis:7-alpine"
            command = ["sh", "-c", "redis-cli -h ${var.name} ping | grep -q PONG"]
            env = [{
              name = "REDISCLI_AUTH" # redis-cli AUTHs with this
              valueFrom = {
                secretKeyRef = { name = var.auth_secret, key = "password" }
              }
            }]
          }]
        }
      }
    }
  }

  wait {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "3m"
  }
}
