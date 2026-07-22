# mariadb-operator addon. Terraform owns the application and root passwords
# (generated here and handed to the operator through Secrets), so the addon
# keeps the same contract as the Bitnami/CNPG postgres addons: DATABASE_URL is a
# pure expression, no read-back of an operator-generated Secret. The operator
# reconciles replication, automatic failover and (optionally) physical backups
# behind a stable Service — `<name>-primary` in HA, `<name>` when standalone.

locals {
  is_ha = var.replicas > 1

  # Replication exposes the primary through `<name>-primary`; a standalone
  # server is reached on the plain `<name>` Service.
  host = local.is_ha ? "${var.name}-primary" : var.name
  port = 3306

  app_secret  = "${var.name}-app"
  root_secret = "${var.name}-root"

  labels = merge(
    { "app.kubernetes.io/managed-by" = "terraform" },
    var.part_of != null ? { "app.kubernetes.io/part-of" = var.part_of } : {},
    var.labels,
  )

  # Propagated by the operator (spec.inheritedMetadata) onto the objects it
  # creates. managed-by is left off: those objects are the operator's, not
  # Terraform's directly.
  inherited_labels = merge(
    var.part_of != null ? { "app.kubernetes.io/part-of" = var.part_of } : {},
    var.labels,
  )

  resources = {
    requests = { cpu = var.cpu_requests, memory = var.memory_requests }
    limits = merge(
      { memory = var.memory_limits },
      var.cpu_limits != null ? { cpu = var.cpu_limits } : {},
    )
  }

  # S3 storage block shared by the backup and bootstrap-from sources. Keyless
  # when no credentials Secret is given: the key refs are simply omitted and the
  # pod writes with its ambient IAM identity (EKS Pod Identity / IRSA).
  backup_s3 = var.backup == null ? null : merge(
    {
      bucket = var.backup.bucket
      region = var.backup.region
      # The operator requires an explicit endpoint; derive the AWS one from the
      # region unless an override is given for a non-AWS S3-compatible store.
      endpoint = coalesce(var.backup.endpoint_url, "s3.${var.backup.region}.amazonaws.com")
    },
    var.backup.prefix != null ? { prefix = var.backup.prefix } : {},
    var.backup.credentials_secret_name != null ? {
      accessKeyIdSecretKeyRef     = { name = var.backup.credentials_secret_name, key = var.backup.access_key_id_key }
      secretAccessKeySecretKeyRef = { name = var.backup.credentials_secret_name, key = var.backup.secret_access_key_key }
    } : {},
  )

  bootstrap_s3 = var.bootstrap_from == null ? null : merge(
    {
      bucket   = var.bootstrap_from.bucket
      region   = var.bootstrap_from.region
      endpoint = coalesce(var.bootstrap_from.endpoint_url, "s3.${var.bootstrap_from.region}.amazonaws.com")
    },
    var.bootstrap_from.prefix != null ? { prefix = var.bootstrap_from.prefix } : {},
    var.bootstrap_from.credentials_secret_name != null ? {
      accessKeyIdSecretKeyRef     = { name = var.bootstrap_from.credentials_secret_name, key = var.bootstrap_from.access_key_id_key }
      secretAccessKeySecretKeyRef = { name = var.bootstrap_from.credentials_secret_name, key = var.bootstrap_from.secret_access_key_key }
    } : {},
  )
}

resource "random_password" "app" {
  length  = 32
  special = false
}

resource "random_password" "root" {
  length  = 32
  special = false
}

# App user password: the operator creates the user + database + grant from it.
resource "kubernetes_secret_v1" "app_cred" {
  metadata {
    name      = local.app_secret
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    password = random_password.app.result
  }
}

# Root password: required by the operator to manage the server. The app never
# uses it (it connects as the application user only).
resource "kubernetes_secret_v1" "root_cred" {
  metadata {
    name      = local.root_secret
    namespace = var.namespace
    labels    = local.labels
  }
  data = {
    password = random_password.root.result
  }
}

# ServiceAccount for the instance and backup pods, so an external identity (EKS
# Pod Identity / IRSA) can grant them keyless S3 access.
resource "kubernetes_service_account_v1" "instance" {
  count = var.service_account_name != null ? 1 : 0
  metadata {
    name        = var.service_account_name
    namespace   = var.namespace
    labels      = local.labels
    annotations = var.service_account_annotations
  }
}

resource "kubernetes_manifest" "mariadb" {
  manifest = {
    apiVersion = "k8s.mariadb.com/v1alpha1"
    kind       = "MariaDB"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = local.labels
    }
    spec = merge(
      {
        rootPasswordSecretKeyRef = { name = local.root_secret, key = "password" }

        # Initial application user + database + grant (created by the operator).
        username             = var.username
        passwordSecretKeyRef = { name = local.app_secret, key = "password" }
        database             = var.database

        replicas = var.replicas

        storage = merge(
          { size = var.storage_size },
          var.storage_class != null ? { storageClass = var.storage_class } : {},
        )

        resources = local.resources
      },
      # Primary + replicas with async replication and optional auto-failover.
      local.is_ha ? {
        replication = {
          enabled = true
          primary = { autoFailover = var.auto_failover }
        }
      } : {},
      var.image != null ? { image = var.image } : {},
      var.service_account_name != null ? { serviceAccountName = var.service_account_name } : {},
      var.anti_affinity ? { affinity = { antiAffinityEnabled = true } } : {},
      var.pod_disruption_budget != null ? { podDisruptionBudget = var.pod_disruption_budget } : {},
      length(var.node_selector) > 0 ? { nodeSelector = var.node_selector } : {},
      length(var.tolerations) > 0 ? { tolerations = var.tolerations } : {},
      var.priority_class_name != null ? { priorityClassName = var.priority_class_name } : {},
      # inheritMetadata is typed object({labels, annotations}) by the CRD, so send
      # both keys (empty maps when unused) or kubernetes_manifest's transform
      # rejects the partial object. (Note: the field is inheritMetadata, not the
      # CNPG-style inheritedMetadata.)
      length(local.inherited_labels) > 0 || length(var.annotations) > 0 ? {
        inheritMetadata = {
          labels      = local.inherited_labels
          annotations = var.annotations
        }
      } : {},
      # Adopt an existing database from a logical dump in S3 (first create only).
      var.bootstrap_from != null ? {
        bootstrapFrom = merge(
          { s3 = local.bootstrap_s3 },
          var.bootstrap_from.target_recovery_time != null ? { targetRecoveryTime = var.bootstrap_from.target_recovery_time } : {},
        )
      } : {},
    )
  }

  # Optionally block until the operator reports the MariaDB Ready, so the apply
  # does not return before the database is usable.
  dynamic "wait" {
    for_each = var.wait_for_ready ? [1] : []
    content {
      condition {
        type   = "Ready"
        status = "True"
      }
    }
  }

  timeouts {
    create = var.ready_timeout
  }

  depends_on = [
    kubernetes_secret_v1.app_cred,
    kubernetes_secret_v1.root_cred,
    kubernetes_service_account_v1.instance,
  ]
}

# --- backup ------------------------------------------------------------------

resource "kubernetes_manifest" "physical_backup" {
  count = var.backup != null ? 1 : 0

  manifest = {
    apiVersion = "k8s.mariadb.com/v1alpha1"
    kind       = "PhysicalBackup"
    metadata = {
      name      = "${var.name}-backup"
      namespace = var.namespace
      labels    = local.labels
    }
    spec = merge(
      {
        mariaDbRef   = { name = var.name }
        schedule     = { cron = var.backup.schedule }
        maxRetention = var.backup.max_retention
        storage      = { s3 = local.backup_s3 }
      },
      # Keyless: run the backup Job under the SA so it inherits the IAM identity.
      var.service_account_name != null && var.backup.credentials_secret_name == null ? {
        serviceAccountName = var.service_account_name
      } : {},
    )
  }

  depends_on = [kubernetes_manifest.mariadb]
}
