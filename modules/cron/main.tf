# Scheduled task runner: the `heroku scheduler` equivalent for a deployed
# formation, and the recurring counterpart of the `run` submodule. The CronJob
# inherits its runtime environment from a live Deployment instead of
# re-declaring it — envFrom (which is how the content-hash-suffixed
# Secret/ConfigMap names are picked up without hardcoding them),
# imagePullSecrets and serviceAccountName are read from the Deployment's pod
# template, so every tick sees exactly the env of the process it belongs to,
# addon connection vars included.
#
# Why this is not just a process in the formation: a formation entry is a
# Deployment, so a task that should run for ten seconds every five minutes
# would instead run forever and be restarted by the kubelet each time it
# exited. Applications whose scheduler is a separate periodic command — a CMS
# firing due events, a cleanup task, a feed refresh — have no way to express
# that today short of a hand-rolled resource in the consuming stack.

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

  name = "${var.deployment}-${var.name}"

  # The scheduled pods must NOT inherit the Deployment's own identity label,
  # for the same reason the `run` submodule avoids it:
  # `app.kubernetes.io/name = <deployment>` is the selector of the Deployment,
  # its Service, its ServiceMonitor and its PodDisruptionBudget, so a pod
  # carrying it is picked up by all of them. A Service would route live
  # requests to a pod that only runs the scheduled command, and the disruption
  # controller would fail to resolve a Job's `scale` subresource and stop
  # updating the PDB's status.
  #
  # It matters more here than for a one-off: a CronJob produces such a pod on
  # every tick, forever, so the damage is recurring rather than bounded by one
  # run's duration.
  labels = {
    "app.kubernetes.io/name"       = local.name
    "app.kubernetes.io/component"  = var.name
    "app.kubernetes.io/part-of"    = var.deployment
    "app.kubernetes.io/managed-by" = "terraform"
  }

  # Extra labels for the tick pods only. A mutating admission webhook acts on
  # the Pod at create time, so a label on the CronJob or on the Job never
  # reaches it — Datadog's `admission.datadoghq.com/enabled = "true"` is the
  # motivating case: with it, every tick pod gets the agent's hostPath volume,
  # `DD_TRACE_AGENT_URL` on the socket and the UST tags injected, instead of the
  # caller hand-wiring `DD_TRACE_AGENT_URL` at the agent's Service through
  # `env`. `local.labels` is merged last on purpose: the four identity keys
  # above are what keeps a tick pod out of the Deployment's Service, PDB and
  # ServiceMonitor selectors, so they must not be overridable from the outside.
  pod_labels = merge(var.pod_labels, local.labels)
}

resource "kubernetes_cron_job_v1" "cron" {
  metadata {
    name      = local.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    schedule                      = var.schedule
    timezone                      = var.timezone
    concurrency_policy            = var.concurrency_policy
    starting_deadline_seconds     = var.starting_deadline_seconds
    suspend                       = var.suspend
    successful_jobs_history_limit = var.successful_jobs_history_limit
    failed_jobs_history_limit     = var.failed_jobs_history_limit

    job_template {
      metadata {
        labels = local.labels
      }

      spec {
        backoff_limit              = var.backoff_limit
        ttl_seconds_after_finished = var.ttl_seconds_after_finished
        active_deadline_seconds    = var.active_deadline_seconds

        template {
          metadata {
            labels = local.pod_labels
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

            container {
              name    = var.name
              image   = var.image
              command = var.command

              resources {
                requests = {
                  cpu    = var.cpu_requests
                  memory = var.memory_requests
                }
                limits = var.memory_limits == null ? {} : {
                  memory = var.memory_limits
                }
              }

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
    }
  }
}
