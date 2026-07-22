# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials. Same shape as the Bitnami redis addon (REDIS_URL), so a stack
# swaps `source` with no downstream change. With auth on, REDIS_URL carries the
# password and moves to sensitive_env.

output "env" {
  description = "Plaintext connection vars (REDIS_URL when the instance runs without auth)."
  value       = var.auth ? {} : { REDIS_URL = local.redis_url }
}

output "sensitive_env" {
  description = "Credential vars (REDIS_URL with the password when auth is on)."
  sensitive   = true
  value       = var.auth ? { REDIS_URL = local.redis_url } : {}
}

output "host" {
  description = "Hostname of the Dragonfly Service (repointed to the master on failover)."
  value       = local.host
}

output "service_account_name" {
  description = "ServiceAccount used by the instance pods (target for an EKS Pod Identity association), or null."
  value       = var.service_account_name
}
