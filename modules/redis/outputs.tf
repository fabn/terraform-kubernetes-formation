output "env" {
  description = "Plaintext connection vars for Rails/Sidekiq."
  value = {
    REDIS_URL = "redis://${helm_release.redis.name}-master:6379"
  }
}

output "sensitive_env" {
  description = "Always empty (in-cluster Redis runs without auth); present to satisfy the addon contract."
  sensitive   = true
  value       = {}
}

output "host" {
  description = "Hostname of the redis master Service."
  value       = "${helm_release.redis.name}-master"
}
