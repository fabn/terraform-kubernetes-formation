# =============================================================================
# E2E: dragonfly addon against a real Kind cluster + Dragonfly operator
# =============================================================================
# Installs the operator, deploys the addon for real (master + replica) and waits
# for it Ready, then AUTHs + PINGs the Service through a Job — proving the
# REDIS_URL host and password work end to end.

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-kind"
}

provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = "kind-kind"
  }
}

run "operator" {
  module {
    source = "./modules/dragonfly-operator"
  }
}

run "namespace" {
  module {
    source = "./modules/namespace"
  }

  variables {
    name = "dragonfly-e2e"
  }
}

run "dragonfly" {
  module {
    source = "../modules/dragonfly"
  }

  variables {
    namespace      = run.namespace.name
    name           = "e2e-dragonfly"
    wait_for_ready = true
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.REDIS_URL), "@e2e-dragonfly:6379")
    error_message = "REDIS_URL should target the instance Service"
  }

  assert {
    condition     = output.host == "e2e-dragonfly"
    error_message = "host should be the Dragonfly Service name"
  }
}

# Real connectivity: AUTH + PING through the Service. Apply success (the Job
# completes) proves the host and password from the addon actually work.
run "connectivity" {
  module {
    source = "./modules/dragonfly-ping"
  }

  variables {
    namespace   = run.namespace.name
    name        = "e2e-dragonfly"
    auth_secret = "e2e-dragonfly-auth"
  }
}
