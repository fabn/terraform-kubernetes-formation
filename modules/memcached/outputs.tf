# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials.
#
# MEMCACHED_SERVER_URL mirrors the AWS addons companion (fabn/addons/aws) so
# an in-cluster / managed swap stays invisible to the app: a scheme-prefixed
# `memcached://host:port` URL (a single node here; the AWS addon emits a
# comma-separated list of every cache node). Plain memcached with no SASL, so
# there are no credentials to output.
output "env" {
  description = "Plaintext connection var for the application cache store: a memcached://host:port URL."
  value = {
    MEMCACHED_SERVER_URL = "memcached://${module.memcached.service_name}:11211"
  }
}

output "sensitive_env" {
  description = "Always empty (no SASL); present to satisfy the addon contract."
  sensitive   = true
  value       = {}
}

output "host" {
  description = "Hostname of the memcached Service."
  value       = module.memcached.service_name
}
