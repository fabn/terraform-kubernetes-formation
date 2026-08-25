# One-off Job runner: the `heroku run` / release-phase equivalent for a
# deployed formation. The Job inherits its runtime environment from a live
# Deployment instead of re-declaring it — envFrom (which is how the
# content-hash-suffixed Secret/ConfigMap names are picked up without
# hardcoding them), imagePullSecrets and serviceAccountName are read from the
# Deployment's pod template, so the run always sees exactly the env of the
# process it belongs to, addon connection vars included. The volumes that
# process's container mounts are inherited on the same terms — storage is part
# of a process's environment, not of one invocation's configuration.

data "kubernetes_resource" "deployment" {
  api_version = "apps/v1"
  kind        = "Deployment"

  metadata {
    name      = var.deployment
    namespace = var.namespace
  }
}

locals {
  pod_spec  = data.kubernetes_resource.deployment.object.spec.template.spec
  container = try(local.pod_spec.containers[0], {})

  # The API returns the pod template with its optional fields present and set
  # to null rather than absent, and `try()` catches an *error*, not a null — so
  # `try(x, [])` around one of these collections yields the null itself and
  # hands it to the `for` that consumes it, failing the plan with "Iteration
  # over null value". A container that mounts nothing and a pod with no pull
  # secrets are the ordinary case, not an exotic one, so every optional
  # collection is read as absent-or-null here; optional *scalars* go through
  # `coalesce` at their use site.
  #
  # Neither obvious spelling of that works: the collections come back as
  # *tuples*, so `x == null ? [] : x` fails to type-check (branches are tuples
  # of different lengths), and `coalesce(x, [])` unifies the elements into a
  # map of strings — which turns `defaultMode = 420` into `"420"` and every
  # `readOnly` into a string. Filtering a one-element wrapper keeps each
  # element's own object type.
  pod_env_from     = flatten([for value in [try(local.container.envFrom, null)] : value if value != null])
  pod_mounts       = flatten([for value in [try(local.container.volumeMounts, null)] : value if value != null])
  pod_pull_secrets = flatten([for value in [try(local.pod_spec.imagePullSecrets, null)] : value if value != null])
  pod_volumes      = flatten([for value in [try(local.pod_spec.volumes, null)] : value if value != null])

  # Flatten the first container's envFrom to plain ref names; either ref kind
  # may be absent on a given entry.
  env_from = [for source in local.pod_env_from : {
    prefix         = try(source.prefix, null)
    secret_ref     = try(source.secretRef.name, null)
    config_map_ref = try(source.configMapRef.name, null)
  }]

  image_pull_secrets   = [for secret in local.pod_pull_secrets : secret.name]
  service_account_name = try(local.pod_spec.serviceAccountName, null)

  # Volumes are inherited too, and by default. A run that reads or writes a
  # directory the process mounts would otherwise see the image's own empty
  # directory: the mount path exists in the image regardless, so a read finds
  # nothing there and a write lands in the container's ephemeral layer and is
  # discarded when the run ends — neither of them raising anything. Inheriting
  # a volume that cannot be mounted fails the other way, with a Pending pod,
  # which is visible in seconds; a default whose failure is silent is the wrong
  # default. It is also the same category as everything else read here: envFrom
  # and the service account are the environment of the process, and so is its
  # storage. `heroku run` gets the dyno's filesystem for that reason — an
  # inherited emptyDir becoming a fresh per-run directory is the ephemeral dyno
  # filesystem reproduced, not a wart.
  #
  # Only the volumes the process's own container mounts are inherited: a pod
  # volume nothing mounts carries no path to reproduce it at. Every field is
  # read by name rather than copied through, because the pod template comes back
  # from the API defaulted (`mountPropagation: "None"` sits on every mount).
  # For the same reason as the collections above, every optional scalar read
  # here is wrapped in `coalesce` (absent and null both fall through to the
  # default) or left explicitly nullable where null is the value we want:
  # `try(x.readOnly, false)` yields null on a present-and-null field and the
  # null propagates into whatever consumes it.
  inherited_mounts = var.inherit_volumes ? {
    for mount in local.pod_mounts : mount.name => {
      mount_path = mount.mountPath
      sub_path   = try(mount.subPath, null)
      read_only  = coalesce(try(mount.readOnly, null), false)
    }
  } : {}

  inherited_pod_volumes = {
    for volume in local.pod_volumes : volume.name => volume
    if contains(keys(local.inherited_mounts), volume.name)
  }

  # Which source a volume actually carries, decided by value rather than by
  # `keys(volume)`: the same API defaulting means every source key can be
  # present-and-null, so a key test passes for all four at once and would
  # quietly render a hostPath as an emptyDir — the silent failure this
  # inheritance exists to close.
  #
  # `defaultMode` comes back as the decimal integer the API stores (420), while
  # the provider takes the octal string the manifest was written with ("0644").
  inherited_volume_sources = {
    for name, volume in local.inherited_pod_volumes : name => {
      secret                  = try(volume.secret.secretName, null)
      config_map              = try(volume.configMap.name, null)
      persistent_volume_claim = try(volume.persistentVolumeClaim.claimName, null)
      empty_dir               = try(volume.emptyDir, null) != null
      mode                    = try(format("0%o", volume.secret.defaultMode), format("0%o", volume.configMap.defaultMode), null)
      # Carried so a tmpfs stays a tmpfs: an emptyDir silently losing its
      # `medium` would be the same class of bug as not inheriting it at all.
      empty_dir_medium     = try(volume.emptyDir.medium, null)
      empty_dir_size_limit = try(volume.emptyDir.sizeLimit, null)
      # Read-only either way round: a claim the pod declares read-only stays
      # read-only here even when the mount itself does not say so.
      claim_read_only = coalesce(try(volume.persistentVolumeClaim.readOnly, null), false)
    }
  }

  reproducible_volumes = {
    for name, source in local.inherited_volume_sources : name => source
    if anytrue([source.secret != null, source.config_map != null, source.persistent_volume_claim != null, source.empty_dir])
  }

  inherited_volumes = {
    for name, source in local.reproducible_volumes : name => {
      name                    = name
      mount_path              = local.inherited_mounts[name].mount_path
      sub_path                = local.inherited_mounts[name].sub_path
      read_only               = local.inherited_mounts[name].read_only || source.claim_read_only
      secret                  = source.secret
      config_map              = source.config_map
      persistent_volume_claim = source.persistent_volume_claim
      mode                    = source.mode
      empty_dir_medium        = source.empty_dir_medium
      empty_dir_size_limit    = source.empty_dir_size_limit
    }
  }

  # Reported rather than dropped: a volume the module cannot reproduce is
  # exactly the silent gap this inheritance exists to close (see the
  # precondition on the Job).
  unsupported_volumes = [
    for name, source in local.inherited_volume_sources : name
    if !contains(keys(local.reproducible_volumes), name)
  ]

  # `volumes` is additive to what was inherited; an entry of the same name
  # replaces the inherited one, which is how a run changes a mount path or
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

  # The run must NOT inherit the Deployment's own identity label.
  # `app.kubernetes.io/name = <deployment>` is what the workload module uses as
  # the selector of the Deployment, its Service, its ServiceMonitor and its
  # PodDisruptionBudget — so a Job pod carrying it is picked up by all of them:
  #
  #   - PDB: to compute the expected pod count the disruption controller
  #     resolves each covered pod's controller and queries its `scale`
  #     subresource. Job does not implement it, so the sync fails with
  #     `CalculateExpectedPodCountFailed` and the PDB status stops being updated
  #     for as long as a run pod exists (run duration + ttl_seconds_after_finished).
  #   - Service: the run pod becomes eligible for the web Service's endpoints
  #     as soon as it is Ready, which sends live traffic to a pod that only runs
  #     the one-off command.
  #
  # So the run gets its own name — mirroring how a sibling process is named
  # `<app>-<process>` upstream, and matching the Job's own generate_name — and
  # keeps the relationship discoverable through part-of.
  labels = {
    "app.kubernetes.io/name"       = "${var.deployment}-${var.name}"
    "app.kubernetes.io/component"  = var.name
    "app.kubernetes.io/part-of"    = var.deployment
    "app.kubernetes.io/managed-by" = "terraform"
  }

  # Extra labels for the run's pod only. A mutating admission webhook acts on
  # the Pod at create time, so a label on the Job never reaches it — Datadog's
  # `admission.datadoghq.com/enabled = "true"` is the motivating case, exactly
  # as in the `cron` submodule. `local.labels` is merged last on purpose: the
  # four identity keys above are what keeps the run pod out of the Deployment's
  # Service, PDB and ServiceMonitor selectors, so they must not be overridable
  # from the outside.
  pod_labels = merge(var.pod_labels, local.labels)
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

  timeouts {
    create = var.timeout
  }

  lifecycle {
    precondition {
      condition     = length(local.unsupported_volumes) == 0
      error_message = "Cannot reproduce the volume(s) ${join(", ", local.unsupported_volumes)} of Deployment ${var.deployment}: only secret, configMap, persistentVolumeClaim and emptyDir sources are inherited. Set inherit_volumes = false and declare what the run needs through `volumes`."
    }
  }
}
