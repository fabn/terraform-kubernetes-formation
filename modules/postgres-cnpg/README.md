# `postgres-cnpg` addon

CloudNativePG operator `Cluster` — a drop-in swap for the Bitnami
[`postgres`](../postgres) addon (identical env contract; only the host differs,
the operator serves the primary on `<name>-rw`). Primary + optional replicas with
operator-managed failover, a per-instance generated password in Terraform state +
the auth Secret, and optional continuous backup + PITR to S3 via the barman-cloud
plugin (keyless with `inheritFromIAMRole` on EKS Pod Identity / IRSA).

**Requires** the CloudNativePG operator — and, for backups, the barman-cloud
plugin — installed cluster-wide.

## Contract

| Output | Vars |
| --- | --- |
| `env` | `PGHOST` (the operator's `<name>-rw` Service), `PGPORT`, `PGUSER`, `PGDATABASE` |
| `sensitive_env` | `DATABASE_URL`, `PGPASSWORD` |
| `host`, `cluster_name` | Read/write Service hostname, `Cluster` name |

## Usage

```hcl
module "postgres" {
  source  = "fabn/formation/kubernetes//modules/postgres-cnpg"
  version = "~> 0.1"

  namespace = "myapp-production"
  database  = "myapp"
  username  = "myapp"

  instances    = 2
  storage_size = "20Gi"

  # Keep the primary off Spot: a reclaim forces a failover / write blip.
  node_affinity = {
    required = [{ key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }]
  }

  # Continuous backup + PITR, keyless via Pod Identity / IRSA.
  backup = {
    destination_path = "s3://acme-backups/myapp-production"
    retention_policy = "30d"
  }
}
```

See also [`examples/postgres-cnpg`](../../examples/postgres-cnpg).

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `namespace` | — | Namespace the `Cluster` is created in |
| `database` | — | Database created at bootstrap |
| `username` | — | Application role (owner) |
| `name` | `pg` | `Cluster` name; the primary is served on `<name>-rw` |
| `instances` | `1` | Primary + replicas. `>= 2` for operator-managed failover |
| `image_name` | `null` | Postgres image; `null` uses the operator default |
| `part_of`, `labels`, `annotations` | `null`, `{}`, `{}` | Metadata (inherited by the operator's objects) |
| `storage_size`, `storage_class` | `5Gi`, `null` | Data volume |
| `cpu_requests`, `cpu_limits` | `50m`, `null` | CPU |
| `memory_requests`, `memory_limits` | `256Mi`, `512Mi` | Memory |
| `wait_for_ready`, `ready_timeout` | `false`, `10m` | Block the apply until the operator reports Ready |
| `backup` | `null` | Continuous backup + PITR to S3 via barman-cloud (see below) |

### HA & placement

| Name | Default | Description |
| --- | --- | --- |
| `enable_pdb` | `true` | Operator-managed PodDisruptionBudgets (one for the primary, one for the replicas), so a drain never takes the primary and always leaves a replica. Disable for single-instance/dev stacks |
| `enable_pod_anti_affinity` | `true` | Spread instances across nodes |
| `pod_anti_affinity_type` | `preferred` | `required` (hard, true HA) or `preferred` (soft, fits single-node/dev) |
| `topology_key` | `kubernetes.io/hostname` | Topology key the anti-affinity spreads on (use a zone key where zones exist) |
| `node_affinity` | `null` | Set-based placement: `required` + `preferred` match expressions, same shape as a formation web process. Rendered into `spec.affinity.nodeAffinity` |
| `topology_spread_constraints` | `[]` | Passed verbatim to `spec.topologySpreadConstraints` (k8s camelCase, cluster-level — not part of the affinity block). Spreads across zones with an explicit skew, where the anti-affinity knobs spread on a single topology key |
| `node_selector` | `{}` | Exact-match labels (e.g. a dedicated DB node pool) |
| `tolerations` | `[]` | e.g. the `dedicated=database:NoSchedule` taint on a DB node pool |
| `priority_class_name` | `null` | PriorityClass for the instance pods |

A common production pin, on top of the anti-affinity defaults, keeps the primary
on on-demand capacity and optionally prefers arm64:

```hcl
node_affinity = {
  required  = [{ key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }]
  preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["arm64"] }]
}
```

On a multi-zone cluster, pair the per-node anti-affinity with a zone spread —
`enable_pod_anti_affinity` only spreads on one topology key at a time:

```hcl
topology_spread_constraints = [{
  maxSkew           = 1
  topologyKey       = "topology.kubernetes.io/zone"
  whenUnsatisfiable = "ScheduleAnyway" # DoNotSchedule once every zone has capacity
}]
```

### Shutdown / lifecycle timings

| Name | Default | Description |
| --- | --- | --- |
| `stop_delay` | `300` | Graceful shutdown budget. The operator copies it onto the pod's `terminationGracePeriodSeconds` |
| `smart_shutdown_timeout` | `30` | Part of `stop_delay` spent waiting for connections to close on their own before escalating to fast shutdown. Must be `< stop_delay` |
| `switchover_delay` | `null` | Planned-switchover budget; `null` ⇒ operator default (3600) |
| `start_delay` | `null` | Startup readiness budget; `null` ⇒ operator default (3600) |
| `failover_delay` | `null` | Delay before promoting a replica; `null` ⇒ operator default (0, immediate) |

CloudNativePG's stock shutdown budget (`stopDelay` 1800s,
`smartShutdownTimeout` 180s) is tuned for large databases and works against fast
node lifecycles: since `stopDelay` becomes the pod's
`terminationGracePeriodSeconds`, at the default a single instance can hold up a
node drain (cluster-autoscaler / Karpenter consolidation) for up to 30 minutes —
and it can never be honoured inside a Spot interruption's ~2-minute window
anyway. This addon therefore ships shorter, drain-friendly defaults and leaves the
rest as opt-in passthroughs (`null` ⇒ operator default). Raise `stop_delay` for a
large database whose shutdown checkpoint legitimately needs more time.

### Backup (barman-cloud)

`backup` creates an `ObjectStore`, wires it into the `Cluster` as the WAL archiver
and schedules base backups:

```hcl
backup = {
  destination_path = "s3://acme-backups/myapp"     # s3://<bucket>/<path>
  retention_policy = "30d"
  schedule         = "0 0 3 * * *"                 # 6-field cron (with seconds)
  # credentials_secret_name = "s3-creds"           # omit ⇒ inheritFromIAMRole
  # endpoint_url           = "https://…"           # only for non-AWS S3-compatible stores
}
```

Leaving `credentials_secret_name` null makes the backup keyless: the pods write
with their ambient IAM identity (EKS Pod Identity / IRSA).

Reference: [CloudNativePG](https://github.com/cloudnative-pg/cloudnative-pg)
([Cluster CRD](https://cloudnative-pg.io/docs/1.30/cloudnative-pg.v1)),
[barman-cloud plugin](https://github.com/cloudnative-pg/plugin-barman-cloud).
