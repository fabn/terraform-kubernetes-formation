# `memcached` addon

Plain memcached on `fabn/workload/kubernetes`, deliberately **ephemeral**: no PVC,
so a pod restart cold-starts an empty cache and the application treats it as a
miss. No ingress and no probes — the kubelet restarts the pod on process exit,
the only failure mode that matters for a cache.

## Contract

| Output | Vars |
| --- | --- |
| `env` | `MEMCACHED_SERVERS` — a comma-separated `host:port` server list (one node here) |
| `sensitive_env` | Always empty (no SASL); present to satisfy the addon contract |
| `host` | Hostname of the memcached Service |

`MEMCACHED_SERVERS` is deliberately **not** a `memcached://…` URL: memcached
clients (dalli et al.) parse a `host:port` list, not a URI scheme — unlike
`redis://` / `postgresql://`, whose clients do parse the scheme, so a prefix here
would only force the app to strip it. This matches the MemCachier/Heroku
convention and the managed companion `fabn/addons/aws`, which emits the same list,
so an in-cluster ⇄ managed swap stays invisible to the app.

## Usage

```hcl
module "memcached" {
  source  = "fabn/formation/kubernetes//modules/memcached"
  version = "~> 0.1"

  namespace  = "myapp-staging"
  max_memory = 512
}
```

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `namespace` | — | Namespace the workload is created in |
| `name` | `memcached` | Workload/Service name |
| `image` | `memcached:1.6-alpine` | Container image |
| `max_memory` | `256` | `-m` item memory cap in MB. Also drives the memory limit (`1.25 ×`, for slab + connection overhead) |
| `cpu_requests` | `10m` | CPU request |
| `memory_requests` | `64Mi` | Memory request |
| `labels`, `annotations` | `{}`, `{}` | Metadata on the workload / pods |

## HA & placement

**Not exposed.** Single ephemeral replica, no PDB, no anti-affinity, no node
affinity/selector, no topology spread: a drain cold-starts the cache, which is the
accepted trade-off for this addon rather than an oversight. If a cache ever needs
to survive node churn, that is a [`dragonfly`](../dragonfly) instance with
`cache_mode = true` — it has replicas, failover and the placement surface described
in `CLAUDE.md`.

Reference: [`fabn/workload/kubernetes`](https://registry.terraform.io/modules/fabn/workload/kubernetes/latest).
