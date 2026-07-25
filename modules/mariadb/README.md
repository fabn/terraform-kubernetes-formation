# `mariadb` addon

mariadb-operator `MariaDB` — the MySQL-family database, same `DATABASE_URL`
contract as the postgres addons. Either a single standalone server (clients use
the `<name>` Service) or primary + replicas with operator-managed async
replication and automatic failover (clients use `<name>-primary`, repointed on
failover). Terraform owns the app + root passwords; optional scheduled physical
backups to S3 (keyless via EKS Pod Identity / IRSA), and optional adoption of an
existing database by bootstrapping from a logical dump in S3.

**Requires** the mariadb-operator installed cluster-wide.

## Contract

| Output | Vars |
| --- | --- |
| `env` | `MYSQL_HOST` (`<name>-primary` in HA, `<name>` standalone), `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_DATABASE` |
| `sensitive_env` | `DATABASE_URL`, `MYSQL_PWD` |
| `host`, `mariadb_name`, `service_account_name` | Service hostname, CR name, created ServiceAccount |

## Usage

```hcl
module "mariadb" {
  source  = "fabn/formation/kubernetes//modules/mariadb"
  version = "~> 0.1"

  namespace = "myapp-production"
  database  = "myapp"
  username  = "myapp"

  replicas      = 2      # primary + replica, operator-managed failover
  anti_affinity = true   # requires at least as many nodes as replicas
  storage_size  = "20Gi"

  pod_disruption_budget = { minAvailable = "50%" }

  service_account_name = "myapp-mariadb" # for keyless S3 backups
  backup = {
    bucket   = "acme-backups"
    prefix   = "myapp-production"
    region   = "eu-west-1"
    schedule = "0 3 * * *"
  }
}
```

See also [`examples/mariadb`](../../examples/mariadb).

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `namespace` | — | Namespace the `MariaDB` is created in |
| `database` | — | Database created at bootstrap |
| `username` | — | Application user |
| `name` | `mariadb` | CR name; the Service is `<name>` (`<name>-primary` in HA) |
| `replicas` | `2` | `1` = standalone, `>= 2` = primary + replicas with replication |
| `auto_failover` | `true` | Let the operator promote a replica when the primary fails |
| `image` | `null` | MariaDB image; `null` uses the operator default |
| `part_of`, `labels`, `annotations` | `null`, `{}`, `{}` | Metadata |
| `storage_size`, `storage_class` | `5Gi`, `null` | Data volume |
| `cpu_requests`, `cpu_limits` | `100m`, `null` | CPU |
| `memory_requests`, `memory_limits` | `512Mi`, `1Gi` | Memory. Keep `innodb_buffer_pool_size` in line with the limit — exceeding it is an OOM-kill |
| `service_account_name` | `null` | ServiceAccount for the instance and backup pods (created here); required for keyless S3 |
| `service_account_annotations` | `{}` | e.g. the IRSA `eks.amazonaws.com/role-arn` |
| `backup` | `null` | Scheduled physical backups to S3 (see below) |
| `bootstrap_from` | `null` | Adopt an existing database from a logical dump in S3 (see below) |
| `wait_for_ready`, `ready_timeout` | `false`, `10m` | Block the apply until the operator reports Ready |

### HA & placement

| Name | Default | Description |
| --- | --- | --- |
| `enable_pdb` | `true` | Create a PodDisruptionBudget when `replicas > 1` (the operator manages none itself). `false` opts out on dev clusters |
| `pod_disruption_budget` | `null` | Override the default budget: exactly one of `min_available` / `max_unavailable`, absolute (`"1"`) or percentage (`"50%"`). An explicit budget is honoured on a standalone instance too |
| `anti_affinity` | `false` | Require instances to spread across nodes (true HA). Leave false on single-node clusters, or replicas stay `Pending` |
| `node_affinity` | `null` | Set-based placement: `required` + `preferred` match expressions, same shape as a formation web process. Rendered into `spec.affinity.nodeAffinity`, alongside `anti_affinity` rather than instead of it |
| `topology_spread_constraints` | `[]` | Passed verbatim to `spec.topologySpreadConstraints` (k8s camelCase). Spreads across zones with an explicit skew and a soft/hard `whenUnsatisfiable`, where `anti_affinity` only offers hard per-node spreading |
| `node_selector` | `{}` | Exact-match labels (e.g. a dedicated DB node pool) |
| `tolerations` | `[]` | e.g. the `dedicated=database:NoSchedule` taint on a DB node pool |
| `priority_class_name` | `null` | PriorityClass for the instance pods |

**Disruption budget.** mariadb-operator manages no PodDisruptionBudget of its own,
and this module defaults to `replicas = 2` — so without one a node drain could take
the primary and its replica at once. An HA instance therefore gets a budget by
default (`maxUnavailable = 1`, the same choice the Dragonfly operator makes above
one replica); a standalone instance gets none, because a single-pod
`minAvailable = 1` blocks every drain forever. `enable_pdb = false` opts out,
`pod_disruption_budget` reshapes it:

```hcl
replicas              = 3
pod_disruption_budget = { min_available = "2" }
```

Exactly one of the two keys may be set, validated at plan time. Both still reach
the manifest, the unused one as `null` — `kubernetes_manifest` types the object from
the CRD schema and requires every attribute, the same constraint that applies to
[`dragonfly`](../dragonfly)'s `spec.pdb` and
[`postgres-cnpg`](../postgres-cnpg)'s `inheritedMetadata` — and the API server
treats that null as an absent key.

#### Production block

The defaults are tuned for a stack that also has to run on a single-node dev
cluster, so production needs an explicit block. This is it, whole — paste it and
adjust:

```hcl
replicas      = 2    # >= 2, or there is nothing to fail over to
auto_failover = true # default, but it is the point of running HA
anti_affinity = true # hard per-node spread; needs >= replicas nodes

# Zone spread on top: anti_affinity only spreads per node.
topology_spread_constraints = [{
  maxSkew           = 1
  topologyKey       = "topology.kubernetes.io/zone"
  whenUnsatisfiable = "ScheduleAnyway" # DoNotSchedule once every zone has capacity
}]

# Keep the primary off Spot: a reclaim forces a failover and a write blip.
node_affinity = {
  required  = [{ key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] }]
  preferred = [{ weight = 100, key = "kubernetes.io/arch", operator = "In", values = ["arm64"] }]
}

# Scheduled physical backups, keyless via Pod Identity / IRSA.
service_account_name = "myapp-mariadb"
backup = {
  bucket = "acme-backups"
  prefix = "myapp-production"
  region = "eu-west-1"
}
```

Already right by default, so absent above: the disruption budget (created for you
above one replica). Deliberately not defaulted, because each needs something only
you know: `anti_affinity` leaves replicas `Pending` on a single node, the zone label
key exists only on a multi-zone cluster, `karpenter.sh/capacity-type` assumes
Karpenter, and the backup needs a bucket. Size the instances (`storage_size`,
`memory_limits`, …) separately — placement says nothing about capacity.

### Backup

Keyless by default: leave `credentials_secret_name` null and the backup Job writes
with the pod's ambient IAM identity (EKS Pod Identity / IRSA) via
`service_account_name` — validated, so a keyless backup without a ServiceAccount
is rejected at plan time. The operator requires an explicit S3 endpoint, so
`region` builds it (`s3.<region>.amazonaws.com`); set `endpoint_url` only to
override it for non-AWS S3-compatible stores.

```hcl
backup = {
  bucket        = "acme-backups"
  prefix        = "myapp-production"
  region        = "eu-west-1"
  schedule      = "0 3 * * *"
  max_retention = "720h" # 30d
}
```

### Adoption (`bootstrap_from`)

Bootstraps a newly created instance from a logical dump in S3. The object must be
named `backup.<RFC3339>.sql` (e.g. `backup.2026-07-22T10:00:00Z.sql`); set
`target_recovery_time` to pick one when several exist. Only applied at creation.

**Caveat.** A full logical dump carries the application user, so the operator's
`User` reconcile may fail (`ALTER USER … Error 1396`) and the app password won't
match `passwordSecretKeyRef`. After adopting, reset the app user to match the
Secret (as root), or take the source dump with data only.

Reference: [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator)
([MariaDB CRD](https://github.com/mariadb-operator/mariadb-operator/blob/main/docs/api_reference.md)).
