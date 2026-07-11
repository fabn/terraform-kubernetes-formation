# Rails (config/environments/production.rb) builds its :mem_cache_store from
# MEMCACHIER_SERVERS — the var name is a Heroku-addon legacy kept for config
# parity across deploy targets. Plain memcached with no SASL, so the
# MEMCACHIER_USERNAME / MEMCACHIER_PASSWORD pair stays unset.
output "env" {
  description = "Plaintext connection vars for the Rails cache store."
  value = {
    MEMCACHIER_SERVERS = "${module.memcached.service_name}:11211"
  }
}

output "sensitive_env" {
  description = "Always empty (no SASL); present to satisfy the addon contract."
  sensitive   = true
  value       = {}
}
