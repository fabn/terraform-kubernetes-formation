# =============================================================================
# Dragonfly Example
# =============================================================================
# The operator-backed Redis/Valkey-compatible cache/queue: master + replica
# with operator-managed automatic failover, password auth (Terraform-owned)
# and optional keyless S3 snapshots. Requires the Dragonfly operator installed
# on the cluster. The app connects through REDIS_URL — the same contract as the
# `redis` addon — but with auth on it's a credential, so it arrives via
# secret_env. The caller owns the namespace because the app's env depends on
# the addon outputs.

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "myapp"
  }
}

module "dragonfly" {
  source = "../../modules/dragonfly"

  namespace = kubernetes_namespace_v1.app.metadata[0].name
  name      = "myapp-cache"
  part_of   = "myapp"

  # HA: master + replica; the operator repoints the Service on failover, so the
  # app needs no sentinel awareness.
  replicas = 2

  # Dragonfly needs ~256Mi per io-thread; one thread keeps a cache predictable.
  threads    = 1
  memory_mib = 512

  # Optional keyless S3 snapshots: the instance pods write with their ambient
  # IAM identity, so pair this ServiceAccount with an EKS Pod Identity
  # association (or IRSA) on the bucket in your cloud infra.
  service_account_name = "myapp-dragonfly"
  snapshot = {
    s3_uri = "s3://my-backups-bucket/myapp/cache"
    cron   = "0 */6 * * *"
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

  # With auth on, the addon's env is empty and REDIS_URL (carrying the
  # password) comes in through secret_env.
  env = merge(module.dragonfly.env, {
    RAILS_ENV = "production"
  })
  secret_env = module.dragonfly.sensitive_env
}
