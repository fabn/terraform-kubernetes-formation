# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials.
#
# MEMCACHED_SERVERS is a plain host:port server list, deliberately NOT a
# `memcached://…` URL: memcached clients (dalli et al.) parse a host:port list,
# not a URI scheme — unlike redis:// / postgresql:// whose clients do parse the
# scheme, so prefixing one here would only force the app to strip it. This
# matches the MemCachier/Heroku server-list convention and the AWS addons
# companion (fabn/addons/aws), which emits the same host:port list
# (comma-separated across nodes) so an in-cluster / managed swap stays invisible
# to the app. Plain memcached with no SASL, so there are no credentials.
output "env" {
  description = "Plaintext connection var for the application cache store: a comma-separated host:port memcached server list (a single node here)."
  value = {
    MEMCACHED_SERVERS = "${module.memcached.service_name}:11211"
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
