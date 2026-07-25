# =============================================================================
# E2E: dragonfly addon against a real Kind cluster + Dragonfly operator
# =============================================================================
# Installs the operator, deploys the addon for real (master + replica) and waits
# for it Ready, then AUTHs + PINGs the Service through a Job — proving the
# REDIS_URL host and password work end to end.

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-kind"
}

provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = "kind-kind"
  }
}

run "operator" {
  module {
    source = "./modules/dragonfly-operator"
  }
}

run "namespace" {
  module {
    source = "./modules/namespace"
  }

  variables {
    name = "dragonfly-e2e"
  }
}

run "dragonfly" {
  module {
    source = "../modules/dragonfly"
  }

  variables {
    namespace      = run.namespace.name
    name           = "e2e-dragonfly"
    wait_for_ready = true

    # Placement knobs are exercised here because the mocked unit tests can't:
    # kubernetes_manifest sends the manifest as-is, so a field the CRD doesn't
    # define is only rejected by a real API server. Both terms are satisfiable on
    # a single-node Kind cluster (soft arch preference, os=linux requirement), so
    # they prove acceptance without making the instance unschedulable.
    node_affinity = {
      required  = [{ key = "kubernetes.io/os", operator = "In", values = ["linux"] }]
      preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["amd64", "arm64"] }]
    }
    topology_spread_constraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway" # single node: DoNotSchedule would pin the replica Pending
    }]
    # Customises the PDB the operator creates on its own for a 2-replica instance.
    pod_disruption_budget = { min_available = "1" }
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.REDIS_URL), "@e2e-dragonfly:6379")
    error_message = "REDIS_URL should target the instance Service"
  }

  assert {
    condition     = output.host == "e2e-dragonfly"
    error_message = "host should be the Dragonfly Service name"
  }

  # Read back from the API server: the CRD accepted the placement fields and
  # stored them as sent.
  assert {
    condition     = kubernetes_manifest.dragonfly.object.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key == "kubernetes.io/os"
    error_message = "the stored CR should carry the required node affinity term"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.object.spec.topologySpreadConstraints[0].topologyKey == "kubernetes.io/hostname"
    error_message = "the stored CR should carry the topology spread constraint"
  }

  assert {
    condition     = tostring(kubernetes_manifest.dragonfly.object.spec.pdb.minAvailable) == "1"
    error_message = "the stored CR should carry the PDB override"
  }
}

# Real connectivity: AUTH + PING through the Service. Apply success (the Job
# completes) proves the host and password from the addon actually work.
run "connectivity" {
  module {
    source = "./modules/dragonfly-ping"
  }

  variables {
    namespace   = run.namespace.name
    name        = "e2e-dragonfly"
    auth_secret = "e2e-dragonfly-auth"
  }
}

# Idempotency guard for the placement fields, same mechanism as the postgres-cnpg
# one (#32): re-plan the *same* instance against live state with identical inputs.
# If the operator or the API server normalises anything we sent (a nodeAffinity
# term, the PDB override), the re-plan queues an update and marks the computed
# `object` "known after apply", so the assertion below can't evaluate and the run
# fails. A clean plan keeps `object` known → this passes only when the addon is
# idempotent with the placement surface configured.
run "dragonfly_idempotent" {
  command = plan

  module {
    source = "../modules/dragonfly"
  }

  variables {
    namespace      = run.namespace.name
    name           = "e2e-dragonfly"
    wait_for_ready = true

    node_affinity = {
      required  = [{ key = "kubernetes.io/os", operator = "In", values = ["linux"] }]
      preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["amd64", "arm64"] }]
    }
    topology_spread_constraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "ScheduleAnyway"
    }]
    pod_disruption_budget = { min_available = "1" }
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.object.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key == "kubernetes.io/os"
    error_message = "dragonfly is not idempotent with placement configured: a re-plan still changes the stored CR"
  }
}
