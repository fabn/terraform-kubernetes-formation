# =============================================================================
# Dragonfly addon contract tests
# =============================================================================
# Same env / sensitive_env contract as the Bitnami redis addon (REDIS_URL), so
# callers swap `source` with no change.

mock_provider "kubernetes" {}
mock_provider "random" {}

# Auth on (default): REDIS_URL carries the password and lives in sensitive_env.
run "dragonfly_auth_contract" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
  }

  assert {
    condition     = startswith(nonsensitive(output.sensitive_env.REDIS_URL), "redis://:")
    error_message = "REDIS_URL should embed the password after redis://:"
  }

  assert {
    condition     = endswith(nonsensitive(output.sensitive_env.REDIS_URL), "@dragonfly:6379")
    error_message = "REDIS_URL should target the <name> Service on 6379"
  }

  assert {
    condition     = length(output.env) == 0
    error_message = "with auth on, nothing is plaintext"
  }

  assert {
    condition     = output.host == "dragonfly"
    error_message = "host should be the Dragonfly Service name"
  }

  assert {
    condition     = contains(kubernetes_manifest.dragonfly.manifest.spec.args, "--proactor_threads=1")
    error_message = "threads should pin --proactor_threads"
  }
}

# Auth off: REDIS_URL is plaintext in env, sensitive_env empty.
run "dragonfly_no_auth" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    name      = "cache"
    auth      = false
  }

  assert {
    condition     = output.env.REDIS_URL == "redis://cache:6379"
    error_message = "no-auth REDIS_URL should be plaintext host:port"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "no-auth: sensitive_env empty"
  }
}

# S3 snapshot: dir set to the S3 URI, no PVC.
run "dragonfly_snapshot_s3" {
  command = apply

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace            = "addon-test"
    service_account_name = "dragonfly"
    snapshot             = { s3_uri = "s3://backups/cache" }
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.snapshot.dir == "s3://backups/cache"
    error_message = "s3_uri should drive snapshot.dir"
  }

  assert {
    condition     = kubernetes_manifest.dragonfly.manifest.spec.serviceAccountName == "dragonfly"
    error_message = "the instance SA (for Pod Identity) should be set"
  }

  assert {
    condition     = !can(kubernetes_manifest.dragonfly.manifest.spec.snapshot.persistentVolumeClaimSpec)
    error_message = "S3 snapshot should not create a PVC spec"
  }
}

# snapshot rejects setting both s3 and pvc.
run "dragonfly_snapshot_rejects_both" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace = "addon-test"
    snapshot  = { s3_uri = "s3://b/p", pvc_size = "5Gi" }
  }

  expect_failures = [var.snapshot]
}

# memory must cover the thread count (256Mi per thread).
run "dragonfly_rejects_undersized_memory" {
  command = plan

  module {
    source = "./modules/dragonfly"
  }

  variables {
    namespace  = "addon-test"
    threads    = 4
    memory_mib = 512
  }

  expect_failures = [var.memory_mib]
}
