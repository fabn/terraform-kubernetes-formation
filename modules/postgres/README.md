# `postgres` addon

Bitnami PostgreSQL chart, **standalone** architecture. The password is generated
per instance and stays in Terraform state + the auth Secret, so ephemeral
environments need no plaintext secret anywhere.

For an HA database (primary + replicas, operator-managed failover, PITR to S3)
use the [`postgres-cnpg`](../postgres-cnpg) addon instead — identical env contract, so
the swap is invisible to the app.

## Contract

| Output | Vars |
| --- | --- |
| `env` | `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` (so `psql` inside the pod connects with no args) |
| `sensitive_env` | `DATABASE_URL`, `PGPASSWORD` |
| `host` | Hostname of the Postgres Service (`<name>-postgresql`) |

## Usage

```hcl
module "postgres" {
  source  = "fabn/formation/kubernetes//modules/postgres"
  version = "~> 0.1"

  namespace = "myapp-staging"
  database  = "myapp"
  username  = "myapp"

  storage_size = "10Gi"
}

module "app" {
  source = "fabn/formation/kubernetes"
  # ...
  env        = module.postgres.env
  secret_env = module.postgres.sensitive_env
}
```

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `namespace` | — | Namespace the chart is released into |
| `database` | — | Database created at bootstrap |
| `username` | — | Application role |
| `name` | `pg` | Release name; the Service is `<name>-postgresql` |
| `part_of` | `null` | `app.kubernetes.io/part-of` on the auth Secret |
| `chart_version` | `16.6.7` | Bitnami `postgresql` chart version |
| `storage_size` | `5Gi` | PVC size for the data volume |
| `cpu_requests` | `50m` | CPU request |
| `memory_requests` | `128Mi` | Memory request |
| `memory_limits` | `384Mi` | Memory limit |

## HA & placement

**Not exposed.** This addon is single-instance by construction (no PDB, no
anti-affinity, no node affinity/selector, no topology spread), so it takes an
availability hit on every node lifecycle event — a drain or a Spot reclaim
restarts the only instance. It is meant for dev/staging and for stacks that can
tolerate that; anything production-shaped belongs on
[`postgres-cnpg`](../postgres-cnpg), which exposes the full placement surface
described in `CLAUDE.md`.

## Notes

The values file pins `bitnamilegacy/*` repositories with
`global.security.allowInsecureImages`: chart >= 15.x rejects unrecognised
registries ([bitnami/charts#30850](https://github.com/bitnami/charts/issues/30850)).

Reference: [Bitnami PostgreSQL chart](https://github.com/bitnami/charts/tree/main/bitnami/postgresql).
