# =============================================================================
# Memcached addon tests
# =============================================================================

mock_provider "kubernetes" {}

# Extra labels must reach the pod template, so Datadog Unified Service Tagging
# (tags.datadoghq.com/*) can be attached to the cache the same way as to the
# other operator-backed addons.
run "labels_propagate_to_pods" {
  command = plan

  module {
    source = "./modules/memcached"
  }

  variables {
    namespace = "addon-test"
    name      = "myapp-memcached"
    labels = {
      "tags.datadoghq.com/env"     = "test"
      "tags.datadoghq.com/service" = "myapp-memcached"
    }
  }

  assert {
    condition = (
      module.memcached.deployment.spec[0].template[0].metadata[0].labels["tags.datadoghq.com/env"] == "test" &&
      module.memcached.deployment.spec[0].template[0].metadata[0].labels["tags.datadoghq.com/service"] == "myapp-memcached"
    )
    error_message = "Extra labels should propagate to the memcached pod template (for Datadog UST)"
  }
}
