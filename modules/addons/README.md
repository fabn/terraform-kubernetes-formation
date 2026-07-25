# `addons` wrapper

One `addons` map entry per backing service, each deployed as an instance of the
matching submodule under `../`. The merged `env` / `sensitive_env` outputs plug
straight into the formation module's `env` / `secret_env`, Heroku-addon style.

This is the companion of `fabn/addons/aws` (managed AWS backing services): same map
shape, same env contract, so a stack swaps in-cluster for cloud by pointing at the
other module (network inputs aside). Each submodule stays usable individually — and
exposes more knobs than the wrapper; this covers the common case of one stack with a
set of sized addons.

Supported addons: [`postgres`](../postgres), [`redis`](../redis),
[`memcached`](../memcached). The operator-backed addons
([`postgres-cnpg`](../postgres-cnpg), [`mariadb`](../mariadb),
[`dragonfly`](../dragonfly)) are used directly, not through this wrapper — they need
a cluster-wide operator and expose HA/placement surfaces the size presets don't
model.

## Contract

| Output | Value |
| --- | --- |
| `env` | Merged plaintext config vars of every enabled addon |
| `sensitive_env` | Merged credential vars of every enabled addon |
| `postgres`, `redis`, `memcached` | Per-addon connection details (`host`, plus `database`/`username` for postgres); `null` when the addon is not enabled |

## Usage

```hcl
module "addons" {
  source  = "fabn/formation/kubernetes//modules/addons"
  version = "~> 0.1"

  namespace = "myapp-staging"
  name      = "myapp-staging"

  addons = {
    postgres  = { size = "small" }
    redis     = { size = "mini" }
    memcached = { size = "mini", max_memory = 512 } # explicit knob wins over the preset
  }
}

module "app" {
  source = "fabn/formation/kubernetes"
  # ...
  env        = module.addons.env
  secret_env = module.addons.sensitive_env
}
```

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `namespace` | — | Namespace the addons are deployed into |
| `name` | — | Stack name (e.g. `myapp-staging`). Resources are named `<name>-<addon>`; the postgres database/user default to the stack name with dashes turned into underscores |
| `addons` | `{}` | Map of addon name => spec |

Per-entry spec: `size` (`mini` \| `small` \| `medium` \| `large`, default `mini`)
plus optional raw overrides that win over the preset for that field —
`cpu_requests`, `memory_requests` (postgres/memcached), `memory_limits` +
`storage_size` + `database` + `username` (postgres), `max_memory`
(redis/memcached), `persistence_enabled` + `persistence_size` +
`delete_pvc_on_delete` (redis). Applying a knob to the wrong addon is a validation
error, not a silent no-op.

## Size presets

| Addon | Preset | Sizing |
| --- | --- | --- |
| postgres | mini | 5Gi, 50m CPU, 128Mi/384Mi |
| | small | 10Gi, 250m CPU, 256Mi/512Mi |
| | medium | 20Gi, 500m CPU, 512Mi/1Gi |
| | large | 50Gi, 1000m CPU, 1Gi/2Gi |
| redis | mini | 256MB maxmemory, 10m CPU, 1Gi PVC |
| | small | 512MB, 20m CPU, 2Gi |
| | medium | 1024MB, 50m CPU, 4Gi |
| | large | 2048MB, 100m CPU, 8Gi |
| memcached | mini | 256MB item memory, 10m CPU, 64Mi request |
| | small | 512MB, 20m CPU, 96Mi |
| | medium | 1024MB, 50m CPU, 160Mi |
| | large | 2048MB, 100m CPU, 320Mi |

`mini` mirrors the submodule defaults; `small` mirrors a typical small-prod stack.

## HA & placement

**Not exposed**, and not planned: the three addons behind this wrapper are all
single-instance by construction, so there is nothing to spread or budget. A stack
that needs HA backing services uses the operator-backed submodules directly — see
their READMEs and the placement convention in `CLAUDE.md`.
