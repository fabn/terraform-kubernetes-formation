# =============================================================================
# Formation Tests
# =============================================================================

mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  name        = "myapp"
  namespace   = "myapp-test"
  environment = "test"
  image       = "ghcr.io/acme/myapp:1.0.0"
  domain      = "myapp.example.com"

  registry_username = "ci"
  registry_password = "token"

  formation = {
    web = {
      web                = true
      ports              = { http = 3000 }
      startup_probe_path = "/healthz"
    }
    worker = {
      args = ["bundle", "exec", "sidekiq"]
    }
  }
}

# Test: Heroku-like process naming (web keeps the bare app name)
run "process_naming" {
  command = plan

  assert {
    condition     = output.web_deployment_name == "myapp"
    error_message = "Web process should keep the bare app name"
  }

  assert {
    condition     = output.deployment_names.web == "myapp" && output.deployment_names.worker == "myapp-worker" && length(output.deployment_names) == 2
    error_message = "Non-web processes should be named <name>-<process>"
  }

  assert {
    condition     = output.image == "ghcr.io/acme/myapp:1.0.0"
    error_message = "Image output should echo var.image"
  }
}

# Test: namespace created and labelled by default
run "namespace_created" {
  command = plan

  assert {
    condition     = kubernetes_namespace_v1.ns[0].metadata[0].name == "myapp-test"
    error_message = "Namespace should be created with var.namespace"
  }

  assert {
    condition     = kubernetes_namespace_v1.ns[0].metadata[0].labels["myapp/environment"] == "test"
    error_message = "Namespace should carry the <name>/environment label"
  }

  assert {
    condition     = kubernetes_namespace_v1.ns[0].metadata[0].labels["app.kubernetes.io/part-of"] == "myapp"
    error_message = "Namespace should carry the part-of label"
  }

  assert {
    condition     = output.namespace == "myapp-test"
    error_message = "Namespace output should match var.namespace"
  }
}

# Test: caller-owned namespace (composition roots)
run "namespace_not_created" {
  command = plan

  variables {
    create_namespace = false
  }

  assert {
    condition     = length(kubernetes_namespace_v1.ns) == 0
    error_message = "No namespace resource should be created when create_namespace = false"
  }

  assert {
    condition     = output.namespace == "myapp-test"
    error_message = "Namespace output should still be var.namespace"
  }
}

# Test: SECRET_KEY_BASE generated + content-hash named Secret/ConfigMap
run "shared_env_objects" {
  command = apply

  assert {
    condition     = random_id.secret_key_base.byte_length == 64
    error_message = "Generated SECRET_KEY_BASE should be 64 random bytes"
  }

  assert {
    condition     = startswith(output.secret_name, "myapp-secrets-")
    error_message = "Shared Secret should be name-prefixed and content-hash suffixed"
  }

  assert {
    condition     = startswith(output.config_map_name, "myapp-config-")
    error_message = "Shared ConfigMap should be name-prefixed and content-hash suffixed"
  }
}

# Test: worker-only stacks are valid (no web process, no domain)
run "worker_only_formation" {
  command = plan

  variables {
    domain = null
    formation = {
      worker = { args = ["bundle", "exec", "sidekiq"] }
    }
  }

  assert {
    condition     = output.web_deployment_name == null
    error_message = "web_deployment_name should be null without a web process"
  }

  assert {
    condition     = output.deployment_names.worker == "myapp-worker" && length(output.deployment_names) == 1
    error_message = "Worker-only formation should deploy just the worker"
  }
}

# Test: autoscaled processes hand the replica count to an external autoscaler
run "autoscaled_process_null_replicas" {
  command = plan

  variables {
    formation = {
      web = {
        web                = true
        ports              = { http = 3000 }
        startup_probe_path = "/healthz"
      }
      worker = {
        args       = ["bundle", "exec", "sidekiq"]
        autoscaled = true
        # Ignored: the autoscaler owns the count.
        replicas = 3
      }
    }
  }

  # The worker was applied earlier in this file with a managed count of 1.
  # With autoscaled = true the config sends a null count, and the provider
  # keeps the live value for the computed field — the ignored `replicas = 3`
  # must never reach the manifest, and the existing count must survive the
  # plan untouched (the no-drift contract with an external autoscaler).
  assert {
    condition     = module.process["worker"].deployment.spec[0].replicas == "1"
    error_message = "Autoscaled processes must leave the live replica count untouched (config sends null, ignoring `replicas`)"
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].replicas == "1"
    error_message = "Non-autoscaled processes should keep the managed replica count"
  }
}

# Test: ALB mode — annotations on the web ingress, in-cluster TLS/ACME suppressed
run "alb_ingress" {
  command = plan

  variables {
    ingress_class_name = null
    alb = {
      load_balancer_name = "shared-external"
    }
  }

  assert {
    condition     = module.process["web"].ingress.metadata[0].annotations["alb.ingress.kubernetes.io/load-balancer-name"] == "shared-external"
    error_message = "Web ingress should carry the ALB load-balancer-name annotation"
  }

  assert {
    condition     = module.process["web"].ingress.metadata[0].annotations["alb.ingress.kubernetes.io/listen-ports"] == jsonencode([{ HTTPS = 443 }])
    error_message = "Web ingress should default to the HTTPS 443 listener"
  }

  assert {
    condition     = !contains(keys(module.process["web"].ingress.metadata[0].annotations), "kubernetes.io/tls-acme")
    error_message = "ALB mode should suppress the ACME annotation (TLS terminates on the ALB)"
  }

  assert {
    condition     = length(module.process["web"].ingress.spec[0].tls) == 0
    error_message = "ALB mode should suppress the in-cluster TLS block"
  }
}

# Test: a web process requires a domain
run "validation_web_requires_domain" {
  command = plan

  variables {
    domain = null
  }

  expect_failures = [var.domain]
}

# Test: formation validation — a single web process
run "validation_rejects_multiple_web" {
  command = plan

  variables {
    formation = {
      web  = { web = true, ports = { http = 3000 } }
      web2 = { web = true, ports = { http = 3001 } }
    }
  }

  expect_failures = [var.formation]
}
