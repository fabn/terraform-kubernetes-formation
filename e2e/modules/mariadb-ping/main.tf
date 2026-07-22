# Connectivity check: a Job that runs `SELECT 1` against the MariaDB Service as
# the application user, proving the addon's host + generated password actually
# work end to end. The apply blocks on the Job completing; a wrong host, user or
# password fails the query, the Job never completes, and the run fails.

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

variable "host" {
  type = string # Service the app connects to (<name> standalone / <name>-primary HA)
}

variable "username" {
  type = string
}

variable "database" {
  type = string
}

variable "password_secret" {
  type = string # Secret holding the app password under key `password`
}

resource "kubernetes_manifest" "ping" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = "${var.host}-ping"
      namespace = var.namespace
    }
    spec = {
      backoffLimit = 3
      template = {
        spec = {
          restartPolicy = "Never"
          containers = [{
            name    = "ping"
            image   = "mariadb:11"
            command = ["sh", "-c", "mariadb -h ${var.host} -u ${var.username} -D ${var.database} -e 'SELECT 1'"]
            env = [{
              name = "MYSQL_PWD" # the mariadb client authenticates with this
              valueFrom = {
                secretKeyRef = { name = var.password_secret, key = "password" }
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
