# =============================================================================
# Run Submodule Tests
# =============================================================================
# One-off Jobs inherit their runtime environment (envFrom, imagePullSecrets,
# serviceAccountName) from a live Deployment; the Deployment read is stubbed
# with override_data.

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
    condition     = kubernetes_job_v1.run.metadata[0].labels["app.kubernetes.io/name"] == "myapp" && kubernetes_job_v1.run.metadata[0].labels["app.kubernetes.io/component"] == "run"
    error_message = "Job labels should carry the deployment name and the component"
  }

  assert {
    condition     = length(kubernetes_job_v1.run.spec[0].template[0].spec[0].init_container) == 0
    error_message = "No init container should exist without init_command"
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
    condition     = kubernetes_job_v1.run.metadata[0].labels["app.kubernetes.io/component"] == "release"
    error_message = "The name variable should drive the component label"
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
