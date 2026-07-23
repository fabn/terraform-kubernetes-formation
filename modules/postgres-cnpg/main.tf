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

        affinity = merge(
          {
            enablePodAntiAffinity = var.enable_pod_anti_affinity
            podAntiAffinityType   = var.pod_anti_affinity_type
            topologyKey           = var.topology_key
          },
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
      var.priority_class_name != null ? { priorityClassName = var.priority_class_name } : {},
      # Both keys must be present (null when empty): kubernetes_manifest types
      # inheritedMetadata as object({labels, annotations}) from the CRD schema,
      # so a partial object like {labels = ...} fails to transform.
      length(local.inherited_labels) > 0 || length(var.annotations) > 0 ? {
        inheritedMetadata = {
          labels      = length(local.inherited_labels) > 0 ? local.inherited_labels : null
          annotations = length(var.annotations) > 0 ? var.annotations : null
        }
      } : {},
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

  timeouts {
    create = var.ready_timeout
  }

  depends_on = [kubernetes_secret_v1.app_cred]
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
