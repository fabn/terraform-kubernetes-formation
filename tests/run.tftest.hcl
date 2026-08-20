# =============================================================================
# Run Submodule Tests
# =============================================================================
# One-off Jobs inherit their runtime environment (envFrom, imagePullSecrets,
# serviceAccountName and the volumes its container mounts) from a live
# Deployment; the Deployment read is stubbed with override_data.

mock_provider "kubernetes" {}

variables {
  namespace  = "run-test"
  deployment = "myapp"
  image      = "ghcr.io/acme/myapp:1.0.0"
  command    = ["/bin/bash", "-lc", "bin/rails db:migrate"]
}

# The pod template a formation web Deployment would carry: envFrom pointing at
# the content-hash-suffixed Secret/ConfigMap, a registry pull secret and a
# service account.
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

# Test: the Job inherits envFrom / pull secrets / service account from the
# Deployment and pins the explicit image + command
run "inherits_runtime_environment" {
  command = plan

  module {
    source = "./modules/run"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].env_from[0].secret_ref[0].name == "myapp-secrets-abc123"
    error_message = "Job should inherit the Deployment's secretRef envFrom"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].env_from[1].config_map_ref[0].name == "myapp-config-def456"
    error_message = "Job should inherit the Deployment's configMapRef envFrom"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].image_pull_secrets[0].name == "myapp-registry-pull-abc123"
    error_message = "Job should inherit the Deployment's imagePullSecrets"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].service_account_name == "myapp"
    error_message = "Job should inherit the Deployment's serviceAccountName"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].image == "ghcr.io/acme/myapp:1.0.0"
    error_message = "Image should be the explicit input, never read from the Deployment"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].command[2] == "bin/rails db:migrate"
    error_message = "Container should run the given command"
  }
}

# Test: one-shot Job shape (no retries, TTL cleanup, Never restart, blocking
# apply) and Heroku-like naming/labels
run "one_shot_job_shape" {
  command = plan

  module {
    source = "./modules/run"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].backoff_limit == 0 && kubernetes_job_v1.run.spec[0].ttl_seconds_after_finished == "600"
    error_message = "Job should default to no retries and a 600s post-completion TTL"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].restart_policy == "Never"
    error_message = "Job pods should never restart in place"
  }

  assert {
    condition     = kubernetes_job_v1.run.wait_for_completion == true
    error_message = "Apply should block on Job completion by default"
  }

  assert {
    condition     = kubernetes_job_v1.run.metadata[0].generate_name == "myapp-run-"
    error_message = "Jobs should be generate_name'd <deployment>-<name>-"
  }

  assert {
    condition     = kubernetes_job_v1.run.metadata[0].labels["app.kubernetes.io/name"] == "myapp-run" && kubernetes_job_v1.run.metadata[0].labels["app.kubernetes.io/component"] == "run"
    error_message = "Job labels should carry its own name and the component"
  }

  assert {
    condition     = kubernetes_job_v1.run.metadata[0].labels["app.kubernetes.io/part-of"] == "myapp"
    error_message = "Job labels should keep the deployment grouping via part-of"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].init_container) == 0
    error_message = "No init container should exist without init_command"
  }
}

# Test: no Job pod may carry app.kubernetes.io/name == <deployment>. That label
# is the selector of the Deployment's Service, ServiceMonitor and
# PodDisruptionBudget upstream; a pod matching it freezes the PDB status
# (CalculateExpectedPodCountFailed: Job has no scale subresource) and becomes
# eligible for the web Service's endpoints.
run "pod_labels_do_not_collide_with_deployment_selector" {
  command = plan

  module {
    source = "./modules/run"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].metadata[0].labels["app.kubernetes.io/name"] != var.deployment
    error_message = "Job pods must not carry the Deployment's own app.kubernetes.io/name"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].metadata[0].labels["app.kubernetes.io/name"] == "myapp-run"
    error_message = "Job pods should be labelled with the run's own name"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].metadata[0].labels["app.kubernetes.io/part-of"] == "myapp"
    error_message = "Job pods should stay grouped with the deployment via part-of"
  }
}

# Test: init_command adds an init container sharing image and inherited env
run "init_container_from_init_command" {
  command = plan

  module {
    source = "./modules/run"
  }

  variables {
    init_command = ["/bin/bash", "-lc", "until pg_isready -t 5; do sleep 2; done"]
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].init_container[0].command[2] == "until pg_isready -t 5; do sleep 2; done"
    error_message = "Init container should run init_command"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].init_container[0].image == "ghcr.io/acme/myapp:1.0.0"
    error_message = "Init container should share the Job image"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].init_container[0].env_from) == 2
    error_message = "Init container should inherit the Deployment envFrom too"
  }
}

# Test: extra env vars land on the container on top of the inherited envFrom
run "extra_env_merged" {
  command = plan

  module {
    source = "./modules/run"
  }

  variables {
    env = {
      SEED_COSTUMES = "1"
    }
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].env[0].name == "SEED_COSTUMES" && kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].env[0].value == "1"
    error_message = "Extra env vars should be set on the Job container"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].env_from) == 2
    error_message = "Inherited envFrom should survive the extra env merge"
  }
}

# Test: knob overrides flow through to the Job spec
run "knob_overrides" {
  command = plan

  module {
    source = "./modules/run"
  }

  variables {
    name                       = "release"
    backoff_limit              = 2
    ttl_seconds_after_finished = 60
    active_deadline_seconds    = 300
    wait_for_completion        = false
  }

  assert {
    condition     = kubernetes_job_v1.run.metadata[0].generate_name == "myapp-release-"
    error_message = "The name variable should drive the Job name infix"
  }

  assert {
    condition     = kubernetes_job_v1.run.metadata[0].labels["app.kubernetes.io/component"] == "release" && kubernetes_job_v1.run.metadata[0].labels["app.kubernetes.io/name"] == "myapp-release"
    error_message = "The name variable should drive the component and name labels"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].backoff_limit == 2 && kubernetes_job_v1.run.spec[0].ttl_seconds_after_finished == "60" && kubernetes_job_v1.run.spec[0].active_deadline_seconds == 300
    error_message = "Job spec knobs should follow the variables"
  }

  assert {
    condition     = kubernetes_job_v1.run.wait_for_completion == false
    error_message = "wait_for_completion should be overridable"
  }
}

# Test: a bare Deployment (no SA, no pull secrets, no envFrom) inherits as
# empty, not as an error
run "bare_deployment" {
  command = plan

  module {
    source = "./modules/run"
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
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].env_from) == 0
    error_message = "No envFrom should be produced for a Deployment without one"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].image_pull_secrets) == 0
    error_message = "No pull secrets should be produced for a Deployment without them"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].volume) == 0
    error_message = "No volume should be produced for a Deployment without any"
  }
}

# Test: an empty command is rejected
run "validation_rejects_empty_command" {
  command = plan

  module {
    source = "./modules/run"
  }

  variables {
    command = []
  }

  expect_failures = [var.command]
}

# =============================================================================
# Volumes
# =============================================================================

# Test: the Job pod mounts the volumes the process's own container mounts, at
# the same paths. Without this a run reads the image's own empty directory at
# the mount path and writes into the container's ephemeral layer — silently,
# because the path exists either way.
run "inherits_the_process_volumes" {
  command = plan

  module {
    source = "./modules/run"
  }

  assert {
    condition = one([
      for volume in kubernetes_job_v1.run.spec[0].template[0].spec[0].volume :
      volume.persistent_volume_claim[0].claim_name if volume.name == "uploads"
    ]) == "myapp-uploads"
    error_message = "The Job pod should carry the claim the process mounts"
  }

  assert {
    condition = one([
      for mount in kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].volume_mount :
      mount.mount_path if mount.name == "uploads"
    ]) == "/var/www/html/web/app/uploads"
    error_message = "The claim should be mounted at the path the process mounts it at"
  }

  # defaultMode comes back from the API as the decimal 420 and has to be
  # rendered as the octal string the provider takes, or 420 is read as octal.
  assert {
    condition = one([
      for volume in kubernetes_job_v1.run.spec[0].template[0].spec[0].volume :
      volume.secret[0].default_mode if volume.name == "tls"
    ]) == "0644"
    error_message = "An inherited secret volume should keep its defaultMode, converted to octal"
  }

  assert {
    condition = one([
      for mount in kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].volume_mount :
      mount.read_only if mount.name == "tls"
    ]) == true
    error_message = "An inherited read-only mount should stay read-only"
  }

  # A fresh per-run emptyDir is the ephemeral dyno filesystem, correctly
  # reproduced — but a tmpfs must stay a tmpfs.
  assert {
    condition = one([
      for volume in kubernetes_job_v1.run.spec[0].template[0].spec[0].volume :
      volume.empty_dir[0].medium if volume.name == "tmp"
    ]) == "Memory"
    error_message = "An inherited emptyDir should keep its medium"
  }

  # A pod volume the container does not mount carries no path to reproduce it
  # at, so it is not inherited.
  assert {
    condition = length([
      for volume in kubernetes_job_v1.run.spec[0].template[0].spec[0].volume :
      volume.name if volume.name == "unmounted"
    ]) == 0
    error_message = "A pod volume the process's container does not mount should not be inherited"
  }
}

# Test: the init container shares the mounts, the way it already shares the env
run "init_container_gets_the_same_mounts" {
  command = plan

  module {
    source = "./modules/run"
  }

  variables {
    init_command = ["/bin/bash", "-lc", "until pg_isready -t 5; do sleep 2; done"]
  }

  assert {
    condition = one([
      for mount in kubernetes_job_v1.run.spec[0].template[0].spec[0].init_container[0].volume_mount :
      mount.mount_path if mount.name == "uploads"
    ]) == "/var/www/html/web/app/uploads"
    error_message = "The init container should mount the inherited volumes too"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].init_container[0].volume_mount) == length(kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].volume_mount)
    error_message = "The init container should see the same mounts as the main container"
  }
}

# Test: `volumes` adds to what was inherited rather than replacing it
run "extra_volumes_are_additive" {
  command = plan

  module {
    source = "./modules/run"
  }

  variables {
    volumes = [{
      name       = "scratch"
      mount_path = "/scratch"
    }]
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].volume) == 4
    error_message = "An extra volume should be added to the three inherited ones"
  }

  assert {
    condition = length(one([
      for volume in kubernetes_job_v1.run.spec[0].template[0].spec[0].volume :
      volume.empty_dir if volume.name == "scratch"
    ])) == 1
    error_message = "A volume declaring no source should render an emptyDir"
  }

  assert {
    condition = one([
      for volume in kubernetes_job_v1.run.spec[0].template[0].spec[0].volume :
      volume.persistent_volume_claim[0].claim_name if volume.name == "uploads"
    ]) == "myapp-uploads"
    error_message = "The inherited volumes should survive an extra one"
  }
}

# Test: an entry of the same name replaces the inherited volume, so a run can
# swap a claim or a path without giving up the rest
run "extra_volumes_override_an_inherited_name" {
  command = plan

  module {
    source = "./modules/run"
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
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].volume) == 3
    error_message = "An entry of an inherited name should replace it, not duplicate it"
  }

  assert {
    condition = one([
      for volume in kubernetes_job_v1.run.spec[0].template[0].spec[0].volume :
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
    source = "./modules/run"
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
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].volume) == 1
    error_message = "inherit_volumes = false should leave only the declared volumes"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].volume[0].name == "backups"
    error_message = "The declared volume should still be mounted with inheritance off"
  }
}

# Test: a volume source the module cannot reproduce fails the plan instead of
# being dropped — a silently missing mount is the defect this inheritance
# exists to close
run "unsupported_volume_source_fails_the_plan" {
  command = plan

  module {
    source = "./modules/run"
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

  expect_failures = [kubernetes_job_v1.run]
}

# Test: two sources on one volume are rejected at plan time
run "validation_rejects_two_volume_sources" {
  command = plan

  module {
    source = "./modules/run"
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

# =============================================================================
# Pod labels
# =============================================================================

# Test: pod_labels reach the Job's pod template only — a mutating admission
# webhook sees the Pod at create time, so a label on the Job never reaches the
# object being admitted
run "pod_labels_reach_the_run_pod_only" {
  command = plan

  module {
    source = "./modules/run"
  }

  variables {
    pod_labels = {
      "admission.datadoghq.com/enabled" = "true"
      "tags.datadoghq.com/service"      = "myapp"
    }
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].metadata[0].labels["admission.datadoghq.com/enabled"] == "true"
    error_message = "pod_labels should land on the pod template"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].metadata[0].labels["tags.datadoghq.com/service"] == "myapp"
    error_message = "Every pod label should land on the pod template"
  }

  assert {
    condition     = !contains(keys(kubernetes_job_v1.run.metadata[0].labels), "admission.datadoghq.com/enabled")
    error_message = "pod_labels should not be copied onto the Job itself"
  }
}

# Test: pod_labels cannot put the Deployment's identity back on a run pod —
# that is what would make it a member of the web Service's endpoints and of the
# Deployment's PodDisruptionBudget
run "pod_labels_cannot_override_the_identity_labels" {
  command = plan

  module {
    source = "./modules/run"
  }

  variables {
    pod_labels = {
      "app.kubernetes.io/name"      = "myapp"
      "app.kubernetes.io/component" = "web"
    }
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].metadata[0].labels["app.kubernetes.io/name"] == "myapp-run"
    error_message = "The module's own name label must win over pod_labels"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].metadata[0].labels["app.kubernetes.io/component"] == "run"
    error_message = "The module's own component label must win over pod_labels"
  }
}

# Test: no extra pod labels by default
run "pod_labels_absent_by_default" {
  command = plan

  module {
    source = "./modules/run"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].metadata[0].labels) == 4
    error_message = "A run should carry only the module's four identity labels by default"
  }
}

# Test: a claim the pod declares read-only stays read-only in the run, even
# when the mount itself does not say so
run "pod_level_read_only_claim_is_honoured" {
  command = plan

  module {
    source = "./modules/run"
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
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].volume_mount[0].read_only == true
    error_message = "A claim the pod declares read-only should be mounted read-only"
  }
}

# Test: the pod template as the API actually returns it — optional fields
# present and set to null rather than absent. `try()` catches an error, not a
# null, so `try(x.readOnly, false)` yields null here and the null propagates;
# this is what broke a real apply. A key test for the source has the same
# shape of bug and would render the claim below as an emptyDir.
run "api_shaped_pod_template_with_null_optionals" {
  command = plan

  module {
    source = "./modules/run"
  }

  override_data {
    target = data.kubernetes_resource.deployment
    values = {
      object = {
        spec = {
          template = {
            spec = {
              volumes = [{
                name                  = "uploads"
                secret                = null
                configMap             = null
                emptyDir              = null
                hostPath              = null
                persistentVolumeClaim = { claimName = "myapp-uploads", readOnly = null }
              }]
              containers = [{
                name = "myapp"
                volumeMounts = [{
                  name             = "uploads"
                  mountPath        = "/var/www/html/web/app/uploads"
                  subPath          = null
                  readOnly         = null
                  mountPropagation = "None"
                }]
              }]
            }
          }
        }
      }
    }
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].volume[0].persistent_volume_claim[0].claim_name == "myapp-uploads"
    error_message = "A null-valued source key must not stop the real claim from being inherited"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].volume[0].empty_dir) == 0
    error_message = "A claim whose sibling source keys are null must not be rendered as an emptyDir"
  }

  assert {
    condition     = kubernetes_job_v1.run.spec[0].template[0].spec[0].container[0].volume_mount[0].read_only == false
    error_message = "A null readOnly should read as false, not propagate as null"
  }
}

# Test: an unsupported source still fails the plan when the supported keys are
# present-and-null alongside it — the case a `keys(volume)` test gets wrong
run "unsupported_source_detected_among_null_keys" {
  command = plan

  module {
    source = "./modules/run"
  }

  override_data {
    target = data.kubernetes_resource.deployment
    values = {
      object = {
        spec = {
          template = {
            spec = {
              volumes = [{
                name                  = "docker-socket"
                secret                = null
                configMap             = null
                emptyDir              = null
                persistentVolumeClaim = null
                hostPath              = { path = "/var/run/docker.sock" }
              }]
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

  expect_failures = [kubernetes_job_v1.run]
}
