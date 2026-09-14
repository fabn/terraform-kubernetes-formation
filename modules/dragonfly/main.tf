# Dragonfly addon. Terraform owns the auth password (generated here and handed
# to the operator through a Secret), so REDIS_URL is a pure expression. The
# operator runs a master + replica(s) and does automatic failover behind a
# stable `<name>` Service, so the app connects with no sentinel awareness.

locals {
  host = var.name
  port = 6379

  auth_secret = "${var.name}-auth"

  labels = merge(
    { "app.kubernetes.io/managed-by" = "terraform" },
    var.part_of != null ? { "app.kubernetes.io/part-of" = var.part_of } : {},
    var.labels,
  )

  # The operator hardcodes these keys into the StatefulSet selector (immutable)
  # and sets them on every object it creates, so they must never reach
  # spec.labels: a user value diverges the pod template from the selector and
  # the operator fails with "failed to generate dragonfly resources".
  # app.kubernetes.io/part-of in particular is forced to "dragonfly", so
  # part_of cannot be honored on the operator's objects — it still labels this
  # module's own Secret/ServiceAccount via local.labels.
  operator_reserved_labels = [
    "app",
    "app.kubernetes.io/name",
    "app.kubernetes.io/instance",
    "app.kubernetes.io/component",
    "app.kubernetes.io/managed-by",
    "app.kubernetes.io/version",
    "app.kubernetes.io/part-of",
  ]

  # Extra labels propagated (spec.labels) onto the operator-managed objects,
  # minus the reserved selector keys above.
  inherited_labels = {
    for k, v in var.labels : k => v if !contains(local.operator_reserved_labels, k)
  }

  password  = var.auth ? random_password.auth[0].result : null
  redis_url = var.auth ? "redis://:${local.password}@${local.host}:${local.port}" : "redis://${local.host}:${local.port}"

  # Dragonfly needs maxmemory (0.8 * limit) >= 256Mi per io-thread; pin the
  # thread count so the memory floor is predictable (see the memory_mib
  # validation). `--cache_mode` turns the instance into a cache: at maxmemory it
  # evicts the least-recently-used keys instead of rejecting writes with OOM.
  args = concat(
    ["--proactor_threads=${var.threads}"],
    var.cache_mode ? ["--cache_mode"] : [],
  )

  # Pod spread, rendered into spec.topologySpreadConstraints (the operator copies
  # it verbatim onto the StatefulSet; it sets no affinity of its own). Two
  # replicas on one node are never what a caller meant — they read as HA and
  # give none — so above one replica this defaults to a hard one-per-node rule.
  #
  # The failure it guards against is not losing an instance. Losing one is a
  # non-event: the replacement replicates from the survivor and never reads a
  # snapshot. It is losing *both at once*, which forces a cold start from
  # whatever the last snapshot holds — and with every replica on one node, one
  # node going away does exactly that.
  #
  # minDomains goes on the hostname entry alone, and only when hard. Skew is
  # computed over *eligible* domains, so a cluster scaled to one node has one
  # domain, skew is 0 by definition, and every replica may land on it — the very
  # case this guards. It is also invalid alongside ScheduleAnyway: the apiserver
  # rejects the pair outright, and since the operator patches the StatefulSet as
  # one object, that rejection takes every unrelated field in the same patch
  # (an image pin, a resource bump) down with it.
  spread_mode = var.pod_anti_affinity_type != null ? var.pod_anti_affinity_type : (var.replicas > 1 ? "required" : null)

  # Built whole and then sliced, never returned from a conditional: the two
  # entries are different object types, so a ternary choosing between `[]` and
  # the pair fails with "Inconsistent conditional result types". slice() keeps
  # them a tuple, which is what lets them carry different attributes.
  spread_entries = [
    merge(
      {
        maxSkew           = 1
        topologyKey       = "kubernetes.io/hostname"
        whenUnsatisfiable = local.spread_mode == "required" ? "DoNotSchedule" : "ScheduleAnyway"
        labelSelector     = { matchLabels = { app = var.name } }
      },
      local.spread_mode == "required" ? { minDomains = var.replicas } : {},
    ),
    {
      # Zones stay a preference at every strength: a saturated AZ must never
      # block scheduling, and on a single-zone cluster a hard rule is unmeetable.
      maxSkew           = 1
      topologyKey       = "topology.kubernetes.io/zone"
      whenUnsatisfiable = "ScheduleAnyway"
      labelSelector     = { matchLabels = { app = var.name } }
    },
  ]

  derived_spread = slice(local.spread_entries, 0, local.spread_mode == null ? 0 : 2)

  # Which of the two wins is decided in the spec merge below, as two mutually
  # exclusive arguments, rather than here as one conditional: the raw input and
  # the derived pair are tuples of different lengths, and a ternary between them
  # is rejected outright ("The 'true' tuple has length 0, but the 'false' tuple
  # has length 2"). Object-typed merge arguments have no such problem.
  use_raw_spread = length(var.topology_spread_constraints) > 0

  # Set-based node affinity rendered into spec.affinity, which the operator copies
  # verbatim onto the StatefulSet pod template (it sets no affinity of its own, so
  # nothing is clobbered). `required` expressions are ANDed into one hard
  # node-selector term; `preferred` become soft/weighted terms. Emitted only when
  # at least one term is given, so the spec stays unchanged by default.
  na_required  = try(var.node_affinity.required, [])
  na_preferred = try(var.node_affinity.preferred, [])
  affinity = length(local.na_required) + length(local.na_preferred) == 0 ? {} : {
    affinity = {
      nodeAffinity = merge(
        length(local.na_required) > 0 ? {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [for e in local.na_required : {
                key      = e.key
                operator = e.operator
                values   = e.values
              }]
            }]
          }
        } : {},
        length(local.na_preferred) > 0 ? {
          preferredDuringSchedulingIgnoredDuringExecution = [for p in local.na_preferred : {
            weight = p.weight
            preference = {
              matchExpressions = [{
                key      = p.key
                operator = p.operator
                values   = p.values
              }]
            }
          }]
        } : {},
      )
    }
  }

  # spec.pdb, customising the PodDisruptionBudget the operator creates on its own
  # for a multi-replica instance. Both keys must be present even though the CRD
  # accepts only one of them: kubernetes_manifest types the object from the CRD
  # schema and requires every attribute ("required attribute maxUnavailable not
  # set" otherwise), the same constraint that forces both inheritedMetadata keys
  # in postgres-cnpg (#24). The unused one is therefore sent as null — validation
  # guarantees exactly one is non-null — and the API server treats a null the way
  # it treats an absent key, so the CRD's mutual-exclusion rule stays satisfied.
  pdb = var.pod_disruption_budget == null ? null : {
    minAvailable   = var.pod_disruption_budget.min_available
    maxUnavailable = var.pod_disruption_budget.max_unavailable
  }

  snapshot = var.snapshot == null ? null : merge(
    { cron = var.snapshot.cron },
    var.snapshot.s3_uri != null ? { dir = var.snapshot.s3_uri } : {},
    var.snapshot.pvc_size != null ? {
      persistentVolumeClaimSpec = {
        accessModes = ["ReadWriteOnce"]
        resources   = { requests = { storage = var.snapshot.pvc_size } }
      }
    } : {},
  )
}

resource "random_password" "auth" {
  count   = var.auth ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "auth" {
  count = var.auth ? 1 : 0
  metadata {
    name      = local.auth_secret
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    password = random_password.auth[0].result
  }
}

# ServiceAccount for the instance pods, so an external identity (EKS Pod
# Identity / IRSA) can grant them S3 access for snapshots.
resource "kubernetes_service_account_v1" "instance" {
  count = var.service_account_name != null ? 1 : 0
  metadata {
    name        = var.service_account_name
    namespace   = var.namespace
    labels      = local.labels
    annotations = var.service_account_annotations
  }
}

resource "kubernetes_manifest" "dragonfly" {
  manifest = {
    apiVersion = "dragonflydb.io/v1alpha1"
    kind       = "Dragonfly"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = local.labels
    }
    spec = merge(
      {
        replicas = var.replicas
        args     = local.args
        # The memory floor is on the LIMIT (Dragonfly reads the cgroup limit for
        # maxmemory), so the request can be set much lower to reserve less node
        # capacity while the limit still satisfies Dragonfly.
        resources = {
          requests = { cpu = var.cpu_requests, memory = "${coalesce(var.memory_requests_mib, var.memory_mib)}Mi" }
          limits   = { memory = "${var.memory_mib}Mi" }
        }
      },
      var.image != null ? { image = var.image } : {},
      var.auth ? {
        authentication = { passwordFromSecret = { name = local.auth_secret, key = "password" } }
      } : {},
      var.service_account_name != null ? { serviceAccountName = var.service_account_name } : {},
      length(local.inherited_labels) > 0 ? { labels = local.inherited_labels } : {},
      length(var.annotations) > 0 ? { annotations = var.annotations } : {},
      local.affinity,
      length(var.node_selector) > 0 ? { nodeSelector = var.node_selector } : {},
      length(var.tolerations) > 0 ? { tolerations = var.tolerations } : {},
      local.use_raw_spread ? { topologySpreadConstraints = var.topology_spread_constraints } : {},
      !local.use_raw_spread && length(local.derived_spread) > 0 ? { topologySpreadConstraints = local.derived_spread } : {},
      var.pod_disruption_budget != null ? { pdb = local.pdb } : {},
      local.snapshot != null ? { snapshot = local.snapshot } : {},
    )
  }

  # Optionally block until the operator reports the instance Ready.
  dynamic "wait" {
    for_each = var.wait_for_ready ? [1] : []
    content {
      fields = {
        "status.phase" = "Ready"
      }
    }
  }

  timeouts {
    create = var.ready_timeout
  }

  depends_on = [kubernetes_secret_v1.auth, kubernetes_service_account_v1.instance]
}

# Dragonfly reaches S3 through IRSA — its S3 client implements the OIDC
# web-identity flow only, so a snapshot destination means web-identity
# credentials. From v1.39.0 those credentials are acquired once at start-up and
# never refreshed, so every save fails `ExpiredToken` a few hours in. Reads are
# unaffected, nothing restarts, and the operator reports the instance healthy:
# the only symptom is a recovery point that stops advancing, which is invisible
# right up until it is the only copy left.
#
# A warning and not a validation: an unpinned image is legitimate for a caller
# with no snapshot destination, and for one who has read this and decided. It
# cannot be a version comparison either — with `image` unset the version is
# whatever the operator picks, which this module cannot see.
#
# Upstream: dragonflydb/dragonfly#7666, fixed in-tree but not yet in a release.
# Delete this check once one carries the fix.
check "snapshot_credentials_refresh" {
  assert {
    condition     = try(var.snapshot.s3_uri, null) == null || var.image != null
    error_message = "S3 snapshots are enabled but `image` is unpinned: Dragonfly v1.39.0 and up never refresh their IRSA credentials, so snapshots silently stop with ExpiredToken a few hours after each start. Pin `image` to a v1.38.x tag until a release carries the fix for dragonflydb/dragonfly#7666."
  }
}
