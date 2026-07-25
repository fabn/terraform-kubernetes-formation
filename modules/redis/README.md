# `redis` addon

Bitnami Redis chart, **standalone**, no auth (in-cluster only). AOF persistence +
`noeviction` so queues and flags never silently disappear under memory pressure.

For an HA cache/queue backend (master + replica, operator-managed failover,
optional auth and S3 snapshots) use the [`dragonfly`](../dragonfly) addon instead —
same `REDIS_URL` contract, so the swap is invisible to the app.

## Contract

| Output | Vars |
| --- | --- |
| `env` | `REDIS_URL` |
| `sensitive_env` | Always empty (no auth in-cluster); present to satisfy the addon contract |
| `host` | Hostname of the master Service (`<name>-master`) |

## Usage

```hcl
module "redis" {
  source  = "fabn/formation/kubernetes//modules/redis"
  version = "~> 0.1"

  namespace  = "myapp-staging"
  max_memory = 512
}
```

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `namespace` | — | Namespace the chart is released into |
| `name` | `redis` | Release name; the Service is `<name>-master` |
| `chart_version` | `20.1.7` | Bitnami `redis` chart version |
| `max_memory` | `256` | `maxmemory` in MB. Also drives the memory request (`<max_memory>Mi`) and limit (`1.25 ×`) |
| `cpu_requests` | `10m` | CPU request |
| `persistence_enabled` | `true` | AOF persistence on a PVC |
| `persistence_size` | `1Gi` | PVC size |
| `delete_pvc_on_delete` | `false` | Keep the PVC when the release is destroyed |

## HA & placement

**Not exposed.** Standalone by construction: no PDB, no anti-affinity, no node
affinity/selector, no topology spread — a drain or Spot reclaim restarts the only
instance, and with `noeviction` + AOF the data comes back but the queue stalls
meanwhile. Use it for dev/staging and for stacks that tolerate that; for anything
production-shaped use [`dragonfly`](../dragonfly), which exposes the placement
surface described in `CLAUDE.md`.

## Notes

`noeviction` is deliberate: this addon is sized as a *queue/state* store, not a
cache. A cache that should evict at `maxmemory` instead of rejecting writes is
[`dragonfly`](../dragonfly) with `cache_mode = true`, or [`memcached`](../memcached).

The values file pins `bitnamilegacy/*` repositories with
`global.security.allowInsecureImages`: chart >= 15.x rejects unrecognised
registries ([bitnami/charts#30850](https://github.com/bitnami/charts/issues/30850)).

Reference: [Bitnami Redis chart](https://github.com/bitnami/charts/tree/main/bitnami/redis).
