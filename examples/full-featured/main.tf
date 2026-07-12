# =============================================================================
# Full Featured Example
# =============================================================================
# A Rails-shaped stack: web + worker processes, postgres/redis/memcached
# addons merged into the shared env, Datadog tagging enabled. The caller owns
# the namespace because the formation's env depends on the addon outputs.

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "myapp-review-pr-42"
  }
}

module "postgres" {
  source = "../../modules/postgres"

  namespace = kubernetes_namespace_v1.app.metadata[0].name
  name      = "myapp-pg"
  database  = "myapp"
  username  = "myapp"
  part_of   = "myapp"
}

module "redis" {
  source = "../../modules/redis"

  namespace           = kubernetes_namespace_v1.app.metadata[0].name
  name                = "myapp-redis"
  persistence_enabled = false
}

module "memcached" {
  source = "../../modules/memcached"

  namespace = kubernetes_namespace_v1.app.metadata[0].name
}

module "app" {
  source = "../.."

  name        = "myapp"
  namespace   = kubernetes_namespace_v1.app.metadata[0].name
  environment = "review-pr-42"
  image       = "ghcr.io/acme/myapp:pr-42"
  domain      = "pr-42.reviews.example.com"

  create_namespace = false

  registry_username = var.registry_username
  registry_password = var.registry_password

  formation = {
    web = {
      web                = true
      ports              = { http = 3000 }
      startup_probe_path = "/healthz"
      memory_limits      = "768Mi"
    }
    worker = {
      args           = ["bundle", "exec", "sidekiq", "-c", "2"]
      datadog_source = "sidekiq"
    }
  }

  env = merge(
    module.postgres.env,
    module.redis.env,
    module.memcached.env,
    {
      RAILS_ENV = "production"
      RACK_ENV  = "production"
    },
  )
  secret_env = module.postgres.sensitive_env

  datadog_enabled = true
  datadog_env     = "review"
  datadog_team    = "platform"
}

# One-off release task (Heroku release phase): prepare the database with the
# exact artifact being released, inheriting the runtime env (envFrom, pull
# secrets, service account) from the web Deployment. The init container gates
# on postgres readiness because backoff_limit = 0 aborts on the first failure.
module "migrate" {
  source = "../../modules/run"

  namespace  = module.app.namespace
  deployment = module.app.web_deployment_name
  image      = "ghcr.io/acme/myapp:pr-42"

  command      = ["/bin/bash", "-lc", "bin/rails db:prepare"]
  init_command = ["/bin/bash", "-lc", "until pg_isready -t 5; do echo 'waiting for postgres'; sleep 2; done"]

  # Same-root composition: defer the Deployment read to apply time so the
  # first apply works too.
  depends_on = [module.app]
}
