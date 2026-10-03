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
| `datadog` | `null` | Datadog Postgres integration on every instance (see below) |

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

#### Production block

The defaults are tuned for a stack that also has to run on a single-node dev
cluster, so production needs an explicit block. This is it, whole — paste it and
adjust:

```hcl
instances = 2 # >= 2, or there is nothing to fail over to

# Hard spread per node: `preferred` is the default because it fits single-node.
enable_pod_anti_affinity = true
pod_anti_affinity_type   = "required"
topology_key             = "kubernetes.io/hostname"

# Zone spread on top, since the anti-affinity above spreads on one key only.
topology_spread_constraints = [{
  maxSkew           = 1
  topologyKey       = "topology.kubernetes.io/zone"
  whenUnsatisfiable = "ScheduleAnyway" # DoNotSchedule once every zone has capacity
}]

# Keep the primary off Spot: a reclaim costs a failover and a write blip.
node_affinity = {
  required  = [{ key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }]
  preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["arm64"] }]
}

# Continuous backup + PITR. Keyless via Pod Identity / IRSA.
backup = {
  destination_path = "s3://acme-backups/myapp-production"
  retention_policy = "30d"
}
```

Already right by default, so absent above: `enable_pdb` (the operator manages the
PDBs). Deliberately not defaulted, because each needs something only you know: the
zone label key exists only on a multi-zone cluster, `karpenter.sh/capacity-type`
assumes Karpenter, and the backup needs a bucket. Size the instances (`storage_size`,
`memory_limits`, …) separately — placement says nothing about capacity.

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

### Datadog

`datadog` wires the [Datadog Postgres integration](https://docs.datadoghq.com/integrations/postgres/)
into every instance, through Autodiscovery annotations and no agent-side config:

```hcl
datadog = {
  tags = ["env:production", "service:myapp-postgres"]
  # username = "datadog"                           # the monitoring role
  # dbm      = true                                # Database Monitoring, see below
  # relations = false                              # per-table metrics, on by default
  # instance = { collect_activity_metrics = true } # any other check option
  # password_from_secret = {}                      # see below
}
```

It adds three things:

- a `<name>-datadog` basic-auth Secret with a generated password;
- a login role in `pg_monitor`, declared in `spec.managed.roles`, so the
  operator creates it on an existing cluster too, not only at bootstrap;
- an `ad.datadoghq.com/postgres.checks` annotation, propagated through
  `spec.inheritedMetadata` onto every instance pod, connecting to `%%host%%`
  (the pod itself) on the application database.

Each instance is checked on its own, replicas included, so per-instance
connections, cache hit ratio, transaction rate, temp files, database size and
replication delay land next to the pod's CPU and memory, which the agent already
collects from the kubelet.

`relations` (on by default) also collects per-table metrics for every table of
the application database: table, index and total size, live and dead tuples,
sequential and index scans, last vacuum and analyze. It is the
[`relations`](https://docs.datadoghq.com/integrations/postgres/) option of the
check with `relation_regex: ".*"`, capped by the check's `max_relations` (300),
and `pg_monitor` already has the access it needs. Only the annotation changes,
so turning it on or off restarts nothing. `instance = { relations = [...] }`
replaces the default list, with the check's full syntax: names or regexes,
schemas, relation kinds.

```hcl
datadog = {
  instance = {
    relations = [
      { relation_regex = "^orders_.*", schemas = ["public"] }, # matching tables in one schema
      { relation_name = "events", relkind = ["r", "p"] },      # a table and its partitions
    ]
  }
}
```

`pg_monitor` reads statistics and settings, not table data. It does see the text
of the queries every session is running, literals included.

By default the password is in plain text in the pod annotation, which is how
the agent reads it: anyone who can read the pods in the namespace can read it.

#### Password from the role's Secret

`password_from_secret` puts an `ENC[]` handle in the annotation instead, which
the agent resolves from the `<name>-datadog` Secret through its
[`k8s.secrets` secret backend](https://docs.datadoghq.com/agent/configuration/secrets-management/)
(Agent 7.75+). The module also creates a Role granting `get` on that one Secret,
and binds it to the agent's service accounts:

```hcl
datadog = {
  password_from_secret = {
    # backend = "k8s"   # the backend's name under multi_secret_backends (Agent 7.80+);
    #                   # omit when k8s.secrets is the agent's only backend
    # readers = [{ namespace = "datadog", name = "datadog-agent" }]   # the default
  }
}
```

| agent configuration | handle written to the annotation |
| --- | --- |
| `secret_backend_type: k8s.secrets` | `ENC[<namespace>/<name>-datadog;password]` |
| `multi_secret_backends` with a `k8s.secrets` entry named `k8s` | `ENC[k8s;<namespace>/<name>-datadog;password]` |

The agent side is not the module's to configure: turn on the backend before
turning this on, or the check fails to authenticate. `readers` defaults to the
node agent's service account as the Datadog Operator names it; pod annotations
are scheduled on the node agent, so that is the one that resolves the handle.

#### Database Monitoring

`dbm = true` turns on [Database Monitoring](https://docs.datadoghq.com/database_monitoring/setup_postgres/selfhosted/)
in the check and sets the server parameters it needs (`pg_stat_statements.*`,
`track_activity_query_size`, `track_io_timing`). The operator preloads
`pg_stat_statements` and creates the extension on its own. Two caveats:

- `track_activity_query_size` and the preload need a restart, so turning it on
  rolls every instance, with a switchover.
- Explain plans need the `datadog.explain_statement` function from the setup
  guide in the application database. The module does not create it: query
  metrics and samples work without it, plans do not.

Database Monitoring is billed separately from infrastructure monitoring.

Reference: [CloudNativePG](https://github.com/cloudnative-pg/cloudnative-pg)
([Cluster CRD](https://cloudnative-pg.io/docs/1.30/cloudnative-pg.v1)),
[barman-cloud plugin](https://github.com/cloudnative-pg/plugin-barman-cloud).
