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
  )

  barman_object_name = "${var.name}-backup"
  plugin_name        = "barman-cloud.cloudnative-pg.io"

  resources = {
    requests = { cpu = var.cpu_requests, memory = var.memory_requests }
    limits   = { cpu = coalesce(var.cpu_limits, var.cpu_requests), memory = var.memory_limits }
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
      var.backup != null ? {
        plugins = [{
          name          = local.plugin_name
          isWALArchiver = true
          parameters    = { barmanObjectName = local.barman_object_name }
        }]
      } : {},
    )
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
      configuration = {
        destinationPath = var.backup.destination_path
        endpointURL     = var.backup.endpoint_url
        s3Credentials = {
          accessKeyId = {
            name = var.backup.credentials_secret_name
            key  = var.backup.access_key_id_key
          }
          secretAccessKey = {
            name = var.backup.credentials_secret_name
            key  = var.backup.secret_access_key_key
          }
        }
        wal  = { compression = var.backup.compression }
        data = { compression = var.backup.compression }
      }
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
