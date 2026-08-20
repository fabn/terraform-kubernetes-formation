# `cron` submodule

The `heroku scheduler` equivalent, and the recurring counterpart of
[`run`](../run): a `kubernetes_cron_job_v1` that executes a command on a
schedule in the same environment as a deployed process. Instead of re-declaring
that environment, it reads the live Deployment's pod template and inherits its
`envFrom` (which is how it picks up the content-hash-suffixed Secret/ConfigMap
names — addon connection vars included), `imagePullSecrets` and
`serviceAccountName`.

## Why not a formation process

A formation entry is a Deployment. A task meant to run for ten seconds every
five minutes would instead run once, exit, and be restarted by the kubelet in a
loop — which is a crash loop wearing a schedule's clothes. Applications whose
periodic work is a separate command (a CMS firing due events, a cleanup task, a
feed refresh) had no way to express that short of a hand-rolled resource in the
consuming stack.

If the periodic work is a *long-running* scheduler process instead — one that
sleeps and wakes on its own — that is a formation process, not this.

## Usage

```hcl
module "scheduler" {
  source  = "fabn/formation/kubernetes//modules/cron"
  version = "~> 0.1"

  namespace  = module.app.namespace
  deployment = module.app.web_deployment_name
  image      = "ghcr.io/acme/myapp:1.2.3"

  schedule = "*/5 * * * *"
  command  = ["/bin/bash", "-lc", "bin/rails runner Scheduler.tick"]

  # Only needed when the formation is applied from the same root: defers the
  # Deployment read to apply time so the first apply works too.
  depends_on = [module.app]
}
```

## Defaults worth knowing

They are chosen so a slow tick degrades gracefully instead of compounding:

| Input | Default | Why |
|---|---|---|
| `concurrency_policy` | `Forbid` | A tick due while the previous one is still running is far more often a slow run to wait out than one to duplicate. `Allow` turns a single slow tick into an unbounded pile-up. |
| `backoff_limit` | `0` | A recurring task gets its retry from the next tick. An immediate retry doubles the work of anything not idempotent. |
| `successful_jobs_history_limit` | `1` | Kubernetes keeps three; on a five-minute schedule that is steady clutter. |
| `ttl_seconds_after_finished` | `600` | Long enough to read the logs of the tick that just failed. |
| `suspend` | `false` | Set it to `true` to stop the schedule during a maintenance window or a cutover freeze without destroying the resource. |

Two inputs have no default and are worth setting deliberately:

- **`active_deadline_seconds`** — below the schedule period, so a hung run
  cannot block every later tick under `Forbid`.
- **`starting_deadline_seconds`** — without it, the controller fires every
  schedule it missed after a control-plane outage. Set it near the period to
  make a missed tick simply skip.

## Naming

The CronJob is `<deployment>-<name>` (default name `cron`), and its pods carry
that as `app.kubernetes.io/name` rather than the Deployment's own. Inheriting
the Deployment's identity label would make every tick pod a member of the web
Service's endpoints and of its PodDisruptionBudget — live traffic routed to a
pod running a batch command, and a disruption controller that cannot resolve a
Job's `scale` subresource. The relationship stays discoverable through
`app.kubernetes.io/part-of`.

## Extra pod labels (`pod_labels`)

`pod_labels` is merged onto the **pod template inside `jobTemplate`** only —
not onto the CronJob and not onto the Job. That is the level a mutating
admission webhook works at: it sees the Pod at create time, so a label sitting
on the CronJob never reaches the object being admitted.

The module's four `app.kubernetes.io/*` labels are merged last and always win,
so nothing passed here can put the Deployment's identity back on a tick pod
(see [Naming](#naming) for what that would break).

### Datadog tracing on every tick

With the Datadog admission controller in the cluster, one label is what turns a
tick pod into a traced one — the webhook mounts the agent's `/var/run/datadog`
hostPath, sets `DD_TRACE_AGENT_URL` to the socket, and injects `DD_SERVICE` /
`DD_ENV` from the UST labels:

```hcl
module "scheduler" {
  source  = "fabn/formation/kubernetes//modules/cron"
  version = "~> 0.13"

  namespace  = module.app.namespace
  deployment = module.app.web_deployment_name
  image      = "ghcr.io/acme/myapp:1.2.3"

  schedule = "*/5 * * * *"
  command  = ["/bin/bash", "-lc", "bin/rails runner Scheduler.tick"]

  pod_labels = {
    "admission.datadoghq.com/enabled" = "true"
    "tags.datadoghq.com/service"      = "myapp"
    "tags.datadoghq.com/env"          = "production"
  }

  depends_on = [module.app]
}
```

Without it, the only way to trace a scheduled task was to point
`DD_TRACE_AGENT_URL` at the agent's Service by hand through `env` — a
workaround that bypasses the socket and the UST injection.
