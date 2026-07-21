locals {
  ns = var.create_namespace ? kubernetes_namespace_v1.ns[0].metadata[0].name : var.namespace

  datadog_service = coalesce(var.datadog_service, var.name)
  datadog_env     = coalesce(var.datadog_env, var.environment)
  datadog_ust_tags = merge(
    {
      service = local.datadog_service
      env     = local.datadog_env
    },
    var.datadog_team != null ? { team = var.datadog_team } : {},
  )
}

resource "kubernetes_namespace_v1" "ns" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
    labels = merge(
      {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = var.name
        "${var.name}/environment"      = var.environment
      },
      var.namespace_labels,
    )
  }
}

resource "random_id" "secret_key_base" {
  byte_length = 64
}

# Shared Secret sourced by every process. SECRET_KEY_BASE is generated so
# nothing sensitive needs to live in plaintext for ephemeral environments;
# callers can still override it via var.secret_env (merged last).
module "secrets" {
  source  = "fabn/workload/kubernetes//modules/secret"
  version = "~> 0.7"

  namespace   = local.ns
  name_prefix = "${var.name}-secrets"

  data = merge(
    { SECRET_KEY_BASE = random_id.secret_key_base.hex },
    var.secret_env,
  )
}

module "config" {
  source  = "fabn/workload/kubernetes//modules/config-map"
  version = "~> 0.7"

  namespace   = local.ns
  name_prefix = "${var.name}-config"

  data = var.env
}

module "registry_credentials" {
  source  = "fabn/workload/kubernetes//modules/secret"
  version = "~> 0.7"

  namespace   = local.ns
  name_prefix = "${var.name}-registry-pull"
  type        = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (var.registry_server) = {
          username = var.registry_username
          password = var.registry_password
          auth     = base64encode("${var.registry_username}:${var.registry_password}")
        }
      }
    })
  }
}
