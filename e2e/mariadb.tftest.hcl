# =============================================================================
# E2E: mariadb addon against a real Kind cluster + mariadb-operator
# =============================================================================
# Installs the operator, deploys the addon for real (standalone, so it fits the
# single-node Kind cluster) and waits for it Ready, then runs `SELECT 1` through
# a Job — proving the addon's host, user and generated password work end to end.
# A second, non-blocking apply exercises the HA + backup + inheritMetadata CR
# schema against the live CRD (the field names the mocked unit tests can't
# validate); the backup Job itself needs real S3 and is validated in the infra
# repo, not here (same as postgres-cnpg).

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
    source = "./modules/mariadb-operator"
  }
}

run "namespace" {
  module {
    source = "./modules/namespace"
  }

  variables {
    name = "mariadb-e2e"
  }
}

run "mariadb" {
  module {
    source = "../modules/mariadb"
  }

  variables {
    namespace            = run.namespace.name
    name                 = "e2e-mariadb"
    database             = "myapp"
    username             = "myapp"
    replicas             = 1
    storage_size         = "1Gi"
    service_account_name = "e2e-mariadb"
    wait_for_ready       = true
  }

  assert {
    condition     = output.host == "e2e-mariadb"
    error_message = "standalone host should be the plain <name> Service"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.DATABASE_URL), "@e2e-mariadb:3306/myapp")
    error_message = "DATABASE_URL should target the deployed host / database"
  }
}

# Real connectivity: SELECT 1 as the app user through the Service. Apply success
# (the Job completes) proves the host, user and password from the addon work.
run "connectivity" {
  module {
    source = "./modules/mariadb-ping"
  }

  variables {
    namespace       = run.namespace.name
    host            = "e2e-mariadb"
    username        = "myapp"
    database        = "myapp"
    password_secret = "e2e-mariadb-app"
  }
}

# Schema coverage for the HA, backup and inheritMetadata paths — the ones the
# mocked unit tests can't validate against the real CRD. wait_for_ready is off:
# a successful apply already proves the operator accepted every field (a wrong
# name like automaticFailover / podTemplate.serviceAccountName / inheritedMetadata
# is rejected by strict decoding), without waiting for a full HA bootstrap on the
# single-node cluster. The backup Job it schedules fails without real S3 — that's
# fine, we only assert the CRs are valid.
run "mariadb_ha_schema" {
  module {
    source = "../modules/mariadb"
  }

  variables {
    namespace            = run.namespace.name
    name                 = "e2e-ha"
    database             = "myapp"
    username             = "myapp"
    part_of              = "myapp"
    replicas             = 2
    storage_size         = "1Gi"
    service_account_name = "e2e-ha"
    backup               = { bucket = "e2e-schema-check", region = "eu-south-1" }
    wait_for_ready       = false
  }

  assert {
    condition     = output.host == "e2e-ha-primary"
    error_message = "HA host should be the <name>-primary Service"
  }
}
