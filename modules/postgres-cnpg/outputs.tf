# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials. Identical shape to the Bitnami-chart postgres addon, so a stack
# swaps `source` (chart -> operator) with no downstream change. Only the host
# differs: CloudNativePG serves the primary on `<name>-rw`.

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
    DATABASE_URL = "postgresql://${var.username}:${random_password.app.result}@${local.host}:5432/${var.database}"
    PGPASSWORD   = random_password.app.result
  }
}

output "host" {
  description = "Hostname of the CloudNativePG read-write (primary) Service."
  value       = local.host
}

output "cluster_name" {
  description = "Name of the CloudNativePG Cluster resource."
  value       = var.name
}
