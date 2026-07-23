# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials. Same shape as the Bitnami redis addon (REDIS_URL by default), so
# a stack swaps `source` with no downstream change. The URL variable name is
# `url_env_var` (default REDIS_URL) so a dedicated cache can emit e.g.
# REDIS_CACHE_URL alongside a primary Redis. With auth on, the URL carries the
# password and moves to sensitive_env.

output "env" {
  description = "Plaintext connection vars (the url_env_var URL when the instance runs without auth)."
  value       = var.auth ? {} : { (var.url_env_var) = local.redis_url }
}

output "sensitive_env" {
  description = "Credential vars (the url_env_var URL with the password when auth is on)."
  sensitive   = true
  value       = var.auth ? { (var.url_env_var) = local.redis_url } : {}
}

output "host" {
  description = "Hostname of the Dragonfly Service (repointed to the master on failover)."
  value       = local.host
}

output "service_account_name" {
  description = "ServiceAccount used by the instance pods (target for an EKS Pod Identity association), or null."
  value       = var.service_account_name
}
