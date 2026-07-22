# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials. Same shape as the postgres addons (DATABASE_URL), so a stack that
# uses a MySQL-family database swaps `source` with no downstream change. The host
# is `<name>-primary` in HA (the operator repoints it on failover) or `<name>`
# when standalone.

output "env" {
  description = "Plaintext connection vars (MYSQL_HOST/MYSQL_PORT/MYSQL_USER/MYSQL_DATABASE), paired with MYSQL_PWD from sensitive_env."
  value = {
    MYSQL_HOST     = local.host
    MYSQL_PORT     = tostring(local.port)
    MYSQL_USER     = var.username
    MYSQL_DATABASE = var.database
  }
}

output "sensitive_env" {
  description = "Credential vars (DATABASE_URL for Rails/mysql2, MYSQL_PWD for the mysql client)."
  sensitive   = true
  value = {
    DATABASE_URL = "mysql2://${var.username}:${random_password.app.result}@${local.host}:${local.port}/${var.database}"
    MYSQL_PWD    = random_password.app.result
  }
}

output "host" {
  description = "Hostname of the Service applications connect to (`<name>-primary` in HA, `<name>` standalone)."
  value       = local.host
}

output "mariadb_name" {
  description = "Name of the MariaDB CR resource."
  value       = var.name
}

output "service_account_name" {
  description = "ServiceAccount used by the instance/backup pods (target for an EKS Pod Identity association), or null."
  value       = var.service_account_name
}
