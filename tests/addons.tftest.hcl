# =============================================================================
# Addon Contract Tests
# =============================================================================
# Every addon exposes `env` (plaintext config) and `sensitive_env`
# (credentials) that callers merge into the formation.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

# Postgres: connection vars point at the chart's <name>-postgresql Service
run "postgres_env_contract" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
  }

  assert {
    condition     = output.env.PGHOST == "pg-postgresql"
    error_message = "PGHOST should target the default release Service"
  }

  assert {
    condition     = output.env.PGPORT == "5432" && output.env.PGUSER == "myapp" && output.env.PGDATABASE == "myapp"
    error_message = "psql no-args vars should be fully populated"
  }

  assert {
    condition     = startswith(output.sensitive_env.DATABASE_URL, "postgresql://myapp:")
    error_message = "DATABASE_URL should embed the username"
  }

  assert {
    condition     = endswith(output.sensitive_env.DATABASE_URL, "@pg-postgresql:5432/myapp")
    error_message = "DATABASE_URL should target host/db of the release"
  }

  assert {
    condition     = output.sensitive_env.PGPASSWORD == random_password.postgres.result
    error_message = "PGPASSWORD should be the generated password"
  }

  assert {
    condition     = output.host == "pg-postgresql"
    error_message = "Host output should match the chart Service name"
  }
}

# Postgres: custom release name drives the Service name
run "postgres_custom_name" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    namespace = "addon-test"
    name      = "myapp-pg"
    database  = "myapp"
    username  = "myapp"
  }

  assert {
    condition     = output.env.PGHOST == "myapp-pg-postgresql"
    error_message = "PGHOST should follow the custom release name"
  }
}

# Redis: URL points at the chart's <name>-master Service, no credentials
run "redis_env_contract" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    namespace = "addon-test"
  }

  assert {
    condition     = output.env.REDIS_URL == "redis://redis-master:6379"
    error_message = "REDIS_URL should target the default release master Service"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "Redis addon runs without auth: sensitive_env must be empty"
  }

  assert {
    condition     = output.host == "redis-master"
    error_message = "Host output should match the master Service name"
  }
}

# Memcached: plain host:port server list, no credentials
run "memcached_env_contract" {
  command = apply

  module {
    source = "./modules/memcached"
  }

  variables {
    namespace = "addon-test"
  }

  assert {
    condition     = output.env.MEMCACHED_SERVERS == "memcached:11211"
    error_message = "MEMCACHED_SERVERS should be a host:port list targeting the Service"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "Memcached addon has no SASL: sensitive_env must be empty"
  }
}

# =============================================================================
# Wrapper contract: modules/addons composes the submodules behind one map and
# re-exports the merged env / sensitive_env.
# =============================================================================

# Merged env of a full stack, addons named <name>-<addon>
run "wrapper_merges_enabled_addons" {
  command = apply

  module {
    source = "./modules/addons"
  }

  variables {
    namespace = "addon-test"
    name      = "myapp-staging"
    addons = {
      postgres  = { size = "small" }
      redis     = { size = "mini" }
      memcached = { size = "mini" }
    }
  }

  assert {
    condition     = output.env.PGHOST == "myapp-staging-postgres-postgresql"
    error_message = "postgres addon should be named <name>-postgres"
  }

  assert {
    condition     = output.env.REDIS_URL == "redis://myapp-staging-redis-master:6379"
    error_message = "redis addon should be named <name>-redis"
  }

  assert {
    condition     = output.env.MEMCACHED_SERVERS == "myapp-staging-memcached:11211"
    error_message = "memcached addon should be named <name>-memcached"
  }

  # postgres db/user default to the stack name (dashes to underscores)
  assert {
    condition     = output.env.PGUSER == "myapp_staging" && output.env.PGDATABASE == "myapp_staging"
    error_message = "postgres db/user should default to the sanitized stack name"
  }

  assert {
    condition     = can(output.sensitive_env.PGPASSWORD) && endswith(output.sensitive_env.DATABASE_URL, "@myapp-staging-postgres-postgresql:5432/myapp_staging")
    error_message = "wrapper sensitive_env should surface the postgres credentials"
  }
}

# A disabled addon contributes nothing to the merged env
run "wrapper_omits_disabled_addons" {
  command = apply

  module {
    source = "./modules/addons"
  }

  variables {
    namespace = "addon-test"
    name      = "myapp-review"
    addons = {
      postgres = { size = "mini" }
    }
  }

  assert {
    condition     = !can(output.env.REDIS_URL) && !can(output.env.MEMCACHED_SERVERS)
    error_message = "only the postgres addon was enabled: no redis/memcached vars expected"
  }

  assert {
    condition     = output.redis == null && output.memcached == null
    error_message = "disabled addons must report null detail outputs"
  }
}

# Explicit knobs override the size preset
run "wrapper_explicit_knob_overrides_preset" {
  command = apply

  module {
    source = "./modules/addons"
  }

  variables {
    namespace = "addon-test"
    name      = "myapp-staging"
    addons = {
      postgres = { size = "mini", database = "custom_db", username = "custom_user" }
    }
  }

  assert {
    condition     = output.env.PGDATABASE == "custom_db" && output.env.PGUSER == "custom_user"
    error_message = "explicit database/username should win over the stack-name default"
  }
}

# Unsupported addon keys are rejected
run "wrapper_rejects_unknown_addon" {
  command = plan

  module {
    source = "./modules/addons"
  }

  variables {
    namespace = "addon-test"
    name      = "myapp-staging"
    addons = {
      mysql = { size = "mini" }
    }
  }

  expect_failures = [var.addons]
}
