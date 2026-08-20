# =============================================================================
# Cron Submodule Tests
# =============================================================================
# Scheduled tasks inherit their runtime environment (envFrom, imagePullSecrets,
# serviceAccountName) from a live Deployment, like the run submodule; the
# Deployment read is stubbed with override_data.

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
            containers = [{
              name = "myapp"
              envFrom = [
                { secretRef = { name = "myapp-secrets-abc123" } },
                { configMapRef = { name = "myapp-config-def456" } },
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
