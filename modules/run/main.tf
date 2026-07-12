# One-off Job runner: the `heroku run` / release-phase equivalent for a
# deployed formation. The Job inherits its runtime environment from a live
# Deployment instead of re-declaring it — envFrom (which is how the
# content-hash-suffixed Secret/ConfigMap names are picked up without
# hardcoding them), imagePullSecrets and serviceAccountName are read from the
# Deployment's pod template, so the run always sees exactly the env of the
# process it belongs to, addon connection vars included.

data "kubernetes_resource" "deployment" {
  api_version = "apps/v1"
  kind        = "Deployment"

  metadata {
    name      = var.deployment
    namespace = var.namespace
  }
}

locals {
  pod_spec = data.kubernetes_resource.deployment.object.spec.template.spec

  # Flatten the first container's envFrom to plain ref names; either ref kind
  # may be absent on a given entry.
  env_from = [for source in try(local.pod_spec.containers[0].envFrom, []) : {
    prefix         = try(source.prefix, null)
    secret_ref     = try(source.secretRef.name, null)
    config_map_ref = try(source.configMapRef.name, null)
  }]

  image_pull_secrets   = [for secret in try(local.pod_spec.imagePullSecrets, []) : secret.name]
  service_account_name = try(local.pod_spec.serviceAccountName, null)

  labels = {
    "app.kubernetes.io/name"       = var.deployment
    "app.kubernetes.io/component"  = var.name
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

resource "kubernetes_job_v1" "run" {
  wait_for_completion = var.wait_for_completion

  metadata {
    generate_name = "${var.deployment}-${var.name}-"
    namespace     = var.namespace
    labels        = local.labels
  }

  spec {
    backoff_limit              = var.backoff_limit
    ttl_seconds_after_finished = var.ttl_seconds_after_finished
    active_deadline_seconds    = var.active_deadline_seconds

    template {
      metadata {
        labels = local.labels
      }

      spec {
        restart_policy       = "Never"
        service_account_name = local.service_account_name

        dynamic "image_pull_secrets" {
          for_each = local.image_pull_secrets
          content {
            name = image_pull_secrets.value
          }
        }

        dynamic "init_container" {
          for_each = var.init_command != null ? [var.init_command] : []
          content {
            name    = "init"
            image   = var.image
            command = init_container.value

            dynamic "env_from" {
              for_each = local.env_from
              content {
                prefix = env_from.value.prefix

                dynamic "secret_ref" {
                  for_each = env_from.value.secret_ref != null ? [env_from.value.secret_ref] : []
                  content {
                    name = secret_ref.value
                  }
                }

                dynamic "config_map_ref" {
                  for_each = env_from.value.config_map_ref != null ? [env_from.value.config_map_ref] : []
                  content {
                    name = config_map_ref.value
                  }
                }
              }
            }

            dynamic "env" {
              for_each = var.env
              content {
                name  = env.key
                value = env.value
              }
            }
          }
        }

        container {
          name    = var.name
          image   = var.image
          command = var.command

          dynamic "env_from" {
            for_each = local.env_from
            content {
              prefix = env_from.value.prefix

              dynamic "secret_ref" {
                for_each = env_from.value.secret_ref != null ? [env_from.value.secret_ref] : []
                content {
                  name = secret_ref.value
                }
              }

              dynamic "config_map_ref" {
                for_each = env_from.value.config_map_ref != null ? [env_from.value.config_map_ref] : []
                content {
                  name = config_map_ref.value
                }
              }
            }
          }

          dynamic "env" {
            for_each = var.env
            content {
              name  = env.key
              value = env.value
            }
          }
        }
      }
    }
  }

  timeouts {
    create = var.timeout
  }
}
