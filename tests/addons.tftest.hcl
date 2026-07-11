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

# Memcached: Heroku-legacy var name, no credentials
run "memcached_env_contract" {
  command = apply

  module {
    source = "./modules/memcached"
  }

  variables {
    namespace = "addon-test"
  }

  assert {
    condition     = output.env.MEMCACHIER_SERVERS == "memcached:11211"
    error_message = "MEMCACHIER_SERVERS should target the memcached Service"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "Memcached addon has no SASL: sensitive_env must be empty"
  }
}
