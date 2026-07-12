# =============================================================================
# E2E Formation Tests - Runs against a real Kind cluster
# =============================================================================
# Deploys a two-process formation (web echo-server + headless worker) behind
# ingress-nginx and verifies the full env wiring (ConfigMap, Secret, generated
# SECRET_KEY_BASE) through the echo server's response.

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

# -----------------------------------------------------------------------------
# Step 1: Setup ingress controller
# -----------------------------------------------------------------------------
run "ingress_controller" {
  module {
    source = "./modules/ingress-controller"
  }
}

# -----------------------------------------------------------------------------
# Step 2: Deploy the formation
# -----------------------------------------------------------------------------
run "deploy_formation" {
  variables {
    name      = "echo"
    namespace = "formation-e2e"
    image     = "ealen/echo-server:latest"
    domain    = "echo.lvh.me"

    formation = {
      web = {
        web                = true
        ports              = { http = 80 }
        startup_probe_path = "/"
        http_probe_path    = "/"
      }
      worker = {
        command = ["/bin/sh", "-c", "sleep infinity"]
      }
    }

    env        = { FROM_CONFIG_MAP = "config-value" }
    secret_env = { FROM_SECRET = "secret-value" }

    # TLS stays on (module default) but without a cert issuer in Kind the
    # plain-HTTP check needs the redirect disabled; this also exercises the
    # ingress_annotations passthrough.
    ingress_annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "false"
    }
  }

  assert {
    condition     = output.namespace == "formation-e2e"
    error_message = "Namespace should be created and reported"
  }

  assert {
    condition     = output.web_deployment_name == "echo"
    error_message = "Web process should keep the bare app name"
  }

  assert {
    condition     = output.deployment_names.worker == "echo-worker"
    error_message = "Worker process should be named <name>-<process>"
  }

  assert {
    condition     = startswith(output.secret_name, "echo-secrets-")
    error_message = "Shared Secret should be content-hash named"
  }

  assert {
    condition     = startswith(output.config_map_name, "echo-config-")
    error_message = "Shared ConfigMap should be content-hash named"
  }
}

# -----------------------------------------------------------------------------
# Step 3: Verify HTTP connectivity and env wiring end-to-end
# -----------------------------------------------------------------------------
run "verify_http" {
  module {
    source = "./modules/http"
  }

  variables {
    url            = "http://echo.lvh.me"
    max_retry      = 10
    retry_interval = 3
  }

  assert {
    condition     = output.status_code == 200
    error_message = "Expected HTTP 200 OK from the web process through the ingress"
  }

  assert {
    condition     = output.parsed.host.hostname == "echo.lvh.me"
    error_message = "Echo server should be reached via the formation domain"
  }

  assert {
    condition     = output.parsed.environment.FROM_CONFIG_MAP == "config-value"
    error_message = "env vars should reach the process via the shared ConfigMap"
  }

  assert {
    condition     = output.parsed.environment.FROM_SECRET == "secret-value"
    error_message = "secret_env vars should reach the process via the shared Secret"
  }

  assert {
    condition     = length(output.parsed.environment.SECRET_KEY_BASE) == 128
    error_message = "Generated SECRET_KEY_BASE (64 random bytes, hex) should reach the process"
  }
}
