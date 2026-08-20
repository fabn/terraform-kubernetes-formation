# Scheduled task runner: the `heroku scheduler` equivalent for a deployed
# formation, and the recurring counterpart of the `run` submodule. The CronJob
# inherits its runtime environment from a live Deployment instead of
# re-declaring it — envFrom (which is how the content-hash-suffixed
# Secret/ConfigMap names are picked up without hardcoding them),
# imagePullSecrets and serviceAccountName are read from the Deployment's pod
# template, so every tick sees exactly the env of the process it belongs to,
# addon connection vars included. The volumes that process's container mounts
# are inherited on the same terms — storage is part of a process's environment,
# not of one invocation's configuration.
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

  # Volumes are inherited too, and by default. A tick that reads or writes a
  # directory the process mounts would otherwise see the image's own empty
  # directory: the mount path exists in the image regardless, so a read finds
  # nothing there and a write lands in the container's ephemeral layer and is
  # discarded when the tick ends — neither of them raising anything. Inheriting
  # a volume that cannot be mounted fails the other way, with a Pending pod,
  # which is visible in seconds; a default whose failure is silent is the wrong
  # default. It is also the same category as everything else read here: envFrom
  # and the service account are the environment of the process, and so is its
  # storage. `heroku scheduler` gets the dyno's filesystem for that reason — an
  # inherited emptyDir becoming a fresh per-tick directory is the ephemeral dyno
  # filesystem reproduced, not a wart.
  #
  # Only the volumes the process's own container mounts are inherited: a pod
  # volume nothing mounts carries no path to reproduce it at. Every field is
  # read by name rather than copied through, because the pod template comes back
  # from the API defaulted (`mountPropagation: "None"` sits on every mount).
  inherited_mounts = var.inherit_volumes ? {
    for mount in try(local.pod_spec.containers[0].volumeMounts, []) : mount.name => {
      mount_path = mount.mountPath
      sub_path   = try(mount.subPath, null)
      read_only  = try(mount.readOnly, false)
    }
  } : {}

  inherited_pod_volumes = {
    for volume in try(local.pod_spec.volumes, []) : volume.name => volume
    if contains(keys(local.inherited_mounts), volume.name)
  }

  # The sources this module reproduces — the ones a formation process can
  # declare. `defaultMode` comes back as the decimal integer the API stores
  # (420), while the provider takes the octal string the manifest was written
  # with ("0644").
  volume_sources = toset(["secret", "configMap", "persistentVolumeClaim", "emptyDir"])

  inherited_volumes = {
    for name, volume in local.inherited_pod_volumes : name => {
      name       = name
      mount_path = local.inherited_mounts[name].mount_path
      sub_path   = local.inherited_mounts[name].sub_path
      # Read-only either way round: a claim the pod declares read-only stays
      # read-only here even when the mount itself does not say so.
      read_only               = local.inherited_mounts[name].read_only || try(volume.persistentVolumeClaim.readOnly, false)
      secret                  = try(volume.secret.secretName, null)
      config_map              = try(volume.configMap.name, null)
      persistent_volume_claim = try(volume.persistentVolumeClaim.claimName, null)
      mode                    = try(format("0%o", volume.secret.defaultMode), format("0%o", volume.configMap.defaultMode), null)
      # Carried so a tmpfs stays a tmpfs: an emptyDir silently losing its
      # `medium` would be the same class of bug as not inheriting it at all.
      empty_dir_medium     = try(volume.emptyDir.medium, null)
      empty_dir_size_limit = try(volume.emptyDir.sizeLimit, null)
    }
    if length(setintersection(keys(volume), local.volume_sources)) > 0
  }

  # Reported rather than dropped: a volume the module cannot reproduce is
  # exactly the silent gap this inheritance exists to close (see the
  # precondition on the CronJob).
  unsupported_volumes = [
    for name, volume in local.inherited_pod_volumes : name
    if length(setintersection(keys(volume), local.volume_sources)) == 0
  ]

  # `volumes` is additive to what was inherited; an entry of the same name
  # replaces the inherited one, which is how a tick changes a mount path or
  # swaps a claim without giving up the rest.
  volumes = values(merge(local.inherited_volumes, {
    for volume in var.volumes : volume.name => {
      name                    = volume.name
      mount_path              = volume.mount_path
      sub_path                = volume.sub_path
      read_only               = volume.read_only
      secret                  = volume.secret
      config_map              = volume.config_map
      persistent_volume_claim = volume.persistent_volume_claim
      mode                    = volume.mode
      empty_dir_medium        = null
      empty_dir_size_limit    = null
    }
  }))

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

            dynamic "volume" {
              for_each = local.volumes
              content {
                name = volume.value.name

                dynamic "secret" {
                  for_each = volume.value.secret != null ? [volume.value.secret] : []
                  content {
                    secret_name  = secret.value
                    default_mode = volume.value.mode
                  }
                }

                dynamic "config_map" {
                  for_each = volume.value.config_map != null ? [volume.value.config_map] : []
                  content {
                    name         = config_map.value
                    default_mode = volume.value.mode
                  }
                }

                dynamic "persistent_volume_claim" {
                  for_each = volume.value.persistent_volume_claim != null ? [volume.value.persistent_volume_claim] : []
                  content {
                    claim_name = persistent_volume_claim.value
                    read_only  = volume.value.read_only
                  }
                }

                # No source set is an emptyDir, the same way it is upstream.
                dynamic "empty_dir" {
                  for_each = anytrue([volume.value.secret != null, volume.value.config_map != null, volume.value.persistent_volume_claim != null]) ? [] : [volume.value]
                  content {
                    medium     = empty_dir.value.empty_dir_medium
                    size_limit = empty_dir.value.empty_dir_size_limit
                  }
                }
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

              dynamic "volume_mount" {
                for_each = local.volumes
                content {
                  name       = volume_mount.value.name
                  mount_path = volume_mount.value.mount_path
                  sub_path   = volume_mount.value.sub_path
                  read_only  = volume_mount.value.read_only
                }
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.unsupported_volumes) == 0
      error_message = "Cannot reproduce the volume(s) ${join(", ", local.unsupported_volumes)} of Deployment ${var.deployment}: only secret, configMap, persistentVolumeClaim and emptyDir sources are inherited. Set inherit_volumes = false and declare what the tick needs through `volumes`."
    }
  }
}
