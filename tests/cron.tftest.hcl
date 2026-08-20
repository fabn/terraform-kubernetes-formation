# =============================================================================
# Cron Submodule Tests
# =============================================================================
# Scheduled tasks inherit their runtime environment (envFrom, imagePullSecrets,
# serviceAccountName and the volumes its container mounts) from a live
# Deployment, like the run submodule; the Deployment read is stubbed with
# override_data.

mock_provider "kubernetes" {}

variables {
  namespace  = "cron-test"
  deployment = "myapp"
  image      = "ghcr.io/acme/myapp:1.0.0"
  command    = ["/bin/bash", "-lc", "bin/rails runner Scheduler.tick"]
  schedule   = "*/5 * * * *"
}

override_data {
  target = data.kubernetes_resource.deployment
  values = {
    object = {
      spec = {
        template = {
          spec = {
            serviceAccountName = "myapp"
            imagePullSecrets   = [{ name = "myapp-registry-pull-abc123" }]
            # The pod template comes back from the API defaulted, hence the
            # `mountPropagation` the module is expected to normalise away, and
            # the decimal `defaultMode` (420 == 0644) it must render back as the
            # octal string the provider takes.
            volumes = [
              { name = "uploads", persistentVolumeClaim = { claimName = "myapp-uploads" } },
              { name = "tls", secret = { secretName = "myapp-tls", defaultMode = 420 } },
              { name = "tmp", emptyDir = { medium = "Memory", sizeLimit = "64Mi" } },
              { name = "unmounted", persistentVolumeClaim = { claimName = "myapp-elsewhere" } },
            ]
            containers = [{
              name = "myapp"
              envFrom = [
                { secretRef = { name = "myapp-secrets-abc123" } },
                { configMapRef = { name = "myapp-config-def456" } },
              ]
              volumeMounts = [
                { name = "uploads", mountPath = "/var/www/html/web/app/uploads", mountPropagation = "None" },
                { name = "tls", mountPath = "/etc/tls", readOnly = true, mountPropagation = "None" },
                { name = "tmp", mountPath = "/tmp", mountPropagation = "None" },
              ]
            }]
          }
        }
      }
    }
  }
}

# Test: the CronJob inherits envFrom / pull secrets / service account from the
# Deployment and pins the explicit image, command and schedule
run "inherits_runtime_environment" {
  command = plan

  module {
    source = "./modules/cron"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].container[0].env_from[0].secret_ref[0].name == "myapp-secrets-abc123"
    error_message = "CronJob should inherit the Deployment's secretRef envFrom"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].container[0].env_from[1].config_map_ref[0].name == "myapp-config-def456"
    error_message = "CronJob should inherit the Deployment's configMapRef envFrom"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].image_pull_secrets[0].name == "myapp-registry-pull-abc123"
    error_message = "CronJob should inherit the Deployment's imagePullSecrets"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].service_account_name == "myapp"
    error_message = "CronJob should inherit the Deployment's serviceAccountName"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].schedule == "*/5 * * * *"
    error_message = "CronJob should carry the requested schedule"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].container[0].image == "ghcr.io/acme/myapp:1.0.0"
    error_message = "CronJob should pin the explicit image"
  }
}

# Test: naming and labels. The scheduled pods must not carry the Deployment's
# identity label, or the web Service would route live traffic to them and the
# PDB would try to resolve a Job's scale subresource — on every tick, forever.
run "named_apart_from_the_deployment" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    name = "scheduler"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.metadata[0].name == "myapp-scheduler"
    error_message = "CronJob should be named <deployment>-<name>"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/name"] == "myapp-scheduler"
    error_message = "Tick pods must not carry the Deployment's own identity label"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/part-of"] == "myapp"
    error_message = "Tick pods should stay discoverable through part-of"
  }
}

# Test: extra pod labels land on the pod template inside jobTemplate — the
# level a mutating admission webhook (Datadog's, here) actually sees — without
# leaking onto the CronJob or the Job, and without displacing the identity
# labels that keep tick pods out of the Deployment's selectors.
run "pod_labels_reach_the_tick_pods_only" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    name = "scheduler"
    pod_labels = {
      "admission.datadoghq.com/enabled" = "true"
      "tags.datadoghq.com/service"      = "myapp"
    }
  }

  assert {
    condition = (
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["admission.datadoghq.com/enabled"] == "true" &&
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["tags.datadoghq.com/service"] == "myapp"
    )
    error_message = "pod_labels should land on the pod template inside jobTemplate"
  }

  assert {
    condition = !contains(
      keys(kubernetes_cron_job_v1.cron.metadata[0].labels),
      "admission.datadoghq.com/enabled"
    )
    error_message = "pod_labels should not reach the CronJob's own labels"
  }

  assert {
    condition = !contains(
      keys(kubernetes_cron_job_v1.cron.spec[0].job_template[0].metadata[0].labels),
      "admission.datadoghq.com/enabled"
    )
    error_message = "pod_labels should not reach the Job template's labels"
  }

  # The four identity labels must survive the merge untouched: they are what
  # keeps a tick pod out of the Deployment's Service, PDB and ServiceMonitor.
  assert {
    condition = (
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/name"] == "myapp-scheduler" &&
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/component"] == "scheduler" &&
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/part-of"] == "myapp" &&
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/managed-by"] == "terraform"
    )
    error_message = "pod_labels should merge with the standard labels, not replace them"
  }
}

# Test: pod_labels cannot hand a tick pod the Deployment's identity, however it
# is spelled — the module's own labels are merged last
run "pod_labels_cannot_override_the_identity_labels" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    pod_labels = {
      "app.kubernetes.io/name"       = "myapp"
      "app.kubernetes.io/managed-by" = "somebody-else"
    }
  }

  assert {
    condition = (
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/name"] == "myapp-cron" &&
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels["app.kubernetes.io/managed-by"] == "terraform"
    )
    error_message = "pod_labels must not be able to override the app.kubernetes.io/* labels"
  }
}

# Test: unset pod_labels leaves the rendered pod template as it was
run "pod_labels_absent_by_default" {
  command = plan

  module {
    source = "./modules/cron"
  }

  assert {
    condition = length(
      kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].metadata[0].labels
    ) == 4
    error_message = "An unset pod_labels should add nothing to the pod template"
  }
}

# Test: the defaults that keep a slow tick from compounding
run "safe_scheduling_defaults" {
  command = plan

  module {
    source = "./modules/cron"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].concurrency_policy == "Forbid"
    error_message = "A tick due while the previous one runs should be skipped, not stacked"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].backoff_limit == 0
    error_message = "A recurring task gets its retry from the next tick, not from a backoff"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].successful_jobs_history_limit == 1
    error_message = "A frequent schedule should not leave three completed Jobs behind each time"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].suspend == false
    error_message = "A cron should fire unless explicitly suspended"
  }
}

# Test: suspend is reachable without destroying the resource — the switch a
# maintenance window or a cutover freeze needs
run "suspendable" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    suspend = true
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].suspend == true
    error_message = "suspend should stop the schedule while leaving the CronJob in place"
  }
}

# Test: a malformed schedule fails at plan, not at the first missed tick
run "validation_rejects_a_malformed_schedule" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    schedule = "*/5 * *"
  }

  expect_failures = [var.schedule]
}

# =============================================================================
# Volumes
# =============================================================================

# Test: the tick pod mounts the volumes the process's own container mounts, at
# the same paths. Without this a scheduled task sees the image's own empty
# directory at the mount path and writes into the container's ephemeral layer —
# silently, because the path exists either way.
run "inherits_the_process_volumes" {
  command = plan

  module {
    source = "./modules/cron"
  }

  assert {
    condition = one([
      for volume in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume :
      volume.persistent_volume_claim[0].claim_name if volume.name == "uploads"
    ]) == "myapp-uploads"
    error_message = "The tick pod should carry the claim the process mounts"
  }

  assert {
    condition = one([
      for mount in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].container[0].volume_mount :
      mount.mount_path if mount.name == "uploads"
    ]) == "/var/www/html/web/app/uploads"
    error_message = "The claim should be mounted at the path the process mounts it at"
  }

  # defaultMode comes back from the API as the decimal 420 and has to be
  # rendered as the octal string the provider takes, or 420 is read as octal.
  assert {
    condition = one([
      for volume in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume :
      volume.secret[0].default_mode if volume.name == "tls"
    ]) == "0644"
    error_message = "An inherited secret volume should keep its defaultMode, converted to octal"
  }

  assert {
    condition = one([
      for mount in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].container[0].volume_mount :
      mount.read_only if mount.name == "tls"
    ]) == true
    error_message = "An inherited read-only mount should stay read-only"
  }

  # A fresh per-tick emptyDir is the ephemeral dyno filesystem, correctly
  # reproduced — but a tmpfs must stay a tmpfs.
  assert {
    condition = one([
      for volume in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume :
      volume.empty_dir[0].medium if volume.name == "tmp"
    ]) == "Memory"
    error_message = "An inherited emptyDir should keep its medium"
  }

  # A pod volume the container does not mount carries no path to reproduce it
  # at, so it is not inherited.
  assert {
    condition = length([
      for volume in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume :
      volume.name if volume.name == "unmounted"
    ]) == 0
    error_message = "A pod volume the process's container does not mount should not be inherited"
  }
}

# Test: `volumes` adds to what was inherited rather than replacing it
run "extra_volumes_are_additive" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    volumes = [{
      name       = "scratch"
      mount_path = "/scratch"
    }]
  }

  assert {
    condition     = length(kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume) == 4
    error_message = "An extra volume should be added to the three inherited ones"
  }

  assert {
    condition = length(one([
      for volume in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume :
      volume.empty_dir if volume.name == "scratch"
    ])) == 1
    error_message = "A volume declaring no source should render an emptyDir"
  }

  assert {
    condition = one([
      for volume in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume :
      volume.persistent_volume_claim[0].claim_name if volume.name == "uploads"
    ]) == "myapp-uploads"
    error_message = "The inherited volumes should survive an extra one"
  }
}

# Test: an entry of the same name replaces the inherited volume, so a tick can
# swap a claim or a path without giving up the rest
run "extra_volumes_override_an_inherited_name" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    volumes = [{
      name                    = "uploads"
      mount_path              = "/var/www/html/web/app/uploads"
      persistent_volume_claim = "myapp-uploads-readonly"
      read_only               = true
    }]
  }

  assert {
    condition     = length(kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume) == 3
    error_message = "An entry of an inherited name should replace it, not duplicate it"
  }

  assert {
    condition = one([
      for volume in kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume :
      volume.persistent_volume_claim[0].claim_name if volume.name == "uploads"
    ]) == "myapp-uploads-readonly"
    error_message = "The declared claim should win over the inherited one"
  }
}

# Test: inheritance is switchable off for the caller it is wrong for, and
# `volumes` still works on its own
run "inheritance_can_be_disabled" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    inherit_volumes = false
    volumes = [{
      name                    = "backups"
      mount_path              = "/backups"
      persistent_volume_claim = "myapp-backups"
    }]
  }

  assert {
    condition     = length(kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume) == 1
    error_message = "inherit_volumes = false should leave only the declared volumes"
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume[0].name == "backups"
    error_message = "The declared volume should still be mounted with inheritance off"
  }
}

# Test: a Deployment without volumes inherits none, rather than failing
run "deployment_without_volumes" {
  command = plan

  module {
    source = "./modules/cron"
  }

  override_data {
    target = data.kubernetes_resource.deployment
    values = {
      object = {
        spec = {
          template = {
            spec = {
              containers = [{ name = "myapp" }]
            }
          }
        }
      }
    }
  }

  assert {
    condition     = length(kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].volume) == 0
    error_message = "No volume should be produced for a Deployment without any"
  }
}

# Test: a volume source the module cannot reproduce fails the plan instead of
# being dropped — a silently missing mount is the defect this inheritance
# exists to close
run "unsupported_volume_source_fails_the_plan" {
  command = plan

  module {
    source = "./modules/cron"
  }

  override_data {
    target = data.kubernetes_resource.deployment
    values = {
      object = {
        spec = {
          template = {
            spec = {
              volumes = [{ name = "docker-socket", hostPath = { path = "/var/run/docker.sock" } }]
              containers = [{
                name         = "myapp"
                volumeMounts = [{ name = "docker-socket", mountPath = "/var/run/docker.sock" }]
              }]
            }
          }
        }
      }
    }
  }

  expect_failures = [kubernetes_cron_job_v1.cron]
}

# Test: two sources on one volume are rejected at plan time
run "validation_rejects_two_volume_sources" {
  command = plan

  module {
    source = "./modules/cron"
  }

  variables {
    volumes = [{
      name                    = "confused"
      mount_path              = "/confused"
      secret                  = "myapp-tls"
      persistent_volume_claim = "myapp-uploads"
    }]
  }

  expect_failures = [var.volumes]
}

# Test: a claim the pod declares read-only stays read-only in the tick, even
# when the mount itself does not say so
run "pod_level_read_only_claim_is_honoured" {
  command = plan

  module {
    source = "./modules/cron"
  }

  override_data {
    target = data.kubernetes_resource.deployment
    values = {
      object = {
        spec = {
          template = {
            spec = {
              volumes = [{ name = "assets", persistentVolumeClaim = { claimName = "myapp-assets", readOnly = true } }]
              containers = [{
                name         = "myapp"
                volumeMounts = [{ name = "assets", mountPath = "/assets" }]
              }]
            }
          }
        }
      }
    }
  }

  assert {
    condition     = kubernetes_cron_job_v1.cron.spec[0].job_template[0].spec[0].template[0].spec[0].container[0].volume_mount[0].read_only == true
    error_message = "A claim the pod declares read-only should be mounted read-only"
  }
}
