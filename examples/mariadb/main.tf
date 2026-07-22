# =============================================================================
# MariaDB (mariadb-operator) Example
# =============================================================================
# The operator-backed MySQL-family addon: a MariaDB with primary + replica and
# operator-managed replication + automatic failover, a Terraform-owned password
# and optional keyless S3 physical backups. Requires the mariadb-operator
# installed on the cluster. The app connects through DATABASE_URL — the same
# contract as the postgres addons — so a MySQL-family stack swaps `source` with
# no downstream change; clients reach the primary on `<name>-primary`, repointed
# on failover. The caller owns the namespace because the app's env depends on
# the addon outputs.

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "myapp"
  }
}

module "mariadb" {
  source = "../../modules/mariadb"

  namespace = kubernetes_namespace_v1.app.metadata[0].name
  name      = "myapp-db"
  database  = "myapp"
  username  = "myapp"
  part_of   = "myapp"

  # HA: primary + replica; the operator repoints `<name>-primary` on failover,
  # so the app needs no awareness.
  replicas     = 2
  storage_size = "10Gi"

  # Optional keyless S3 physical backups: with no credentials_secret_name the
  # backup Job writes with the pod's ambient IAM identity (inheritFromIAMRole),
  # so pair this ServiceAccount with an EKS Pod Identity association (or IRSA) on
  # the bucket in your cloud infra. Drop the block to skip backups.
  service_account_name = "myapp-mariadb"
  backup = {
    bucket = "my-backups-bucket"
    prefix = "myapp/db"
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

  # MYSQL_HOST/MYSQL_PORT/MYSQL_USER/MYSQL_DATABASE are plaintext config;
  # DATABASE_URL and MYSQL_PWD carry the generated credential, so they arrive
  # via secret_env.
  env = merge(module.mariadb.env, {
    RAILS_ENV = "production"
  })
  secret_env = module.mariadb.sensitive_env
}
