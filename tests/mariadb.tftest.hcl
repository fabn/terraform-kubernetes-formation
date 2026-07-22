# =============================================================================
# mariadb addon contract tests
# =============================================================================
# Same env / sensitive_env contract as the postgres addons (DATABASE_URL), so a
# MySQL-family stack swaps `source` with no downstream change. Host is
# `<name>-primary` in HA, `<name>` when standalone.

mock_provider "kubernetes" {}
mock_provider "random" {}

# HA default (replicas = 2): host is <name>-primary, replication is enabled.
run "mariadb_ha_contract" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
    part_of   = "myapp"
  }

  assert {
    condition     = output.host == "mariadb-primary"
    error_message = "HA host should be the <name>-primary Service"
  }

  assert {
    condition     = startswith(nonsensitive(output.sensitive_env.DATABASE_URL), "mysql2://myapp:")
    error_message = "DATABASE_URL should be a mysql2 URL for the app user"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.DATABASE_URL), "@mariadb-primary:3306/myapp")
    error_message = "DATABASE_URL should target the -primary host / database on 3306"
  }

  assert {
    condition     = output.env.MYSQL_HOST == "mariadb-primary" && output.env.MYSQL_PORT == "3306" && output.env.MYSQL_USER == "myapp" && output.env.MYSQL_DATABASE == "myapp"
    error_message = "plaintext connection vars should be fully populated"
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.replication.enabled == true && kubernetes_manifest.mariadb.manifest.spec.replication.primary.autoFailover == true
    error_message = "HA should enable replication with automatic failover"
  }

  # inheritMetadata (correct field name) must carry both labels and annotations.
  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.inheritMetadata.labels["app.kubernetes.io/part-of"] == "myapp" && can(kubernetes_manifest.mariadb.manifest.spec.inheritMetadata.annotations)
    error_message = "inheritMetadata should carry both labels and annotations"
  }
}

# Standalone (replicas = 1): host is the plain <name> Service, no replication.
run "mariadb_standalone" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace = "addon-test"
    name      = "db"
    database  = "app"
    username  = "app"
    replicas  = 1
  }

  assert {
    condition     = output.host == "db"
    error_message = "standalone host should be the plain <name> Service"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.DATABASE_URL), "@db:3306/app")
    error_message = "DATABASE_URL should target the standalone host"
  }

  assert {
    condition     = !can(kubernetes_manifest.mariadb.manifest.spec.replication)
    error_message = "standalone should not set a replication block"
  }
}

# Keyless S3 backup: PhysicalBackup present, no static-key refs, SA on the Job.
run "mariadb_backup_keyless" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace            = "addon-test"
    database             = "app"
    username             = "app"
    service_account_name = "app-mariadb"
    backup               = { bucket = "backups", prefix = "app", region = "eu-south-1" }
  }

  assert {
    condition     = kubernetes_manifest.physical_backup[0].manifest.spec.storage.s3.bucket == "backups"
    error_message = "backup should target the S3 bucket"
  }

  # The operator requires an explicit endpoint; it is derived from the region.
  assert {
    condition     = kubernetes_manifest.physical_backup[0].manifest.spec.storage.s3.endpoint == "s3.eu-south-1.amazonaws.com"
    error_message = "backup should derive the AWS S3 endpoint from the region"
  }

  assert {
    condition     = !can(kubernetes_manifest.physical_backup[0].manifest.spec.storage.s3.accessKeyIdSecretKeyRef)
    error_message = "keyless backup should omit static-key refs"
  }

  # The service account is set at the top level of the PhysicalBackup spec.
  assert {
    condition     = kubernetes_manifest.physical_backup[0].manifest.spec.serviceAccountName == "app-mariadb"
    error_message = "keyless backup Job should run under the service account"
  }
}

# Adoption: bootstrap the instance from a logical dump in S3.
run "mariadb_bootstrap_from" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace            = "addon-test"
    database             = "app"
    username             = "app"
    service_account_name = "app-mariadb"
    bootstrap_from       = { bucket = "dumps", prefix = "app", region = "eu-south-1", target_recovery_time = "2026-07-22T10:00:00Z" }
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.bootstrapFrom.s3.bucket == "dumps"
    error_message = "bootstrapFrom should point at the dump bucket"
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.bootstrapFrom.targetRecoveryTime == "2026-07-22T10:00:00Z"
    error_message = "bootstrapFrom should carry the target recovery time"
  }
}
