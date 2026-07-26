# `run` submodule

The `heroku run` / release-phase equivalent: a `kubernetes_job_v1` that runs a
one-shot command (DB migrations, seed loading, arbitrary tasks) in the same
environment as a deployed process. Instead of re-declaring that environment, the Job
reads the live Deployment's pod template and inherits its `envFrom` (which is how it
picks up the content-hash-suffixed Secret/ConfigMap names — addon connection vars
included), `imagePullSecrets` and `serviceAccountName`.

Two things stay deliberately explicit:

- **`image`** — pin the run to the artifact being released, never to whatever stale
  tag the Deployment currently points at.
- **`command`** — what to run.

## Usage

```hcl
module "migrate" {
  source  = "fabn/formation/kubernetes//modules/run"
  version = "~> 0.1"

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

Typically the module lives in its own tiny root that a pipeline applies after (or
alongside) the release. Each apply that plans the Job creates a fresh
`<deployment>-run-<random>` Job (`generate_name`); after the TTL the finished Job is
garbage-collected, so a later refresh will plan a new run.

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `namespace` | — | Namespace of the Deployment and the Job |
| `deployment` | — | Deployment whose pod template the run inherits |
| `image` | — | Image to run (pin the released artifact) |
| `command` | — | Command to run |
| `init_command` | `null` | Init container sharing the Job's image and env — the place to gate on backing-service readiness |
| `name` | `run` | Component label + name infix |
| `env` | `{}` | Extra vars on top of the inherited `envFrom` |
| `backoff_limit` | `0` | One-shot: migrations are rarely safe to blindly re-run |
| `ttl_seconds_after_finished` | `600` | Finished-Job garbage collection |
| `wait_for_completion` | `true` | `terraform apply` blocks until the run finishes and fails when it does — the natural gate for release pipelines |
| `timeout` | `10m` | Apply-side wait budget |
| `active_deadline_seconds` | `null` | Cluster-side deadline (unbounded by default) |

Output: `job_name`.

## Labels

The Job and its pods carry:

| Label | Value |
| --- | --- |
| `app.kubernetes.io/name` | `<deployment>-<name>` |
| `app.kubernetes.io/component` | `<name>` |
| `app.kubernetes.io/part-of` | `<deployment>` |
| `app.kubernetes.io/managed-by` | `terraform` |

The run deliberately gets **its own** `app.kubernetes.io/name` instead of the
Deployment's — the same way a sibling formation process is named `<app>-worker`
upstream — and keeps the relationship discoverable through
`app.kubernetes.io/part-of`.

That matters because `app.kubernetes.io/name = <deployment>` is the selector
`fabn/workload/kubernetes` gives the Deployment, its Service, its ServiceMonitor
and its PodDisruptionBudget. A Job pod carrying it is selected by all of them:
the disruption controller cannot compute the expected pod count for a pod owned
by a Job (no `scale` subresource) and logs `CalculateExpectedPodCountFailed`,
leaving the PDB status frozen while the run pod exists, and the pod is otherwise
eligible for the web Service's endpoints.

Note for Datadog users: the agent derives `kube_app_name` from
`app.kubernetes.io/name`, so run pods are tagged `<deployment>-<name>` rather
than `<deployment>`. `service` / `env` tagging is unaffected — this module sets
no `tags.datadoghq.com/*` labels and the run inherits `DD_*` variables through
the Deployment's `envFrom` as before.

## Notes

Because a failed run aborts the apply immediately, gate on backing-service readiness
with `init_command` rather than letting the command itself fail on a database that is
still starting.

`restart_policy` is `Never` and the Job is created with `generate_name`, so runs
never collide and a retry is a new Job — never a silent in-place restart.

## HA & placement

Not applicable: a Job is a one-shot, single-pod run. Placement is inherited from the
Deployment's pod template together with the rest of its environment.
