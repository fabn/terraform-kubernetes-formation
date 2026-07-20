# =============================================================================
# E2E Addon Tests - Runs against a real Kind cluster
# =============================================================================
# Deploys every addon for real (Bitnami charts / workload module) and checks
# the env contract. Apply success implies readiness: helm waits for the
# release, the workload module waits for the rollout.

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-kind"
}

provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = "kind-kind"
  }
}

# -----------------------------------------------------------------------------
# Step 1: The namespace addons deploy into (the caller owns it in real use)
# -----------------------------------------------------------------------------
run "namespace" {
  module {
    source = "./modules/namespace"
  }

  variables {
    name = "addons-e2e"
  }
}

# -----------------------------------------------------------------------------
# Postgres addon
# -----------------------------------------------------------------------------
run "postgres" {
  module {
    source = "../modules/postgres"
  }

  variables {
    namespace    = run.namespace.name
    name         = "e2e-pg"
    database     = "myapp"
    username     = "myapp"
    storage_size = "1Gi"
  }

  assert {
    condition     = output.env.PGHOST == "e2e-pg-postgresql"
    error_message = "PGHOST should target the release Service"
  }

  assert {
    condition     = output.env.PGPORT == "5432" && output.env.PGUSER == "myapp" && output.env.PGDATABASE == "myapp"
    error_message = "psql no-args vars should be fully populated"
  }

  assert {
    condition     = endswith(output.sensitive_env.DATABASE_URL, "@e2e-pg-postgresql:5432/myapp")
    error_message = "DATABASE_URL should target the deployed release"
  }
}

# -----------------------------------------------------------------------------
# Redis addon (ephemeral flavour, as used by review environments)
# -----------------------------------------------------------------------------
run "redis" {
  module {
    source = "../modules/redis"
  }

  variables {
    namespace           = run.namespace.name
    name                = "e2e-redis"
    persistence_enabled = false
    max_memory          = 64
  }

  assert {
    condition     = output.env.REDIS_URL == "redis://e2e-redis-master:6379"
    error_message = "REDIS_URL should target the release master Service"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "Redis addon runs without auth: sensitive_env must be empty"
  }
}

# -----------------------------------------------------------------------------
# Memcached addon
# -----------------------------------------------------------------------------
run "memcached" {
  module {
    source = "../modules/memcached"
  }

  variables {
    namespace  = run.namespace.name
    name       = "e2e-memcached"
    max_memory = 64
  }

  assert {
    condition     = output.env.MEMCACHED_SERVER_URL == "memcached://e2e-memcached:11211"
    error_message = "MEMCACHED_SERVER_URL should be a memcached:// URL targeting the Service"
  }
}
