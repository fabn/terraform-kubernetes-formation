# =============================================================================
# CloudNativePG addon contract tests
# =============================================================================
# The operator-backed postgres addon must expose the same env / sensitive_env
# contract as the Bitnami-chart addon, so callers swap `source` with no change.

mock_provider "kubernetes" {}
mock_provider "random" {}

# Connection vars point at the operator-managed <name>-rw Service.
run "cnpg_env_contract" {
  command = apply

  module {
    source = "./modules/postgres-cnpg"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
  }

  assert {
    condition     = output.env.PGHOST == "pg-rw"
    error_message = "PGHOST should target the CloudNativePG read-write Service"
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
    condition     = endswith(output.sensitive_env.DATABASE_URL, "@pg-rw:5432/myapp")
    error_message = "DATABASE_URL should target the -rw host / database"
  }

  assert {
    condition     = output.sensitive_env.PGPASSWORD == random_password.app.result
    error_message = "PGPASSWORD should be the generated password"
  }

  assert {
    condition     = output.host == "pg-rw"
    error_message = "host output should be the -rw Service"
  }
}

# Custom name drives every derived Service / resource name.
run "cnpg_custom_name" {
  command = apply

  module {
    source = "./modules/postgres-cnpg"
  }

  variables {
    name      = "myapp-postgres"
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
  }

  assert {
    condition     = output.host == "myapp-postgres-rw"
    error_message = "host should follow the Cluster name"
  }

  assert {
    condition     = endswith(output.sensitive_env.DATABASE_URL, "@myapp-postgres-rw:5432/myapp")
    error_message = "DATABASE_URL host should follow the Cluster name"
  }
}

# The basic-auth Secret carries the owner credentials handed to the operator.
run "cnpg_owner_secret" {
  command = apply

  module {
    source = "./modules/postgres-cnpg"
  }

  variables {
    name      = "pg"
    namespace = "addon-test"
    database  = "myapp"
    username  = "owner1"
  }

  assert {
    condition     = kubernetes_secret_v1.app_cred.type == "kubernetes.io/basic-auth"
    error_message = "owner Secret must be basic-auth so initdb can consume it"
  }

  assert {
    condition     = kubernetes_secret_v1.app_cred.data.username == "owner1"
    error_message = "owner Secret username should be the requested role"
  }
}

# QoS Guaranteed: CPU limit defaults to the CPU request.
run "cnpg_guaranteed_qos" {
  command = apply

  module {
    source = "./modules/postgres-cnpg"
  }

  variables {
    namespace    = "addon-test"
    database     = "myapp"
    username     = "myapp"
    cpu_requests = "250m"
  }

  assert {
    condition     = local.resources.requests.cpu == local.resources.limits.cpu
    error_message = "CPU request should equal CPU limit (QoS Guaranteed) by default"
  }
}

# Backup is opt-in: no ObjectStore / ScheduledBackup unless configured.
run "cnpg_backup_disabled_by_default" {
  command = apply

  module {
    source = "./modules/postgres-cnpg"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
  }

  assert {
    condition     = length(kubernetes_manifest.object_store) == 0 && length(kubernetes_manifest.scheduled_backup) == 0
    error_message = "no backup resources should exist when backup is null"
  }
}

# Invalid anti-affinity type is rejected.
run "cnpg_rejects_bad_anti_affinity" {
  command = plan

  module {
    source = "./modules/postgres-cnpg"
  }

  variables {
    namespace              = "addon-test"
    database               = "myapp"
    username               = "myapp"
    pod_anti_affinity_type = "banana"
  }

  expect_failures = [var.pod_anti_affinity_type]
}
