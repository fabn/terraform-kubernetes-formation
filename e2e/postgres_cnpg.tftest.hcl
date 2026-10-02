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

    # Placement is exercised here because the mocked unit tests can't: the manifest
    # is sent as-is, so a field the CRD doesn't define (or one it stores in a
    # different shape) only fails against a real API server. Both terms are
    # satisfiable on single-node Kind.
    node_affinity = {
      required  = [{ key = "kubernetes.io/os", operator = "In", values = ["linux"] }]
      preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["amd64", "arm64"] }]
    }
    topology_spread_constraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway" # single node: DoNotSchedule would pin a replica Pending
    }]
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

  # Read back from the API server: the Cluster stored the placement as sent, and
  # topologySpreadConstraints stayed cluster-level (it is not part of the affinity
  # block, unlike the anti-affinity knobs).
  assert {
    condition     = kubernetes_manifest.cluster.object.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key == "kubernetes.io/os"
    error_message = "the stored Cluster should carry the required node affinity term"
  }

  assert {
    condition     = kubernetes_manifest.cluster.object.spec.topologySpreadConstraints[0].topologyKey == "kubernetes.io/hostname"
    error_message = "the stored Cluster should carry the topology spread constraint at spec level"
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

    # Placement is exercised here because the mocked unit tests can't: the manifest
    # is sent as-is, so a field the CRD doesn't define (or one it stores in a
    # different shape) only fails against a real API server. Both terms are
    # satisfiable on single-node Kind.
    node_affinity = {
      required  = [{ key = "kubernetes.io/os", operator = "In", values = ["linux"] }]
      preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["amd64", "arm64"] }]
    }
    topology_spread_constraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway" # single node: DoNotSchedule would pin a replica Pending
    }]
  }

  # On a perpetual diff the re-plan marks this exact field "known after apply",
  # so the condition can't evaluate and the run fails; a clean plan keeps it a
  # concrete (empty) map. This is the field that used to drift (#32).
  assert {
    condition     = length(kubernetes_manifest.cluster.object.spec.inheritedMetadata.annotations) == 0
    error_message = "postgres-cnpg is not idempotent: a re-plan still changes spec.inheritedMetadata.annotations (perpetual diff, #32)"
  }
}

# Step 5: turn the Datadog integration on for the Cluster that already exists,
# which is how it gets enabled in practice. The managed role and the inherited
# check annotation are sent as-is, so the CRD only accepts or rejects them here.
run "postgres_cnpg_datadog" {
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
    datadog        = { tags = ["env:e2e"] }

    node_affinity = {
      required  = [{ key = "kubernetes.io/os", operator = "In", values = ["linux"] }]
      preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["amd64", "arm64"] }]
    }
    topology_spread_constraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway"
    }]
  }

  assert {
    condition     = kubernetes_manifest.cluster.object.spec.managed.roles[0].name == "datadog" && contains(kubernetes_manifest.cluster.object.spec.managed.roles[0].inRoles, "pg_monitor")
    error_message = "the stored Cluster should carry the pg_monitor managed role"
  }

  assert {
    condition     = can(jsondecode(kubernetes_manifest.cluster.object.spec.inheritedMetadata.annotations["ad.datadoghq.com/postgres.checks"]))
    error_message = "the stored Cluster should carry the check annotation"
  }
}

# Step 5b: the role actually works. Log in as it, with the password the check
# annotation carries, and use the grant the check depends on.
run "postgres_cnpg_datadog_role" {
  module {
    source = "./modules/postgres-monitor-ping"
  }

  variables {
    namespace       = run.namespace.name
    host            = run.postgres_cnpg_datadog.host
    username        = "datadog"
    database        = "myapp"
    password_secret = "e2e-cnpg-datadog"
  }
}

# Step 6: the same idempotency guard as step 4, with the role and the
# annotation in the spec. A default the operator fills in on the role would
# show up here as a perpetual diff.
run "postgres_cnpg_datadog_idempotent" {
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
    datadog        = { tags = ["env:e2e"] }

    node_affinity = {
      required  = [{ key = "kubernetes.io/os", operator = "In", values = ["linux"] }]
      preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["amd64", "arm64"] }]
    }
    topology_spread_constraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway"
    }]
  }

  assert {
    condition     = kubernetes_manifest.cluster.object.spec.managed.roles[0].passwordSecret.name == "e2e-cnpg-datadog"
    error_message = "postgres-cnpg with datadog is not idempotent: a re-plan still changes the Cluster"
  }
}
