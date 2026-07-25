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
  # for a multi-replica instance. Exactly one key reaches the CR (the CRD rejects
  # both), so the unset one is dropped rather than sent as null.
  pdb = var.pod_disruption_budget == null ? null : (
    var.pod_disruption_budget.min_available != null
    ? { minAvailable = var.pod_disruption_budget.min_available }
    : { maxUnavailable = var.pod_disruption_budget.max_unavailable }
  )

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
      length(var.topology_spread_constraints) > 0 ? { topologySpreadConstraints = var.topology_spread_constraints } : {},
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
