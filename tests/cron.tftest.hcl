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
