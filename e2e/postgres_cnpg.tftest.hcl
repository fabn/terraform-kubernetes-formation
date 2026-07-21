# =============================================================================
# E2E: postgres-cnpg addon against a real Kind cluster + CloudNativePG operator
# =============================================================================
# Installs the operator, then deploys the addon for real and waits for the
# Cluster to be healthy (wait_for_ready) — so a passing apply means Postgres is
# up and the database was created. Asserts the same env contract as the
# Bitnami-chart postgres addon, proving the drop-in swap works end to end.

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

# Step 1: the cluster-wide operator (CRDs + controller).
run "operator" {
  module {
    source = "./modules/cnpg-operator"
  }
}

# Step 2: a namespace for the instance (the caller owns it in real use).
run "namespace" {
  module {
    source = "./modules/namespace"
  }

  variables {
    name = "cnpg-e2e"
  }
}

# Step 3: the addon. wait_for_ready gates the apply on the healthy phase, so a
# successful apply proves the database exists.
run "postgres_cnpg" {
  module {
    source = "../modules/postgres-cnpg"
  }

  variables {
    namespace      = run.namespace.name
    name           = "e2e-cnpg"
    database       = "myapp"
    username       = "myapp"
    storage_size   = "1Gi"
    wait_for_ready = true
  }

  assert {
    condition     = output.env.PGHOST == "e2e-cnpg-rw"
    error_message = "PGHOST should target the CloudNativePG read-write Service"
  }

  assert {
    condition     = output.env.PGPORT == "5432" && output.env.PGUSER == "myapp" && output.env.PGDATABASE == "myapp"
    error_message = "psql no-args vars should be fully populated"
  }

  assert {
    condition     = endswith(output.sensitive_env.DATABASE_URL, "@e2e-cnpg-rw:5432/myapp")
    error_message = "DATABASE_URL should target the deployed -rw host / database"
  }
}
