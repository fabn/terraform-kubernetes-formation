# =============================================================================
# Postgres (CloudNativePG operator) Example
# =============================================================================
# The operator-backed Postgres addon: a CloudNativePG Cluster (primary +
# replica with operator-managed failover), a per-instance generated password
# (Terraform-owned) and optional continuous backup + PITR to S3 via the
# barman-cloud plugin. Requires the CloudNativePG operator installed on the
# cluster (and the barman-cloud plugin when backups are on). The app connects
# through DATABASE_URL — the same contract as the Bitnami `postgres` addon, so
# a stack swaps `source` (chart -> operator) with no downstream change; only
# the host differs (CloudNativePG serves the primary on `<name>-rw`). The
# caller owns the namespace because the app's env depends on the addon outputs.

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "myapp"
  }
}

module "postgres" {
  source = "../../modules/postgres-cnpg"

  namespace = kubernetes_namespace_v1.app.metadata[0].name
  name      = "myapp-pg"
  database  = "myapp"
  username  = "myapp"
  part_of   = "myapp"

  # HA: primary + replica; clients reach the primary through the operator's
  # `<name>-rw` Service, repointed on failover, so the app needs no awareness.
  instances    = 2
  storage_size = "10Gi"

  # Shutdown timings. The addon already ships drain-friendly defaults
  # (stop_delay 300s, smart_shutdown_timeout 30s) in place of CloudNativePG's
  # 1800s/180s, so a node drain or a Spot reclaim is not held up for minutes
  # (stop_delay becomes the pod terminationGracePeriodSeconds). Shown here for
  # visibility — drop the block to keep the defaults, or raise stop_delay for a
  # large database whose shutdown checkpoint legitimately needs more time.
  stop_delay             = 300
  smart_shutdown_timeout = 30

  # Optional continuous backup + PITR to S3, keyless: with no
  # credentials_secret_name the barman-cloud plugin writes with the instance
  # pods' ambient IAM identity (inheritFromIAMRole), so pair the Cluster's
  # ServiceAccount (named after the Cluster) with an EKS Pod Identity
  # association (or IRSA) on the bucket in your cloud infra. Drop the block to
  # skip backups entirely.
  backup = {
    destination_path = "s3://my-backups-bucket/myapp/pg"
    retention_policy = "30d"
  }
}

module "app" {
  source = "../.."

  name        = "myapp"
  namespace   = kubernetes_namespace_v1.app.metadata[0].name
  environment = "example"
  image       = "ghcr.io/acme/myapp:latest"
  domain      = "myapp.example.com"

  create_namespace = false

  registry_username = "example"
  registry_password = "example-token"

  formation = {
    web = {
      web   = true
      ports = { http = 3000 }
    }
    worker = {
      args           = ["bundle", "exec", "sidekiq"]
      datadog_source = "sidekiq"
    }
  }

  # PGHOST/PGPORT/PGUSER/PGDATABASE are plaintext config; DATABASE_URL and
  # PGPASSWORD carry the generated credential, so they arrive via secret_env.
  env = merge(module.postgres.env, {
    RAILS_ENV = "production"
  })
  secret_env = module.postgres.sensitive_env
}
