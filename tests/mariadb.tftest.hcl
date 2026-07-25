# =============================================================================
# mariadb addon contract tests
# =============================================================================
# Same env / sensitive_env contract as the postgres addons (DATABASE_URL), so a
# MySQL-family stack swaps `source` with no downstream change. Host is
# `<name>-primary` in HA, `<name>` when standalone.

mock_provider "kubernetes" {}
mock_provider "random" {}

# HA default (replicas = 2): host is <name>-primary, replication is enabled.
run "mariadb_ha_contract" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
    part_of   = "myapp"
  }

  assert {
    condition     = output.host == "mariadb-primary"
    error_message = "HA host should be the <name>-primary Service"
  }

  assert {
    condition     = startswith(nonsensitive(output.sensitive_env.DATABASE_URL), "mysql2://myapp:")
    error_message = "DATABASE_URL should be a mysql2 URL for the app user"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.DATABASE_URL), "@mariadb-primary:3306/myapp")
    error_message = "DATABASE_URL should target the -primary host / database on 3306"
  }

  assert {
    condition     = output.env.MYSQL_HOST == "mariadb-primary" && output.env.MYSQL_PORT == "3306" && output.env.MYSQL_USER == "myapp" && output.env.MYSQL_DATABASE == "myapp"
    error_message = "plaintext connection vars should be fully populated"
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.replication.enabled == true && kubernetes_manifest.mariadb.manifest.spec.replication.primary.autoFailover == true
    error_message = "HA should enable replication with automatic failover"
  }

  # inheritMetadata (correct field name) must carry both labels and annotations.
  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.inheritMetadata.labels["app.kubernetes.io/part-of"] == "myapp" && can(kubernetes_manifest.mariadb.manifest.spec.inheritMetadata.annotations)
    error_message = "inheritMetadata should carry both labels and annotations"
  }
}

# Standalone (replicas = 1): host is the plain <name> Service, no replication.
run "mariadb_standalone" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace = "addon-test"
    name      = "db"
    database  = "app"
    username  = "app"
    replicas  = 1
  }

  assert {
    condition     = output.host == "db"
    error_message = "standalone host should be the plain <name> Service"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.DATABASE_URL), "@db:3306/app")
    error_message = "DATABASE_URL should target the standalone host"
  }

  assert {
    condition     = !can(kubernetes_manifest.mariadb.manifest.spec.replication)
    error_message = "standalone should not set a replication block"
  }
}

# Keyless S3 backup: PhysicalBackup present, no static-key refs, SA on the Job.
run "mariadb_backup_keyless" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace            = "addon-test"
    database             = "app"
    username             = "app"
    service_account_name = "app-mariadb"
    backup               = { bucket = "backups", prefix = "app", region = "eu-south-1" }
  }

  assert {
    condition     = kubernetes_manifest.physical_backup[0].manifest.spec.storage.s3.bucket == "backups"
    error_message = "backup should target the S3 bucket"
  }

  # The operator requires an explicit endpoint; it is derived from the region.
  assert {
    condition     = kubernetes_manifest.physical_backup[0].manifest.spec.storage.s3.endpoint == "s3.eu-south-1.amazonaws.com"
    error_message = "backup should derive the AWS S3 endpoint from the region"
  }

  assert {
    condition     = !can(kubernetes_manifest.physical_backup[0].manifest.spec.storage.s3.accessKeyIdSecretKeyRef)
    error_message = "keyless backup should omit static-key refs"
  }

  # The service account is set at the top level of the PhysicalBackup spec.
  assert {
    condition     = kubernetes_manifest.physical_backup[0].manifest.spec.serviceAccountName == "app-mariadb"
    error_message = "keyless backup Job should run under the service account"
  }
}

# Adoption: bootstrap the instance from a logical dump in S3.
run "mariadb_bootstrap_from" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace            = "addon-test"
    database             = "app"
    username             = "app"
    service_account_name = "app-mariadb"
    bootstrap_from       = { bucket = "dumps", prefix = "app", region = "eu-south-1", target_recovery_time = "2026-07-22T10:00:00Z" }
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.bootstrapFrom.s3.bucket == "dumps"
    error_message = "bootstrapFrom should point at the dump bucket"
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.bootstrapFrom.targetRecoveryTime == "2026-07-22T10:00:00Z"
    error_message = "bootstrapFrom should carry the target recovery time"
  }
}

# node_affinity and topology_spread_constraints are absent unless set, and the
# operator's antiAffinityEnabled shorthand stays the only affinity key by default.
run "mariadb_no_placement_by_default" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
  }

  assert {
    condition     = !can(kubernetes_manifest.mariadb.manifest.spec.affinity)
    error_message = "affinity should be omitted when neither anti_affinity nor node_affinity is set"
  }

  assert {
    condition     = !can(kubernetes_manifest.mariadb.manifest.spec.topologySpreadConstraints)
    error_message = "topologySpreadConstraints should be omitted when not set"
  }
}

# node_affinity renders into spec.affinity.nodeAffinity next to (not instead of)
# the operator's antiAffinityEnabled shorthand.
run "mariadb_renders_node_affinity" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace     = "addon-test"
    database      = "myapp"
    username      = "myapp"
    anti_affinity = true
    node_affinity = {
      required  = [{ key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }]
      preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["arm64"] }]
    }
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key == "karpenter.sh/capacity-type"
    error_message = "required node affinity should render into a hard node-selector term"
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight == 100 && kubernetes_manifest.mariadb.manifest.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key == "kubernetes.io/arch"
    error_message = "preferred node affinity should render as a weighted term"
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.affinity.antiAffinityEnabled == true
    error_message = "node_affinity must not displace the operator's antiAffinityEnabled shorthand"
  }
}

# Invalid node_affinity operator is rejected.
run "mariadb_rejects_bad_node_affinity_operator" {
  command = plan

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace     = "addon-test"
    database      = "myapp"
    username      = "myapp"
    node_affinity = { required = [{ key = "x", operator = "Banana", values = [] }] }
  }

  expect_failures = [var.node_affinity]
}

# topology_spread_constraints is passed through verbatim.
run "mariadb_renders_topology_spread_constraints" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
    topology_spread_constraints = [{
      maxSkew           = 1
      topologyKey       = "topology.kubernetes.io/zone"
      whenUnsatisfiable = "ScheduleAnyway"
    }]
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.topologySpreadConstraints[0].topologyKey == "topology.kubernetes.io/zone"
    error_message = "topology spread constraints should reach spec.topologySpreadConstraints verbatim"
  }
}

# An HA instance gets a PodDisruptionBudget by default (the operator manages
# none), maxUnavailable = 1 — the same budget the Dragonfly operator picks.
run "mariadb_default_pdb_when_ha" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
    replicas  = 2
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.podDisruptionBudget.maxUnavailable == "1"
    error_message = "an HA instance should default to a maxUnavailable = 1 budget"
  }

  # Both keys are sent because kubernetes_manifest requires every attribute of a
  # CRD-derived object (#24, #38); the unused one is null, which the API server
  # treats as absent.
  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.podDisruptionBudget.minAvailable == null
    error_message = "the unused PDB key must be sent as null, not omitted"
  }
}

# A standalone server gets none: a single-pod minAvailable = 1 would block every
# node drain forever.
run "mariadb_no_pdb_when_standalone" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace = "addon-test"
    database  = "myapp"
    username  = "myapp"
    replicas  = 1
  }

  assert {
    condition     = !can(kubernetes_manifest.mariadb.manifest.spec.podDisruptionBudget)
    error_message = "a standalone instance should get no PodDisruptionBudget"
  }
}

# enable_pdb = false opts out of the default budget (dev clusters).
run "mariadb_pdb_opt_out" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace  = "addon-test"
    database   = "myapp"
    username   = "myapp"
    replicas   = 2
    enable_pdb = false
  }

  assert {
    condition     = !can(kubernetes_manifest.mariadb.manifest.spec.podDisruptionBudget)
    error_message = "enable_pdb = false should omit the budget"
  }
}

# An explicit budget wins, and is honoured on a standalone instance too.
run "mariadb_explicit_pdb" {
  command = apply

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace             = "addon-test"
    database              = "myapp"
    username              = "myapp"
    replicas              = 1
    pod_disruption_budget = { min_available = "50%" }
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.podDisruptionBudget.minAvailable == "50%"
    error_message = "an explicit budget should be honoured regardless of replica count"
  }

  assert {
    condition     = kubernetes_manifest.mariadb.manifest.spec.podDisruptionBudget.maxUnavailable == null
    error_message = "the unused PDB key must be sent as null, not omitted"
  }
}

# Both keys, or neither, is rejected at plan time.
run "mariadb_rejects_both_pdb_keys" {
  command = plan

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace             = "addon-test"
    database              = "myapp"
    username              = "myapp"
    pod_disruption_budget = { min_available = "1", max_unavailable = "1" }
  }

  expect_failures = [var.pod_disruption_budget]
}

run "mariadb_rejects_empty_pdb" {
  command = plan

  module {
    source = "./modules/mariadb"
  }

  variables {
    namespace             = "addon-test"
    database              = "myapp"
    username              = "myapp"
    pod_disruption_budget = {}
  }

  expect_failures = [var.pod_disruption_budget]
}
