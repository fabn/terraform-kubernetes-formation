# Monitoring-role check: a Job that logs in as the Datadog role with the
# password from its Secret and asserts the role is in pg_monitor and can read
# the statistics views the check polls. The operator reconciles managed roles
# after the Cluster is applied, so the script retries before giving up; the
# apply blocks on the Job completing and fails with it.

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
  type = string
}

variable "username" {
  type = string
}

variable "database" {
  type = string
}

variable "password_secret" {
  type = string # basic-auth Secret holding the role password under `password`
}

locals {
  # One row of `t` per assertion; anything else (a failed login, a missing
  # grant, an unreadable view) leaves the expected output unmatched.
  query = join(" UNION ALL ", [
    "SELECT pg_has_role(current_user, 'pg_monitor', 'MEMBER')",
    "SELECT (count(*) > 0) FROM pg_stat_database",
    "SELECT has_function_privilege('pg_ls_waldir()', 'EXECUTE')",
  ])
}

resource "kubernetes_manifest" "ping" {
  manifest = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = "${var.host}-monitor-ping"
      namespace = var.namespace
    }
    spec = {
      backoffLimit = 0
      template = {
        spec = {
          restartPolicy = "Never"
          containers = [{
            name  = "ping"
            image = "postgres:17"
            command = ["sh", "-c", <<-EOT
              for i in $(seq 1 30); do
                out=$(psql -h ${var.host} -U ${var.username} -d ${var.database} -v ON_ERROR_STOP=1 -tAc "${local.query}") \
                  && [ "$out" = "$(printf 't\nt\nt')" ] && echo ok && exit 0
                echo "attempt $i: $out"; sleep 5
              done
              exit 1
            EOT
            ]
            env = [{
              name = "PGPASSWORD"
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
    create = "5m"
  }
}
