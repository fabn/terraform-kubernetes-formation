# CloudNativePG addon. Terraform owns the application password (generated here
# and handed to the operator through a basic-auth Secret), so the addon keeps
# the same contract as the Bitnami-chart postgres addon: DATABASE_URL is a pure
# expression, no read-back of an operator-generated Secret. The operator
# reconciles HA, failover and (optionally) continuous backup behind that.

locals {
  # CloudNativePG exposes the primary through the `<name>-rw` Service.
  host = "${var.name}-rw"

  cred_secret = "${var.name}-app"

  labels = merge(
    { "app.kubernetes.io/managed-by" = "terraform" },
    var.part_of != null ? { "app.kubernetes.io/part-of" = var.part_of } : {},
    var.labels,
  )

  # Labels CloudNativePG propagates (spec.inheritedMetadata) onto the objects
  # it creates — Pods, Services, PVCs, the PDB, etc. managed-by is left off on
  # purpose: those objects are managed by the operator, not Terraform directly.
  inherited_labels = merge(
    var.part_of != null ? { "app.kubernetes.io/part-of" = var.part_of } : {},
    var.labels,
  )

  datadog_secret = "${var.name}-datadog"

  datadog_secret_ref = try(var.datadog.password_from_secret, null)
  # The handle the agent's k8s.secrets backend resolves: `<namespace>/<secret>;<key>`,
  # prefixed with `<backend>;` when the agent runs several backends.
  datadog_password_handle = local.datadog_secret_ref == null ? null : (
    local.datadog_secret_ref.backend == null
    ? "ENC[${var.namespace}/${local.datadog_secret};password]"
    : "ENC[${local.datadog_secret_ref.backend};${var.namespace}/${local.datadog_secret};password]"
  )

  # Autodiscovery reads the check from the pod annotation keyed by container
  # name, and every instance pod's container is called `postgres`.
  datadog_annotations = var.datadog == null ? {} : {
    "ad.datadoghq.com/postgres.checks" = jsonencode({
      postgres = {
        init_config = {}
        instances = [merge(
          {
            host     = "%%host%%"
            port     = 5432
            username = var.datadog.username
            # Indexing an object rather than a conditional, which would mark the
            # handle sensitive too and hide the whole annotation from the plan.
            password = {
              handle    = local.datadog_password_handle
              plaintext = random_password.datadog[0].result
            }[local.datadog_password_handle != null ? "handle" : "plaintext"]
            dbname = var.database
            dbm    = var.datadog.dbm
            tags   = var.datadog.tags
          },
          var.datadog.relations ? { relations = [{ relation_regex = ".*" }] } : {},
          var.datadog.instance,
        )]
      }
    })
  }

  annotations = merge(var.annotations, local.datadog_annotations)

  # What Database Monitoring needs from the server. Setting any
  # pg_stat_statements.* parameter is what makes the operator preload the
  # library and create the extension.
  dbm_parameters = {
    "pg_stat_statements.max"           = "10000"
    "pg_stat_statements.track"         = "all"
    "pg_stat_statements.track_utility" = "off"
    "track_activity_query_size"        = "4096"
    "track_io_timing"                  = "on"
  }

  barman_object_name = "${var.name}-backup"
  plugin_name        = "barman-cloud.cloudnative-pg.io"

  resources = {
    requests = { cpu = var.cpu_requests, memory = var.memory_requests }
    # No CPU limit by default: a CPU limit throttles the container via CFS quota
    # even when the node has spare CPU, which hurts a latency-sensitive workload
    # like a database. cpu_limits is opt-in; the memory limit always stays (OOM
    # guard).
    limits = merge(
      { memory = var.memory_limits },
      var.cpu_limits != null ? { cpu = var.cpu_limits } : {},
    )
  }

  # Set-based node affinity rendered into the Cluster's spec.affinity.nodeAffinity
  # (a corev1.NodeAffinity). `required` expressions are ANDed into one hard
  # node-selector term; `preferred` become soft/weighted terms. Emitted only when
  # at least one term is given, so the affinity block stays clean otherwise.
  na_required  = try(var.node_affinity.required, [])
  na_preferred = try(var.node_affinity.preferred, [])
  node_affinity = length(local.na_required) + length(local.na_preferred) == 0 ? {} : {
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

resource "random_password" "app" {
  length  = 32
  special = false
}

# basic-auth Secret consumed by the Cluster's initdb (owner credentials).
resource "kubernetes_secret_v1" "app_cred" {
  metadata {
    name      = local.cred_secret
    namespace = var.namespace
    labels    = local.labels
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = var.username
    password = random_password.app.result
  }
}

resource "random_password" "datadog" {
  count = var.datadog != null ? 1 : 0

  length  = 32
  special = false
}

# basic-auth Secret for the managed monitoring role. The operator requires the
# username to match the role name; cnpg.io/reload makes it pick up a rotation.
resource "kubernetes_secret_v1" "datadog_cred" {
  count = var.datadog != null ? 1 : 0

  metadata {
    name      = local.datadog_secret
    namespace = var.namespace
    labels    = merge(local.labels, { "cnpg.io/reload" = "true" })
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = var.datadog.username
    password = random_password.datadog[0].result
  }
}

resource "kubernetes_role_v1" "datadog_secret_reader" {
  count = local.datadog_secret_ref != null ? 1 : 0

  metadata {
    name      = "${local.datadog_secret}-reader"
    namespace = var.namespace
    labels    = local.labels
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [local.datadog_secret]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "datadog_secret_reader" {
  count = local.datadog_secret_ref != null ? 1 : 0

  metadata {
    name      = "${local.datadog_secret}-reader"
    namespace = var.namespace
    labels    = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.datadog_secret_reader[0].metadata[0].name
  }

  dynamic "subject" {
    for_each = local.datadog_secret_ref.readers
    content {
      kind      = "ServiceAccount"
      name      = subject.value.name
      namespace = subject.value.namespace
    }
  }
}

resource "kubernetes_manifest" "cluster" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = local.labels
    }
    spec = merge(
      {
        instances = var.instances

        storage = merge(
          { size = var.storage_size },
          var.storage_class != null ? { storageClass = var.storage_class } : {},
        )

        resources = local.resources

        # No superuser Secret: the app connects as the initdb owner only.
        enableSuperuserAccess = false

        # Operator-managed PodDisruptionBudgets (separate primary/replica).
        enablePDB = var.enable_pdb

        # Graceful-shutdown budget. stopDelay is also copied onto the pod's
        # terminationGracePeriodSeconds by the operator; smartShutdownTimeout is
        # the slice of it spent waiting for connections before a fast shutdown.
        stopDelay            = var.stop_delay
        smartShutdownTimeout = var.smart_shutdown_timeout

        affinity = merge(
          {
            enablePodAntiAffinity = var.enable_pod_anti_affinity
            podAntiAffinityType   = var.pod_anti_affinity_type
            topologyKey           = var.topology_key
          },
          local.node_affinity,
          length(var.node_selector) > 0 ? { nodeSelector = var.node_selector } : {},
          length(var.tolerations) > 0 ? { tolerations = var.tolerations } : {},
        )

        bootstrap = {
          initdb = {
            database = var.database
            owner    = var.username
            secret   = { name = local.cred_secret }
          }
        }
      },
      var.image_name != null ? { imageName = var.image_name } : {},
      # Cluster-level (not part of the affinity block, unlike the anti-affinity knobs).
      length(var.topology_spread_constraints) > 0 ? { topologySpreadConstraints = var.topology_spread_constraints } : {},
      var.priority_class_name != null ? { priorityClassName = var.priority_class_name } : {},
      var.switchover_delay != null ? { switchoverDelay = var.switchover_delay } : {},
      var.start_delay != null ? { startDelay = var.start_delay } : {},
      var.failover_delay != null ? { failoverDelay = var.failover_delay } : {},
      # Both keys must be present — kubernetes_manifest types inheritedMetadata
      # as object({labels, annotations}) from the CRD schema, so a partial object
      # fails to transform. Use an empty map (not null) for the unused one:
      # sending null is what the operator normalises away server-side, leaving a
      # perpetual `annotations = (known after apply)` diff that re-applies the
      # Cluster every plan (#32).
      length(local.inherited_labels) > 0 || length(local.annotations) > 0 ? {
        inheritedMetadata = {
          labels      = local.inherited_labels
          annotations = local.annotations
        }
      } : {},
      var.datadog != null ? {
        managed = {
          roles = [{
            name           = var.datadog.username
            ensure         = "present"
            login          = true
            inRoles        = ["pg_monitor"]
            passwordSecret = { name = local.datadog_secret }
          }]
        }
      } : {},
      try(var.datadog.dbm, false) ? { postgresql = { parameters = local.dbm_parameters } } : {},
      var.backup != null ? {
        plugins = [{
          name          = local.plugin_name
          isWALArchiver = true
          parameters    = { barmanObjectName = local.barman_object_name }
        }]
      } : {},
    )
  }

  # Optionally block until the operator reports the Cluster healthy, so the
  # apply does not return before the database is usable.
  dynamic "wait" {
    for_each = var.wait_for_ready ? [1] : []
    content {
      fields = {
        "status.phase" = "Cluster in healthy state"
      }
    }
  }

  # `update` as well as `create`: the wait above applies to both, so stating only
  # one leaves an update waiting on the provider's own default — a number nobody
  # here chose, and a different one.
  timeouts {
    create = var.ready_timeout
    update = var.ready_timeout
  }

  depends_on = [kubernetes_secret_v1.app_cred, kubernetes_secret_v1.datadog_cred]
}

# --- backup ------------------------------------------------------------------

resource "kubernetes_manifest" "object_store" {
  count = var.backup != null ? 1 : 0

  manifest = {
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata = {
      name      = local.barman_object_name
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      retentionPolicy = var.backup.retention_policy
      configuration = merge(
        {
          destinationPath = var.backup.destination_path
          # Static keys when a Secret is given; otherwise inherit the pod's
          # ambient IAM identity (EKS Pod Identity / IRSA) — no keys to ship.
          # merge() of two conditional maps: a single ternary can't return the
          # two differently-shaped credential objects.
          s3Credentials = merge(
            var.backup.credentials_secret_name != null ? {
              accessKeyId     = { name = var.backup.credentials_secret_name, key = var.backup.access_key_id_key }
              secretAccessKey = { name = var.backup.credentials_secret_name, key = var.backup.secret_access_key_key }
            } : {},
            var.backup.credentials_secret_name == null ? { inheritFromIAMRole = true } : {},
          )
          wal  = { compression = var.backup.compression }
          data = { compression = var.backup.compression }
        },
        # Only non-AWS S3-compatible stores need an explicit endpoint.
        var.backup.endpoint_url != null ? { endpointURL = var.backup.endpoint_url } : {},
      )
    }
  }
}

resource "kubernetes_manifest" "scheduled_backup" {
  count = var.backup != null ? 1 : 0

  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata = {
      name      = "${var.name}-scheduled"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = {
      schedule             = var.backup.schedule
      backupOwnerReference = "self"
      cluster              = { name = var.name }
      method               = "plugin"
      pluginConfiguration  = { name = local.plugin_name }
    }
  }

  depends_on = [kubernetes_manifest.cluster, kubernetes_manifest.object_store]
}
