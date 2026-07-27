# =============================================================================
# KEDA HTTP scale-to-zero (formation.<web>.scale_to_zero)
# =============================================================================

mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  name        = "myapp"
  namespace   = "myapp-test"
  environment = "test"
  image       = "ghcr.io/acme/myapp:1.0.0"
  domain      = "myapp.example.com"

  registry_username = "ci"
  registry_password = "token"

  alb = {
    load_balancer_name = "shared-external"
  }

  formation = {
    web = {
      web                = true
      ports              = { http = 3000 }
      startup_probe_path = "/healthz"
    }
  }
}

# Off by default: no scale_to_zero => the add-on submodule is not instantiated.
run "web_without_scale_to_zero" {
  command = plan

  assert {
    condition     = length(module.keda_http) == 0
    error_message = "Without scale_to_zero the keda_http submodule must not be created."
  }
}

# On: the three per-app objects are named off the app + web process.
run "web_with_scale_to_zero" {
  command = plan

  variables {
    formation = {
      web = {
        web                = true
        ports              = { http = 3000 }
        startup_probe_path = "/healthz"
        scale_to_zero      = { max_replicas = 3 }
      }
    }
  }

  assert {
    condition     = length(module.keda_http) == 1
    error_message = "scale_to_zero on the web process must create the keda_http submodule."
  }

  assert {
    condition     = module.keda_http[0].interceptor_route_name == "web"
    error_message = "InterceptorRoute is named after the web process key."
  }

  assert {
    condition     = module.keda_http[0].scaled_object_name == "myapp-http"
    error_message = "ScaledObject is named <web-deployment>-http."
  }

  assert {
    condition     = module.keda_http[0].ingress_name == "myapp-test-http-interceptor"
    error_message = "Interceptor Ingress is named <namespace>-http-interceptor."
  }
}

# scale_to_zero on a non-web process is rejected.
run "scale_to_zero_requires_web" {
  command = plan

  variables {
    formation = {
      web = {
        web   = true
        ports = { http = 3000 }
      }
      worker = {
        args          = ["bundle", "exec", "sidekiq"]
        scale_to_zero = { max_replicas = 2 }
      }
    }
  }

  expect_failures = [var.formation]
}

# Production must keep a warm floor (min_replicas >= 1).
run "production_requires_warm_floor" {
  command = plan

  variables {
    environment = "production"
    formation = {
      web = {
        web           = true
        ports         = { http = 3000 }
        scale_to_zero = { min_replicas = 0 }
      }
    }
  }

  expect_failures = [var.formation]
}
