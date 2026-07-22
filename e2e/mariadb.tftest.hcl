# =============================================================================
# E2E: mariadb addon against a real Kind cluster + mariadb-operator
# =============================================================================
# Installs the operator, deploys the addon for real (standalone, so it fits the
# single-node Kind cluster) and waits for it Ready, then runs `SELECT 1` through
# a Job — proving the addon's host, user and generated password work end to end.
# HA (<name>-primary) service naming is covered by the unit tests; backups need
# real S3 and are validated in the infra repo, not here (same as postgres-cnpg).

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
    source = "./modules/mariadb-operator"
  }
}

run "namespace" {
  module {
    source = "./modules/namespace"
  }

  variables {
    name = "mariadb-e2e"
  }
}

run "mariadb" {
  module {
    source = "../modules/mariadb"
  }

  variables {
    namespace            = run.namespace.name
    name                 = "e2e-mariadb"
    database             = "myapp"
    username             = "myapp"
    replicas             = 1
    storage_size         = "1Gi"
    service_account_name = "e2e-mariadb"
    wait_for_ready       = true
  }

  assert {
    condition     = output.host == "e2e-mariadb"
    error_message = "standalone host should be the plain <name> Service"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.DATABASE_URL), "@e2e-mariadb:3306/myapp")
    error_message = "DATABASE_URL should target the deployed host / database"
  }
}

# Real connectivity: SELECT 1 as the app user through the Service. Apply success
# (the Job completes) proves the host, user and password from the addon work.
run "connectivity" {
  module {
    source = "./modules/mariadb-ping"
  }

  variables {
    namespace       = run.namespace.name
    host            = "e2e-mariadb"
    username        = "myapp"
    database        = "myapp"
    password_secret = "e2e-mariadb-app"
  }
}
