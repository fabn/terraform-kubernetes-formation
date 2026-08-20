# `cron` submodule

The `heroku scheduler` equivalent, and the recurring counterpart of
[`run`](../run): a `kubernetes_cron_job_v1` that executes a command on a
schedule in the same environment as a deployed process. Instead of re-declaring
that environment, it reads the live Deployment's pod template and inherits its
`envFrom` (which is how it picks up the content-hash-suffixed Secret/ConfigMap
names — addon connection vars included), `imagePullSecrets`,
`serviceAccountName` and the **volumes its container mounts**.

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

## Volumes

Every volume the Deployment's container mounts is mounted into the tick pod, at
the same path, with the same `subPath` and `readOnly` (a claim the pod itself
declares read-only stays read-only). This is on by default, and
`inherit_volumes = false` is the way out.

**Why a default and not an opt-in.** The two failure modes are not symmetric:

- A tick running *without* the process's volume fails silently. The mount path
  exists inside the image anyway, so a read finds an empty directory — and may
  conclude a generated file needs rebuilding — while a write lands in the
  container's ephemeral layer and is discarded when the tick ends. Nothing
  errors, so nothing surfaces until someone goes looking.
- A tick inheriting a volume it cannot mount leaves the pod `Pending`, which is
  visible in seconds.

It is also the category the rest of this module already works in: `envFrom` and
the service account are the environment of the *process*, and so is its storage
— the caller owns the claim, but it owns the Secret and the ConfigMap too, and
those are inherited without being asked for. And it is the `heroku scheduler`
behaviour the module is modelled on: an inherited `emptyDir` becoming a fresh
per-tick directory is the ephemeral dyno filesystem, correctly reproduced.

What is inherited, precisely:

- Only volumes the process's **own container** mounts — a pod volume nothing
  mounts carries no path to reproduce it at.
- `secret`, `configMap`, `persistentVolumeClaim` and `emptyDir` sources; an
  `emptyDir` keeps its `medium` and `sizeLimit`, so a tmpfs stays a tmpfs.
  Anything else (a `hostPath`, a `csi` volume) **fails the plan** with the
  volume named, rather than being dropped — a silently missing mount is the
  defect this inheritance exists to close. Set `inherit_volumes = false` and
  declare what the tick needs through `volumes`.
- Fields are read by name, not copied through: the pod template comes back from
  the API defaulted (`mountPropagation: "None"` on every mount) and
  `defaultMode` comes back as the decimal `420`, which is rendered back as
  `"0644"`.

`volumes` mounts something the tick needs and the web process does not. It is
**additive** to what was inherited, and an entry whose `name` matches an
inherited volume **replaces** it:

```hcl
module "scheduler" {
  source  = "fabn/formation/kubernetes//modules/cron"
  version = "~> 0.14"

  namespace  = module.app.namespace
  deployment = module.app.web_deployment_name
  image      = "ghcr.io/acme/myapp:1.2.3"

  schedule = "*/5 * * * *"
  command  = ["/bin/bash", "-lc", "wp cron event run --due-now"]

  # The uploads claim the web process mounts is already there; this only adds
  # what the schedule needs on top of it.
  volumes = [{
    name                    = "exports"
    mount_path              = "/exports"
    persistent_volume_claim = "myapp-exports"
  }]

  depends_on = [module.app]
}
```

Each entry sets at most one of `secret`, `config_map`,
`persistent_volume_claim` (validated at plan time); setting none renders an
`emptyDir`. Claims are never created here — a claim outlives the process that
mounts it, and a module owning it would destroy data on a rename.

A `ReadWriteOnce` claim is the one case worth a thought: a tick inheriting one
can sit `Pending` while the web pod holds it on another node. That is the loud
failure of the two, and `inherit_volumes = false` is there for it.

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

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `namespace` | — | Namespace of the Deployment and the CronJob |
| `deployment` | — | Deployment whose pod template the ticks inherit |
| `image` | — | Image each tick runs |
| `command` | — | Command each tick runs |
| `schedule` | — | Five-field cron expression, or an `@` shorthand |
| `name` | `cron` | Component label + CronJob name suffix (`<deployment>-<name>`) |
| `timezone` | `null` | IANA zone the schedule is read in (k8s >= 1.27) |
| `concurrency_policy` | `Forbid` | `Allow` / `Forbid` / `Replace` |
| `starting_deadline_seconds` | `null` | How late a missed tick may still start |
| `suspend` | `false` | Stop firing without destroying the resource |
| `successful_jobs_history_limit` | `1` | Completed Jobs kept |
| `failed_jobs_history_limit` | `1` | Failed Jobs kept |
| `backoff_limit` | `0` | Retries within a tick |
| `ttl_seconds_after_finished` | `600` | Finished-Job garbage collection |
| `active_deadline_seconds` | `null` | Cluster-side deadline for one tick |
| `env` | `{}` | Extra vars on top of the inherited `envFrom` |
| `pod_labels` | `{}` | Extra labels on the tick pods only |
| `inherit_volumes` | `true` | Inherit the volumes the Deployment's container mounts |
| `volumes` | `[]` | Extra volumes: `{ name, mount_path, sub_path?, read_only?, secret?, config_map?, persistent_volume_claim?, mode? }`, additive to the inherited ones |
| `cpu_requests` | `50m` | CPU request for the tick container |
| `memory_requests` | `128Mi` | Memory request for the tick container |
| `memory_limits` | `512Mi` | Memory limit (`null` renders none) |

Outputs: `cron_job_name`, `schedule`.

## HA & placement

Not applicable: each tick is a one-shot, single-pod Job.
