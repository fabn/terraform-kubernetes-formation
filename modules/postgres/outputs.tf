# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials. Consumers merge both into the app stack (env -> ConfigMap,
# sensitive_env -> Secret) Heroku-addon style.

output "env" {
  description = "Plaintext connection vars. PGHOST/PGPORT/PGUSER/PGDATABASE let `psql` inside the pod connect with no args (paired with PGPASSWORD from sensitive_env)."
  value = {
    PGHOST     = local.host
    PGPORT     = "5432"
    PGUSER     = var.username
    PGDATABASE = var.database
  }
}

output "sensitive_env" {
  description = "Credential vars (DATABASE_URL for Rails, PGPASSWORD for psql)."
  sensitive   = true
  value = {
    DATABASE_URL = "postgresql://${var.username}:${random_password.postgres.result}@${local.host}:5432/${var.database}"
    PGPASSWORD   = random_password.postgres.result
  }
}

output "host" {
  description = "Hostname of the Postgres primary Service."
  value       = local.host
}
