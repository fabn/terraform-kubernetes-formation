# =============================================================================
# Dragonfly addon contract tests
# =============================================================================
# Same env / sensitive_env contract as the Bitnami redis addon (REDIS_URL), so
# callers swap `source` with no change.

mock_provider "kubernetes" {}
mock_provider "random" {}

# Auth on (default): REDIS_URL carries the password and lives in sensitive_env.
run "dragonfly_auth_contract" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
  }

  assert {
    condition     = startswith(nonsensitive(output.sensitive_env.REDIS_URL), "redis://:")
    error_message = "REDIS_URL should embed the password after redis://:"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.REDIS_URL), "@dragonfly:6379")
    error_message = "REDIS_URL should target the <name> Service on 6379"
  }

  assert {
    condition     = length(output.env) == 0
    error_message = "with auth on, nothing is plaintext"
  }

  assert {
    condition     = output.host == "dragonfly"
    error_message = "host should be the Dragonfly Service name"
  }

  assert {
    condition     = contains(kubernetes_manifest.dragonfly.manifest.spec.args, "--proactor_threads=1")
    error_message = "threads should pin --proactor_threads"
  }
}

# Cache mode: --cache_mode is appended to args so the instance evicts at
# maxmemory instead of rejecting writes; persistence stays off (no snapshot).
run "dragonfly_cache_mode" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace  = "addon-test"
    cache_mode = true
  }

  assert {
    condition     = contains(kubernetes_manifest.dragonfly.manifest.spec.args, "--cache_mode")
    error_message = "cache_mode should append --cache_mode to the instance args"
  }

  assert {
    condition     = contains(kubernetes_manifest.dragonfly.manifest.spec.args, "--proactor_threads=1")
    error_message = "cache_mode should keep the --proactor_threads arg"
  }

  assert {
    condition     = !can(kubernetes_manifest.dragonfly.manifest.spec.snapshot)
    error_message = "cache mode leaves persistence off (no snapshot) by default"
  }
}

# Default (data-store) mode: --cache_mode must not leak in.
run "dragonfly_no_cache_mode_by_default" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
  }

  assert {
    condition     = !contains(kubernetes_manifest.dragonfly.manifest.spec.args, "--cache_mode")
    error_message = "cache_mode is off by default, so --cache_mode should be absent"
  }
}

# Configurable output variable name: emit REDIS_CACHE_URL instead of REDIS_URL.
run "dragonfly_custom_url_env_var" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace   = "addon-test"
    name        = "cache"
    auth        = false
    url_env_var = "REDIS_CACHE_URL"
  }

  assert {
    condition     = output.env.REDIS_CACHE_URL == "redis://cache:6379"
    error_message = "the URL should be emitted under the custom url_env_var key"
  }

  assert {
    condition     = !can(output.env.REDIS_URL)
    error_message = "the default REDIS_URL key should not be present when renamed"
  }
}

# Custom url_env_var also renames the sensitive_env key when auth is on.
run "dragonfly_custom_url_env_var_with_auth" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace   = "addon-test"
    url_env_var = "REDIS_CACHE_URL"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.REDIS_CACHE_URL), "@dragonfly:6379")
    error_message = "auth URL should be emitted under the custom url_env_var key in sensitive_env"
  }
}

# url_env_var must be a valid environment variable name.
run "dragonfly_rejects_invalid_url_env_var" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace   = "addon-test"
    url_env_var = "1-bad name"
  }

  expect_failures = [var.url_env_var]
}

# Auth off: REDIS_URL is plaintext in env, sensitive_env empty.
run "dragonfly_no_auth" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    name      = "cache"
    auth      = false
  }

  assert {
    condition     = output.env.REDIS_URL == "redis://cache:6379"
    error_message = "no-auth REDIS_URL should be plaintext host:port"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "no-auth: sensitive_env empty"
  }
}

# S3 snapshot: dir set to the S3 URI, no PVC.
run "dragonfly_snapshot_s3" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace            = "addon-test"
    service_account_name = "dragonfly"
    snapshot             = { s3_uri = "s3://backups/cache" }
    # Pinned only to keep the snapshot_credentials_refresh check quiet; this run
    # is about the snapshot contract. The check has its own runs below.
    image = "docker.dragonflydb.io/dragonflydb/dragonfly:v1.38.1"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.snapshot.dir == "s3://backups/cache"
    error_message = "s3_uri should drive snapshot.dir"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.serviceAccountName == "dragonfly"
    error_message = "the instance SA (for Pod Identity) should be set"
  }

  assert {
    condition     = !can(kubernetes_manifest.dragonfly.manifest.spec.snapshot.persistentVolumeClaimSpec)
    error_message = "S3 snapshot should not create a PVC spec"
  }
}

# snapshot rejects setting both s3 and pvc.
run "dragonfly_snapshot_rejects_both" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    snapshot  = { s3_uri = "s3://b/p", pvc_size = "5Gi" }
  }

  expect_failures = [var.snapshot]
}

# memory must cover the thread count (320Mi per thread: maxmemory is 0.8*limit
# and Dragonfly needs it >= 256Mi per thread).
run "dragonfly_rejects_undersized_memory" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace  = "addon-test"
    threads    = 4
    memory_mib = 512
  }

  expect_failures = [var.memory_mib]
}

# 300Mi clears the old 256/thread floor but not the real 320/thread one (a
# 300Mi limit gives maxmemory 240Mi < 256Mi, so Dragonfly would exit at boot).
run "dragonfly_memory_floor_is_320_per_thread" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace  = "addon-test"
    threads    = 1
    memory_mib = 300
  }

  expect_failures = [var.memory_mib]
}

# The request decouples from the limit: Dragonfly's floor is on the limit
# (cgroup), so a small request reserves less node capacity while the limit still
# satisfies it.
run "dragonfly_memory_request_below_limit" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace           = "addon-test"
    memory_mib          = 320
    memory_requests_mib = 64
  }

  assert {
    condition = (
      kubernetes_manifest.dragonfly.manifest.spec.resources.requests.memory == "64Mi" &&
      kubernetes_manifest.dragonfly.manifest.spec.resources.limits.memory == "320Mi"
    )
    error_message = "memory request should follow memory_requests_mib while the limit follows memory_mib"
  }
}

# A request above the limit is rejected (k8s forbids request > limit).
run "dragonfly_rejects_request_above_limit" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace           = "addon-test"
    memory_mib          = 320
    memory_requests_mib = 512
  }

  expect_failures = [var.memory_requests_mib]
}

# Reserved selector labels must never reach spec.labels: the operator hardcodes
# app.kubernetes.io/part-of into the StatefulSet selector, so propagating it
# there makes resource generation fail. part_of only labels this module's own
# Secret/SA; extra custom labels still flow through to spec.labels.
run "dragonfly_strips_reserved_labels" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    part_of   = "myapp"
    labels    = { team = "platform", "app.kubernetes.io/part-of" = "myapp" }
  }

  assert {
    condition = (
      kubernetes_manifest.dragonfly.manifest.spec.labels.team == "platform" &&
      !contains(keys(kubernetes_manifest.dragonfly.manifest.spec.labels), "app.kubernetes.io/part-of")
    )
    error_message = "spec.labels should carry custom labels but strip operator-reserved selector keys (part-of)"
  }

  assert {
    condition     = kubernetes_secret_v1.auth[0].metadata[0].labels["app.kubernetes.io/part-of"] == "myapp"
    error_message = "part_of should still label the module's own Secret"
  }
}

# node_affinity is absent from the rendered CR unless set.
run "dragonfly_no_node_affinity_by_default" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
  }

  assert {
    condition     = !can(kubernetes_manifest.dragonfly.manifest.spec.affinity)
    error_message = "affinity should be omitted when node_affinity is not set"
  }
}

# Required + preferred node_affinity renders into spec.affinity.nodeAffinity.
run "dragonfly_renders_node_affinity" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    node_affinity = {
      required  = [{ key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }]
      preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["arm64"] }]
    }
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key == "karpenter.sh/capacity-type"
    error_message = "required node affinity should render into a hard node-selector term"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight == 100 && kubernetes_manifest.dragonfly.manifest.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0].key == "kubernetes.io/arch"
    error_message = "preferred node affinity should render as a weighted term"
  }
}

# Invalid node_affinity operator is rejected.
run "dragonfly_rejects_bad_node_affinity_operator" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace     = "addon-test"
    node_affinity = { required = [{ key = "x", operator = "Banana", values = [] }] }
  }

  expect_failures = [var.node_affinity]
}

# spec.pdb is absent unless set: the operator creates its own default budget
# (maxUnavailable = 1) for a multi-replica instance.
run "dragonfly_no_pdb_by_default" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
  }

  assert {
    condition     = !can(kubernetes_manifest.dragonfly.manifest.spec.pdb)
    error_message = "spec.pdb should be omitted when pod_disruption_budget is not set"
  }
}

# Only the key that was set reaches the CR — the CRD rejects both at once.
run "dragonfly_renders_pdb_min_available" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace             = "addon-test"
    replicas              = 3
    pod_disruption_budget = { min_available = "2" }
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.pdb.minAvailable == "2"
    error_message = "min_available should render as spec.pdb.minAvailable"
  }

  # Both keys are sent because kubernetes_manifest requires every attribute of a
  # CRD-derived object (#24); the unused one is null, which the API server treats
  # as absent, so the CRD's mutual-exclusion rule stays satisfied.
  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.pdb.maxUnavailable == null
    error_message = "the unset PDB key must be sent as null, not omitted (the provider requires every object attribute)"
  }
}

run "dragonfly_renders_pdb_max_unavailable" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace             = "addon-test"
    pod_disruption_budget = { max_unavailable = "50%" }
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.pdb.maxUnavailable == "50%"
    error_message = "max_unavailable should render as spec.pdb.maxUnavailable"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.pdb.minAvailable == null
    error_message = "the unset PDB key must be sent as null, not omitted (the provider requires every object attribute)"
  }
}

# Both keys, or neither, is rejected at plan time like the CRD's CEL rule does.
run "dragonfly_rejects_both_pdb_keys" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace             = "addon-test"
    pod_disruption_budget = { min_available = "1", max_unavailable = "1" }
  }

  expect_failures = [var.pod_disruption_budget]
}

run "dragonfly_rejects_empty_pdb" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace             = "addon-test"
    pod_disruption_budget = {}
  }

  expect_failures = [var.pod_disruption_budget]
}

# --- pod spread -------------------------------------------------------------
# One replica is a single-node-friendly default: no constraint at all, so the
# spec stays byte-identical for every existing caller running one instance.
run "dragonfly_no_spread_at_one_replica" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    replicas  = 1
  }

  assert {
    condition     = !can(kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints)
    error_message = "a single replica should carry no topology spread"
  }
}

# Above one replica the derived rule is hard: two instances on one node read as
# HA and provide none.
run "dragonfly_derives_hard_spread_above_one_replica" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    name      = "broker"
    replicas  = 2
  }

  assert {
    condition     = length(kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints) == 2
    error_message = "two replicas should derive a hostname and a zone constraint"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints[0].whenUnsatisfiable == "DoNotSchedule"
    error_message = "the hostname constraint should be hard by default above one replica"
  }

  # Without it, a cluster scaled to one node has one eligible domain, skew is 0
  # by definition, and both replicas may land together.
  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints[0].minDomains == 2
    error_message = "the hard hostname constraint should carry minDomains = replicas"
  }

  # The apiserver rejects minDomains alongside ScheduleAnyway, and the operator
  # patches the StatefulSet as one object — so one stray key fails the lot.
  assert {
    condition     = !can(kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints[1].minDomains)
    error_message = "the zone constraint must not carry minDomains"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints[1].whenUnsatisfiable == "ScheduleAnyway"
    error_message = "zones stay a preference so a saturated AZ never blocks scheduling"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints[0].labelSelector.matchLabels.app == "broker"
    error_message = "the selector should match the instance's own pods"
  }
}

run "dragonfly_soft_spread_when_asked" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace              = "addon-test"
    replicas               = 2
    pod_anti_affinity_type = "preferred"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints[0].whenUnsatisfiable == "ScheduleAnyway"
    error_message = "preferred should soften the hostname constraint"
  }

  assert {
    condition     = !can(kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints[0].minDomains)
    error_message = "a soft constraint must not carry minDomains"
  }
}

# The raw input stays an escape hatch and wins outright.
run "dragonfly_raw_spread_overrides_the_derived_one" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    replicas  = 2
    topology_spread_constraints = [{
      maxSkew           = 3
      topologyKey       = "custom/key"
      whenUnsatisfiable = "ScheduleAnyway"
      labelSelector     = { matchLabels = { app = "dragonfly" } }
    }]
  }

  assert {
    condition     = length(kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints) == 1
    error_message = "an explicit list should replace the derived constraints entirely"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.topologySpreadConstraints[0].topologyKey == "custom/key"
    error_message = "the explicit constraint should be the one rendered"
  }
}

run "dragonfly_rejects_bad_anti_affinity_type" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace              = "addon-test"
    pod_anti_affinity_type = "hard"
  }

  expect_failures = [var.pod_anti_affinity_type]
}

# --- the IRSA credential-refresh trap ---------------------------------------
# A warning, not a validation — but `terraform test` fails a run on a failed
# check, which is what makes it assertable here.
run "dragonfly_warns_when_s3_snapshots_run_an_unpinned_image" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace            = "addon-test"
    service_account_name = "dragonfly"
    snapshot             = { s3_uri = "s3://backups/cache" }
  }

  expect_failures = [check.snapshot_credentials_refresh]
}

run "dragonfly_quiet_when_the_image_is_pinned" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace            = "addon-test"
    service_account_name = "dragonfly"
    snapshot             = { s3_uri = "s3://backups/cache" }
    image                = "docker.dragonflydb.io/dragonflydb/dragonfly:v1.38.1"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.image == "docker.dragonflydb.io/dragonflydb/dragonfly:v1.38.1"
    error_message = "the pinned image should reach the spec"
  }
}

# A PVC snapshot needs no AWS credentials at all, so the check must stay out of
# its way.
run "dragonfly_quiet_for_pvc_snapshots" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    snapshot  = { pvc_size = "5Gi" }
  }

  assert {
    condition     = can(kubernetes_manifest.dragonfly.manifest.spec.snapshot.persistentVolumeClaimSpec)
    error_message = "a pvc_size snapshot should render a PVC spec"
  }
}
