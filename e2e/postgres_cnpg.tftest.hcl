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
    namespace    = run.namespace.name
    name         = "e2e-cnpg"
    database     = "myapp"
    username     = "myapp"
    storage_size = "1Gi"
    # part_of populates spec.inheritedMetadata.labels while annotations stay
    # empty — the exact shape that used to leave a perpetual
    # `spec.inheritedMetadata.annotations = (known after apply)` diff (#32).
    part_of        = "e2e"
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

# Step 4: idempotency guard (#32). Re-plan the *same* Cluster against the live
# state. A perpetual diff (e.g. the operator normalising away a null
# spec.inheritedMetadata.annotations we sent) would plan an update and mark the
# resource's computed `object` "known after apply", so the assertion below can't
# evaluate and the run fails. A clean plan keeps `object` known → this passes
# only when the addon is idempotent.
run "postgres_cnpg_idempotent" {
  command = plan

  module {
    source = "../modules/postgres-cnpg"
  }

  variables {
    namespace      = run.namespace.name
    name           = "e2e-cnpg"
    database       = "myapp"
    username       = "myapp"
    storage_size   = "1Gi"
    part_of        = "e2e"
    wait_for_ready = true
  }

  # On a perpetual diff the re-plan marks this exact field "known after apply",
  # so the condition can't evaluate and the run fails; a clean plan keeps it a
  # concrete (empty) map. This is the field that used to drift (#32).
  assert {
    condition     = length(kubernetes_manifest.cluster.object.spec.inheritedMetadata.annotations) == 0
    error_message = "postgres-cnpg is not idempotent: a re-plan still changes spec.inheritedMetadata.annotations (perpetual diff, #32)"
  }
}
