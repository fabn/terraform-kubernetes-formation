# `run` submodule

The `heroku run` / release-phase equivalent: a `kubernetes_job_v1` that runs a
one-shot command (DB migrations, seed loading, arbitrary tasks) in the same
environment as a deployed process. Instead of re-declaring that environment, the Job
reads the live Deployment's pod template and inherits its `envFrom` (which is how it
picks up the content-hash-suffixed Secret/ConfigMap names — addon connection vars
included), `imagePullSecrets`, `serviceAccountName` and the **volumes its container
mounts**.

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
| `pod_labels` | `{}` | Extra labels on the run's pod only — for pod-level admission webhooks |
| `inherit_volumes` | `true` | Inherit the volumes the Deployment's container mounts (see [Volumes](#volumes)) |
| `volumes` | `[]` | Extra volumes: `{ name, mount_path, sub_path?, read_only?, secret?, config_map?, persistent_volume_claim?, mode? }`, additive to the inherited ones |
| `backoff_limit` | `0` | One-shot: migrations are rarely safe to blindly re-run |
| `ttl_seconds_after_finished` | `600` | Finished-Job garbage collection |
| `wait_for_completion` | `true` | `terraform apply` blocks until the run finishes and fails when it does — the natural gate for release pipelines |
| `timeout` | `10m` | Apply-side wait budget |
| `active_deadline_seconds` | `null` | Cluster-side deadline (unbounded by default) |

Output: `job_name`.

## Volumes

Every volume the Deployment's container mounts is mounted into the Job's pod —
into the init container as well, which shares the main container's environment —
at the same path, with the same `subPath` and `readOnly` (a claim the pod itself
declares read-only stays read-only). This is on by default, and
`inherit_volumes = false` is the way out.

**Why a default and not an opt-in.** The two failure modes are not symmetric:

- A run *without* the process's volume fails silently. The mount path exists
  inside the image anyway, so a read finds an empty directory and a write lands
  in the container's ephemeral layer and is discarded when the run ends. Nothing
  errors, so nothing surfaces until someone goes looking.
- A run inheriting a volume it cannot mount leaves the pod `Pending`, which is
  visible in seconds.

It is also the category the rest of this module already works in: `envFrom` and
the service account are the environment of the *process*, and so is its storage
— the caller owns the claim, but it owns the Secret and the ConfigMap too, and
those are inherited without being asked for. And it is the `heroku run`
behaviour the module is modelled on: an inherited `emptyDir` becoming a fresh
per-run directory is the ephemeral dyno filesystem, correctly reproduced.

What is inherited, precisely:

- Only volumes the process's **own container** mounts — a pod volume nothing
  mounts carries no path to reproduce it at.
- `secret`, `configMap`, `persistentVolumeClaim` and `emptyDir` sources; an
  `emptyDir` keeps its `medium` and `sizeLimit`, so a tmpfs stays a tmpfs.
  Anything else (a `hostPath`, a `csi` volume) **fails the plan** with the
  volume named, rather than being dropped — a silently missing mount is the
  defect this inheritance exists to close. Set `inherit_volumes = false` and
  declare what the run needs through `volumes`.
- Fields are read by name, not copied through: the pod template comes back from
  the API defaulted (`mountPropagation: "None"` on every mount) and
  `defaultMode` comes back as the decimal `420`, which is rendered back as
  `"0644"`.

`volumes` mounts something the run needs and the deployed process does not. It
is **additive** to what was inherited, and an entry whose `name` matches an
inherited volume **replaces** it:

```hcl
module "import" {
  source  = "fabn/formation/kubernetes//modules/run"
  version = "~> 0.14"

  namespace  = module.app.namespace
  deployment = module.app.web_deployment_name
  image      = "ghcr.io/acme/myapp:1.2.3"

  command = ["/bin/bash", "-lc", "bin/rails data:import"]

  # Whatever the web process mounts is already there; this only adds the
  # scratch space the import needs on top of it.
  volumes = [{
    name                    = "import"
    mount_path              = "/import"
    persistent_volume_claim = "myapp-import"
  }]

  depends_on = [module.app]
}
```

Each entry sets at most one of `secret`, `config_map`,
`persistent_volume_claim` (validated at plan time); setting none renders an
`emptyDir`. Claims are never created here — a claim outlives the process that
mounts it, and a module owning it would destroy data on a rename.

A `ReadWriteOnce` claim is the one case worth a thought: a run inheriting one
can sit `Pending` while the deployed pod holds it on another node. That is the
loud failure of the two, and `inherit_volumes = false` is there for it.

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

### Extra pod labels (`pod_labels`)

`pod_labels` is merged onto the **pod template** only, not onto the Job. That is
the level a mutating admission webhook works at: it sees the Pod at create time,
so a label sitting on the Job never reaches the object being admitted — with
Datadog's `admission.datadoghq.com/enabled = "true"`, for instance, the webhook
mounts the agent's socket and injects `DD_TRACE_AGENT_URL` and the UST tags into
the run.

The module's four `app.kubernetes.io/*` labels are merged last and always win,
so nothing passed here can put the Deployment's identity back on a run pod (see
above for what that would break). Same input, same rule, as in
[`cron`](../cron).

## Notes

Because a failed run aborts the apply immediately, gate on backing-service readiness
with `init_command` rather than letting the command itself fail on a database that is
still starting.

`restart_policy` is `Never` and the Job is created with `generate_name`, so runs
never collide and a retry is a new Job — never a silent in-place restart.

## HA & placement

Not applicable: a Job is a one-shot, single-pod run. Storage is inherited from the
Deployment's pod template together with the rest of its environment (see
[Volumes](#volumes)); placement knobs — node affinity, tolerations, node selector
— are not, so a run lands wherever the scheduler puts it.
