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

# Test: the web probes get the permissive defaults, overridable per process
run "permissive_probe_defaults" {
  command = plan

  variables {
    formation = {
      web = {
        web                = true
        ports              = { http = 3000 }
        startup_probe_path = "/healthz"
        http_probe_path    = "/healthz"
      }
      slow = {
        web                           = false
        ports                         = { http = 4000 }
        startup_probe_path            = "/healthz"
        http_probe_path               = "/healthz"
        startup_probe_timeout_seconds = 10
        probe_timeout_seconds         = 5
      }
    }
  }

  assert {
    condition = (
      module.process["web"].deployment.spec[0].template[0].spec[0].container[0].startup_probe[0].timeout_seconds == 5 &&
      module.process["web"].deployment.spec[0].template[0].spec[0].container[0].startup_probe[0].failure_threshold == 30 &&
      module.process["web"].deployment.spec[0].template[0].spec[0].container[0].liveness_probe[0].timeout_seconds == 3
    )
    error_message = "Web process should inherit the permissive probe defaults (startup 5s/30, probe 3s)"
  }

  assert {
    condition = (
      module.process["slow"].deployment.spec[0].template[0].spec[0].container[0].startup_probe[0].timeout_seconds == 10 &&
      module.process["slow"].deployment.spec[0].template[0].spec[0].container[0].liveness_probe[0].timeout_seconds == 5
    )
    error_message = "Per-process overrides should win over the defaults"
  }
}

# Test: a non-web process can probe a named port other than "http" — the case
# of a process exposing an in-process metrics endpoint. Without probe_port its
# probes would target "http", a port name its container never declares, so it
# had to run with no probes at all.
run "probe_port_targets_a_non_http_named_port" {
  command = plan

  variables {
    formation = {
      web = {
        web                = true
        ports              = { http = 3000 }
        startup_probe_path = "/healthz"
        http_probe_path    = "/healthz"
      }
      exporter = {
        args            = ["bundle", "exec", "exporter"]
        ports           = { metrics = 9394 }
        probe_port      = "metrics"
        http_probe_path = "/metrics"
      }
    }
  }

  assert {
    condition = (
      module.process["exporter"].deployment.spec[0].template[0].spec[0].container[0].startup_probe[0].http_get[0].port == "metrics" &&
      module.process["exporter"].deployment.spec[0].template[0].spec[0].container[0].liveness_probe[0].http_get[0].port == "metrics" &&
      module.process["exporter"].deployment.spec[0].template[0].spec[0].container[0].readiness_probe[0].http_get[0].port == "metrics"
    )
    error_message = "All three probes of a non-web process should target its declared probe_port"
  }

  # http_probe_path alone drives liveness/readiness; the startup probe falls
  # back to it, so the process gets the full set on the same port.
  assert {
    condition = (
      module.process["exporter"].deployment.spec[0].template[0].spec[0].container[0].startup_probe[0].http_get[0].path == "/metrics" &&
      module.process["exporter"].deployment.spec[0].template[0].spec[0].container[0].liveness_probe[0].http_get[0].path == "/metrics"
    )
    error_message = "A non-web process setting only http_probe_path should get startup + liveness/readiness probes"
  }

  # The container must actually declare the port the probes name.
  assert {
    condition = (
      module.process["exporter"].deployment.spec[0].template[0].spec[0].container[0].port[0].name == "metrics" &&
      module.process["exporter"].deployment.spec[0].template[0].spec[0].container[0].port[0].container_port == 9394
    )
    error_message = "The exporter should declare the named containerPort its probes target"
  }

  # Regression guard on the null passthrough: `probe_port` is optional with no
  # default, and the downstream variable defaults to "http" without setting
  # `nullable = false` — a variable left at the default `nullable = true` takes
  # an explicit null *over* its default, so forwarding the unset attribute raw
  # would render a null port here rather than preserving today's behaviour.
  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].container[0].startup_probe[0].http_get[0].port == "http"
    error_message = "A process that does not set probe_port must still probe \"http\""
  }
}

# Test: probe_port naming a port the container never declares is rejected at
# plan time — otherwise it applies cleanly and the probe silently never resolves.
run "validation_rejects_probe_port_outside_ports" {
  command = plan

  variables {
    formation = {
      web = {
        web                = true
        ports              = { http = 3000 }
        startup_probe_path = "/healthz"
      }
      exporter = {
        ports           = { metrics = 9394 }
        probe_port      = "http"
        http_probe_path = "/metrics"
      }
    }
  }

  expect_failures = [var.formation]
}

# Test: the validation only fires on an explicitly set probe_port — processes
# that declare no ports at all (the common worker) stay valid.
run "validation_allows_portless_process_without_probe_port" {
  command = plan

  variables {
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

  assert {
    condition     = length(module.process["worker"].deployment.spec[0].template[0].spec[0].container[0].startup_probe) == 0
    error_message = "A process with no probe paths should render no probes"
  }
}

run "node_affinity_passthrough" {
  command = plan

  variables {
    formation = {
      web = {
        web   = true
        ports = { http = 3000 }
        node_affinity = {
          required = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot"] },
            { key = "eks.amazonaws.com/instance-category", operator = "NotIn", values = ["t"] },
          ]
          preferred = [
            { weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["arm64"] },
          ]
        }
      }
      worker = {
        web   = false
        ports = { metrics = 9394 }
      }
    }
  }

  assert {
    condition     = length(module.process["web"].deployment.spec[0].template[0].spec[0].affinity[0].node_affinity[0].required_during_scheduling_ignored_during_execution[0].node_selector_term[0].match_expressions) == 2
    error_message = "Web process should forward both required node-affinity match expressions"
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].affinity[0].node_affinity[0].preferred_during_scheduling_ignored_during_execution[0].weight == 100
    error_message = "Web process should forward the preferred node-affinity weight"
  }

  assert {
    condition     = length(module.process["worker"].deployment.spec[0].template[0].spec[0].affinity[0].node_affinity) == 0
    error_message = "A process without node_affinity should not get node affinity"
  }
}

run "node_selector_and_pod_affinity_passthrough" {
  command = plan

  variables {
    formation = {
      web = {
        web           = true
        ports         = { http = 3000 }
        node_selector = { "disktype" = "ssd" }
        tolerations   = [{ key = "example.com/dedicated", operator = "Exists", effect = "NoSchedule" }]
        pod_affinity = {
          required = [
            { topology_key = "kubernetes.io/hostname", match_labels = { app = "cache" } },
          ]
        }
      }
    }
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].node_selector["disktype"] == "ssd"
    error_message = "Web process should forward the node selector"
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].toleration[0].key == "example.com/dedicated"
    error_message = "Web process should forward the toleration to the tainted pool"
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].affinity[0].pod_affinity[0].required_during_scheduling_ignored_during_execution[0].topology_key == "kubernetes.io/hostname"
    error_message = "Web process should forward the pod affinity"
  }
}

run "anti_affinity_and_pdb_passthrough" {
  command = plan

  variables {
    formation = {
      # No anti_affinity set: inherits the "soft" default (spread replicas
      # best-effort), matching fabn/workload/kubernetes.
      web = {
        web   = true
        ports = { http = 3000 }
      }
      # Hard anti-affinity + a PodDisruptionBudget guarding the worker.
      worker = {
        web           = false
        replicas      = 3
        anti_affinity = "hard"
        pdb_enabled   = true
        pdb_config    = { max_unavailable = "1" }
      }
    }
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].affinity[0].pod_anti_affinity[0].preferred_during_scheduling_ignored_during_execution[0].weight == 1
    error_message = "The default (soft) anti-affinity should emit a preferred pod anti-affinity term"
  }

  assert {
    condition     = module.process["worker"].deployment.spec[0].template[0].spec[0].affinity[0].pod_anti_affinity[0].required_during_scheduling_ignored_during_execution[0].topology_key == "kubernetes.io/hostname"
    error_message = "anti_affinity = \"hard\" should emit a required pod anti-affinity term"
  }
}

run "raw_pod_anti_affinity_and_topology_spread_passthrough" {
  command = plan

  variables {
    formation = {
      web = {
        web   = true
        ports = { http = 3000 }
        # Raw spread rule on a custom topology key, additive to the default
        # "soft" host-level anti-affinity.
        pod_anti_affinity = {
          required = [
            { topology_key = "topology.kubernetes.io/zone", match_labels = { app = "web" } },
          ]
        }
        topology_spread_constraints = [
          {
            max_skew           = 1
            topology_key       = "topology.kubernetes.io/zone"
            when_unsatisfiable = "DoNotSchedule"
          },
        ]
      }
    }
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].affinity[0].pod_anti_affinity[0].required_during_scheduling_ignored_during_execution[0].topology_key == "topology.kubernetes.io/zone"
    error_message = "Raw pod_anti_affinity required term should be forwarded verbatim"
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].affinity[0].pod_anti_affinity[0].preferred_during_scheduling_ignored_during_execution[0].weight == 1
    error_message = "Raw pod_anti_affinity should coexist with the soft anti_affinity shorthand"
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].topology_spread_constraint[0].max_skew == 1
    error_message = "topology_spread_constraints should be forwarded"
  }

  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].topology_spread_constraint[0].when_unsatisfiable == "DoNotSchedule"
    error_message = "topology_spread_constraints when_unsatisfiable should be forwarded"
  }
}

# The shutdown budget is per process: a queue worker needs room for its own
# drain timeout, while a stateless web pod does not and keeps the default.
run "termination_grace_period_passthrough" {
  command = plan

  variables {
    formation = {
      web = {
        web   = true
        ports = { http = 3000 }
      }
      worker = {
        args                             = ["bundle", "exec", "sidekiq", "-t", "90"]
        termination_grace_period_seconds = 100
      }
    }
  }

  assert {
    condition     = module.process["worker"].deployment.spec[0].template[0].spec[0].termination_grace_period_seconds == 100
    error_message = "Worker should forward its termination grace period"
  }

  # Omitted rather than pinned to 30: leaving the field unset is what lets
  # Kubernetes apply its own default, and keeps the manifest free of a value
  # nobody chose.
  assert {
    condition     = module.process["web"].deployment.spec[0].template[0].spec[0].termination_grace_period_seconds == null
    error_message = "A process that sets no grace period should not render the field at all"
  }
}

# Test: extra pod labels reach every process, and stay off by default
run "pod_labels" {
  command = plan

  variables {
    labels = { Customer = "acme", "example.com/tier" = "gold" }
  }

  # Every process, not just the web one: attribution that skips the workers
  # under-reports whatever it is measuring.
  assert {
    condition = alltrue([
      for p in ["web", "worker"] :
      module.process[p].deployment.spec[0].template[0].metadata[0].labels["Customer"] == "acme"
    ])
    error_message = "Extra labels should land on the pod template of every process"
  }

  # The pod template is the part that matters for anything reading pod
  # metadata, but the workload module applies them to its other objects too.
  assert {
    condition     = module.process["web"].deployment.metadata[0].labels["example.com/tier"] == "gold"
    error_message = "Extra labels should also land on the Deployment itself"
  }

  # The module's own labels must survive the merge — losing part-of or
  # managed-by would break selectors and ownership queries.
  assert {
    condition = (
      module.process["web"].deployment.spec[0].template[0].metadata[0].labels["app.kubernetes.io/name"] == "myapp" &&
      module.process["web"].deployment.spec[0].template[0].metadata[0].labels["app.kubernetes.io/managed-by"] == "terraform"
    )
    error_message = "Extra labels should merge with the standard labels, not replace them"
  }
}

# Test: no extra labels leaves the rendered manifest untouched
run "pod_labels_absent_by_default" {
  command = plan

  assert {
    condition     = !contains(keys(module.process["web"].deployment.spec[0].template[0].metadata[0].labels), "Customer")
    error_message = "An unset `labels` should add nothing to the pod template"
  }
}

# Test: volumes reach the pod template, and only the process that declares them
run "volumes_passthrough" {
  command = plan

  variables {
    formation = {
      web = {
        web   = true
        ports = { http = 3000 }
        volumes = [{
          name                    = "uploads"
          mount_path              = "/var/www/html/web/app/uploads"
          persistent_volume_claim = "myapp-uploads"
        }]
      }
      worker = {
        args = ["bundle", "exec", "sidekiq"]
      }
    }
  }

  assert {
    condition     = one(module.process["web"].deployment.spec[0].template[0].spec[0].volume).persistent_volume_claim[0].claim_name == "myapp-uploads"
    error_message = "The declared claim should be mounted as a pod volume"
  }

  assert {
    condition     = one([for mount in module.process["web"].deployment.spec[0].template[0].spec[0].container[0].volume_mount : mount.mount_path if mount.name == "uploads"]) == "/var/www/html/web/app/uploads"
    error_message = "The volume should be mounted into the container at the declared path"
  }

  # Per process, not per formation: a worker declaring none mounts none.
  assert {
    condition     = length(module.process["worker"].deployment.spec[0].template[0].spec[0].volume) == 0
    error_message = "A process declaring no volumes should get none"
  }
}
