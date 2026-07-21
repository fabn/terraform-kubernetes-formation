# Terraform Kubernetes Formation Module

Heroku-style application stack on Kubernetes: a `formation` map of processes
(one [fabn/workload/kubernetes](https://registry.terraform.io/modules/fabn/workload/kubernetes)
instance each — the `web` process gets Service + Ingress + probes, the others
run headless), a shared Secret/ConfigMap, a generated `SECRET_KEY_BASE`
(override via `secret_env`) and a registry pull secret.

Published on the Terraform Registry as
[`fabn/formation/kubernetes`](https://registry.terraform.io/modules/fabn/formation/kubernetes),
next to [`fabn/workload/kubernetes`](https://registry.terraform.io/modules/fabn/workload/kubernetes),
the building block it composes.

## Features

- **Formation**: Heroku-Procfile-like map of processes; each entry becomes one
  `fabn/workload/kubernetes` instance sharing the same image
- **Web process**: at most one entry sets `web = true` (enforced by
  validation) and gets the Service, the Ingress and the HTTP probes; every
  other process runs headless and is restarted by the kubelet on process
  exit. Worker-only stacks (queue consumers, schedulers) simply omit the web
  entry
- **Shared env**: one ConfigMap (`env`) + one Secret (`secret_env`) sourced by
  every process, content-hash named so changes roll the deployments
- **Generated `SECRET_KEY_BASE`**: nothing sensitive needs to live in plaintext
  for ephemeral environments; override via `secret_env`
- **Registry pull secret**: a `dockerconfigjson` Secret wired into every process
- **Datadog**: optional UST tags + log annotations on every process
- **Addons**: independent backing-service submodules (`postgres`, `redis`,
  `memcached`) with a uniform contract — outputs `env` (plaintext config) and
  `sensitive_env` (credentials) the caller merges into the stack, Heroku-addon
  style — or the `addons` wrapper that sizes them behind one Heroku-like map
  (the in-cluster twin of the managed [`fabn/addons/aws`](https://registry.terraform.io/modules/fabn/addons/aws))
- **One-off Jobs**: the `run` submodule is the `heroku run` / release-phase
  equivalent — a Job that inherits the runtime environment of a deployed
  process (envFrom, pull secrets, service account) to run a one-shot command
  (migrations, seeds, arbitrary tasks)

## Usage

```hcl
module "app" {
  source  = "fabn/formation/kubernetes"
  version = "~> 0.1"

  name        = "myapp"
  namespace   = "myapp-staging"
  environment = "staging"
  image       = "ghcr.io/acme/myapp:1.2.3"
  domain      = "myapp-staging.example.com"

  registry_username = var.github_username
  registry_password = var.image_pull_token

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

  env        = merge(module.postgres.env, module.redis.env, { RAILS_ENV = "production" })
  secret_env = module.postgres.sensitive_env
}
```

The module is framework-neutral by design (nothing injects `RAILS_ENV` — pass
it via `env`), though its defaults are shaped around Rails + Sidekiq.

### With addons

Addons live in independent submodules and are merged into the stack through
`env`/`secret_env`. Because the formation's inputs depend on the addon
outputs, the caller owns the namespace (`create_namespace = false`):

```hcl
resource "kubernetes_namespace_v1" "app" {
  metadata { name = "myapp-review-pr-42" }
}

module "postgres" {
  source  = "fabn/formation/kubernetes//modules/postgres"
  version = "~> 0.1"

  namespace = kubernetes_namespace_v1.app.metadata[0].name
  name      = "myapp-pg"
  database  = "myapp"
  username  = "myapp"
}

module "redis" {
  source  = "fabn/formation/kubernetes//modules/redis"
  version = "~> 0.1"

  namespace           = kubernetes_namespace_v1.app.metadata[0].name
  name                = "myapp-redis"
  persistence_enabled = false
}

module "memcached" {
  source  = "fabn/formation/kubernetes//modules/memcached"
  version = "~> 0.1"

  namespace = kubernetes_namespace_v1.app.metadata[0].name
}

module "app" {
  source  = "fabn/formation/kubernetes"
  version = "~> 0.1"

  # ...
  create_namespace = false
  namespace        = kubernetes_namespace_v1.app.metadata[0].name

  env = merge(
    module.postgres.env,
    module.redis.env,
    module.memcached.env,
    { RAILS_ENV = "production" },
  )
  secret_env = module.postgres.sensitive_env
}
```

New backing services are new addon modules, never new toggles in the core;
managed cloud addons (Aurora, ElastiCache, …) live in the companion
[`fabn/addons/aws`](https://registry.terraform.io/modules/fabn/addons/aws),
which exposes the same `env` / `sensitive_env` contract so a stack swaps
in-cluster for managed without touching the app.

### Addons behind one map (`modules/addons`)

The `addons` submodule wraps the backing-service submodules behind a single
Heroku-like map — one entry per service, sized with a preset plan — and
re-exports the merged `env` / `sensitive_env`. It is the in-cluster twin of
`fabn/addons/aws`: the same map shape and the same env contract, so a stack
picks its backend by pointing at one module or the other (network inputs
aside).

```hcl
module "addons" {
  source  = "fabn/formation/kubernetes//modules/addons"
  version = "~> 0.2"

  namespace = kubernetes_namespace_v1.app.metadata[0].name
  name      = "myapp-staging"

  addons = {
    postgres  = { size = "small" } # database/user default to the stack name
    redis     = { size = "mini" }
    memcached = { size = "mini" }
  }
}

module "app" {
  source  = "fabn/formation/kubernetes"
  version = "~> 0.2"

  # ...
  create_namespace = false
  namespace        = kubernetes_namespace_v1.app.metadata[0].name

  env        = merge(module.addons.env, { RAILS_ENV = "production" })
  secret_env = module.addons.sensitive_env
}
```

`size` picks a preset (`mini` | `small` | `medium` | `large`, default `mini`);
any explicit knob (`storage_size`, `max_memory`, `cpu_requests`, …) overrides
the preset for that field. For knobs the wrapper does not surface, use the
individual submodules directly (they stay usable on their own).

### Behind an AWS ALB (EKS Auto Mode / AWS Load Balancer Controller)

Set `alb` to configure the web Ingress for ALB termination — TLS ends on the
load balancer (ACM certificate), so the in-cluster TLS block and the ACME
annotation are suppressed:

```hcl
module "app" {
  source = "fabn/formation/kubernetes"

  # ...
  domain             = "myapp.example.com" # must be covered by the ALB's ACM cert
  ingress_class_name = null                # the ALB class is usually the cluster default
  alb = {
    load_balancer_name = "shared-external" # same value on every Ingress of a group ALB
  }
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.9 |
| kubernetes | ~> 3.0 |
| random | ~> 3.6 |
| helm (addons only) | ~> 3.0 |

## Inputs

### Required

| Name | Description | Type |
|------|-------------|------|
| `name` | Application name; drives workload names (`<name>` for web, `<name>-<process>` otherwise) | `string` |
| `namespace` | Kubernetes namespace to deploy into | `string` |
| `environment` | Logical environment name (staging, production, review-pr-123, …) | `string` |
| `image` | Full image reference (registry/repo:tag) shared by every process | `string` |
| `formation` | Map of process name => process spec (see below) | `map(object)` |
| `registry_username` | Username for the registry imagePullSecret | `string` |
| `registry_password` | Password/token for the registry imagePullSecret | `string` |

### Formation entries

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `web` | Marks the (at most one) HTTP process behind the ingress | `bool` | `false` |
| `command` | Container command override | `list(string)` | `null` |
| `args` | Container args | `list(string)` | `null` |
| `replicas` | Replica count (ignored when `autoscaled`) | `number` | `1` |
| `autoscaled` | Hands the replica count to an external autoscaler (HPA, KEDA): deploys with `replicas = null` so Terraform never manages or reverts the live count | `bool` | `false` |
| `ports` | Container ports (name => port) | `map(number)` | `{}` |
| `startup_probe_path` | HTTP startup probe path | `string` | `null` |
| `http_probe_path` | HTTP liveness/readiness probe path | `string` | `null` |
| `startup_probe_timeout_seconds` | startupProbe timeoutSeconds — more permissive than k8s (1) for cold Rails boots | `number` | `5` |
| `startup_probe_failure_threshold` | startupProbe failureThreshold — long startup budget for slow starts | `number` | `30` |
| `probe_timeout_seconds` | liveness/readiness timeoutSeconds — tolerates transient spikes | `number` | `3` |
| `probe_failure_threshold` | liveness/readiness failureThreshold (null = k8s default 3) | `number` | `null` |
| `cpu_requests` | CPU request | `string` | `"50m"` |
| `memory_requests` | Memory request | `string` | `"128Mi"` |
| `memory_limits` | Memory limit | `string` | `"512Mi"` |
| `datadog_source` | Datadog log source (defaults to `rails` for web, process name otherwise) | `string` | `null` |
| `datadog_checks` | Datadog autodiscovery checks | `any` | `{}` |

### Optional

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `domain` | Public hostname served by the web process ingress (required when the formation has a web process) | `string` | `null` |
| `create_namespace` | Create the namespace (`false` for composition roots) | `bool` | `true` |
| `env` | Plaintext env vars for every process (ConfigMap) | `map(string)` | `{}` |
| `secret_env` | Sensitive env vars for every process (Secret) | `map(string)` | `{}` |
| `registry_server` | Container registry host | `string` | `"ghcr.io"` |
| `ingress_class_name` | IngressClass for the web ingress (set to `null` to use the cluster default class) | `string` | `"nginx"` |
| `ingress_annotations` | Extra annotations on the web ingress | `map(string)` | `{}` |
| `alb` | ALB termination for the web ingress: `{ load_balancer_name, healthcheck_path, listen_ports }` (see above) | `object` | `null` |
| `namespace_labels` | Extra labels merged onto the namespace | `map(string)` | `{}` |
| `datadog_enabled` | Datadog UST tags + log annotations on every process | `bool` | `false` |
| `datadog_service` | Datadog service tag (defaults to `name`) | `string` | `null` |
| `datadog_env` | Datadog env tag (defaults to `environment`) | `string` | `null` |
| `datadog_team` | Datadog team tag | `string` | `null` |

## Outputs

| Name | Description |
|------|-------------|
| `namespace` | Namespace the stack is deployed into |
| `image` | Image reference in use |
| `web_deployment_name` | Name of the web process Deployment (equals `name`); `null` without a web process |
| `deployment_names` | Map of formation key => Deployment name |
| `secret_name` | Name of the shared env Secret (content-hash suffixed) |
| `config_map_name` | Name of the shared env ConfigMap (content-hash suffixed) |

## Addon submodules

Uniform contract: inputs `namespace`/`name` (+ service specifics), outputs
`env` (plaintext) and `sensitive_env` (credentials). Compose them behind one
map with the [`addons` wrapper](#addons-behind-one-map-modulesaddons), or use
them individually.

### postgres

Bitnami PostgreSQL chart, standalone architecture. The password is generated
per instance and stays in TF state + the auth Secret.

- `env`: `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` (lets `psql` inside the
  pod connect with no args)
- `sensitive_env`: `DATABASE_URL`, `PGPASSWORD`

### redis

Bitnami Redis chart, standalone, no auth (in-cluster only). AOF persistence +
`noeviction` so queues and flags never silently disappear under memory
pressure.

- `env`: `REDIS_URL`
- `sensitive_env`: empty

### memcached

Plain memcached on `fabn/workload/kubernetes`, deliberately ephemeral (no PVC).

- `env`: `MEMCACHED_SERVERS` (a comma-separated `host:port` server list — no
  URI scheme, the format memcached clients consume — matching the
  `fabn/addons/aws` memcached addon)
- `sensitive_env`: empty

## One-off Jobs: the `run` submodule

The `heroku run` / release-phase equivalent: a `kubernetes_job_v1` that runs a
one-shot command (DB migrations, seed loading, arbitrary tasks) in the same
environment as a deployed process. Instead of re-declaring that environment,
the Job reads the live Deployment's pod template and inherits its `envFrom`
(which is how it picks up the content-hash-suffixed Secret/ConfigMap names —
addon connection vars included), `imagePullSecrets` and `serviceAccountName`.

Two things stay deliberately explicit:

- **`image`** — pin the run to the artifact being released, never to whatever
  stale tag the Deployment currently points at.
- **`command`** — what to run.

The Job defaults to one-shot semantics: `backoff_limit = 0` (migrations are
rarely safe to blindly re-run), `restart_policy = Never`,
`ttl_seconds_after_finished = 600`, and `wait_for_completion = true` so
`terraform apply` blocks until the run finishes and fails when it does — the
natural gate for release pipelines.

Because a failed run aborts immediately, gate on backing-service readiness with
the optional `init_command`, an init container sharing the Job's image and env:

```hcl
module "migrate" {
  source = "fabn/formation/kubernetes//modules/run"

  namespace  = module.app.namespace
  deployment = module.app.web_deployment_name
  image      = "ghcr.io/acme/myapp:1.2.3" # the artifact being released

  command      = ["/bin/bash", "-lc", "bin/rails db:migrate"]
  init_command = ["/bin/bash", "-lc", "until pg_isready -t 5; do echo 'waiting for postgres'; sleep 2; done"]

  # Only needed when the formation is applied from the same root: defers the
  # Deployment read to apply time so the first apply works too.
  depends_on = [module.app]
}
```

Typically the module lives in its own tiny root that a pipeline applies after
(or alongside) the release. Each apply that plans the Job creates a fresh
`<deployment>-run-<random>` Job (`generate_name`); after the TTL the finished
Job is garbage-collected, so a later refresh will plan a new run.

Inputs: `namespace`, `deployment`, `image`, `command` (required);
`init_command`, `name` (component label + name infix, default `run`), `env`
(extra vars on top of the inherited envFrom), `backoff_limit`,
`ttl_seconds_after_finished`, `wait_for_completion`, `timeout` (apply-side,
default `10m`), `active_deadline_seconds` (cluster-side, default unbounded).
Outputs: `job_name`.

## Examples

- [Minimal](examples/minimal) — web-only formation
- [Full featured](examples/full-featured) — web + worker + all addons

## Testing

Unit tests run against mocked providers, E2E tests run against a
[Kind](https://kind.sigs.k8s.io/) cluster (see `.github/workflows/e2e.yml`).

```bash
# Unit tests
terraform init && terraform test

# E2E tests (requires a Kind cluster with ports 80/443 mapped, see .github/kind-config.yml)
terraform -chdir=e2e init && terraform -chdir=e2e test
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
