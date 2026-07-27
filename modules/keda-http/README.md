# `keda-http`

Per-app wiring for **request-based scale-to-zero** of a web process, via the
[KEDA HTTP add-on](https://github.com/kedacore/http-add-on): the web scales
`0..N` on incoming HTTP concurrency, and the shared interceptor proxy buffers
requests during a cold start, so an idle environment costs ~nothing.

You normally **don't use this submodule directly** — set
[`formation.<web>.scale_to_zero`](../../README.md#request-based-scale-to-zero-keda-http-add-on)
on the root module, which instantiates it with the web process's own name,
Service, port and ALB. It has its own README because it renders the objects and
carries the add-on's caveats.

**Requires** the KEDA HTTP add-on **control plane** installed cluster-wide
(operator + interceptor proxy + external scaler + the `http.keda.sh` CRDs), in
`interceptor_namespace` (default `keda`). This submodule emits only the per-app
objects.

## What it renders

1. **`InterceptorRoute`** (`http.keda.sh/v1beta1`), in the app namespace —
   routes `host` to the web Service with a concurrency scaling metric and
   per-route `timeouts` (readiness/request).
2. **`ScaledObject`** (`keda.sh/v1alpha1`, `external-push` trigger), in the app
   namespace — owns the `0..N` scaling of the web Deployment, driven by the
   add-on's external scaler.
3. **`Ingress`** in `interceptor_namespace` — puts `host` on the app's shared
   ALB pointing at the interceptor proxy Service. The proxy lives in that
   namespace and the ALB controller requires the Ingress in the backend
   Service's namespace, so it cannot live in the app namespace.

## Usage

```hcl
# What the root module does when a web process sets scale_to_zero:
module "keda_http" {
  source  = "fabn/formation/kubernetes//modules/keda-http"
  version = "~> 0.10"

  name            = "web"
  namespace       = "myapp-staging"
  host            = "myapp-staging.example.com"
  target_service  = "myapp" # the web Service (= the web Deployment name)
  target_port     = 3000
  deployment_name = "myapp"

  max_replicas = 3
  alb          = { load_balancer_name = "shared-external" }
}
```

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `name` | — | InterceptorRoute name + the trigger's `interceptorRoute` reference (the web process key, e.g. `web`) |
| `namespace` | — | App namespace holding the target Deployment/Service, the InterceptorRoute and the ScaledObject |
| `host` | — | Public host routed through the interceptor |
| `target_service` | — | Web Service the interceptor forwards ready traffic to |
| `target_port` | — | Web Service port |
| `deployment_name` | — | Web Deployment the ScaledObject scales `0..N` |
| `min_replicas` | `0` | Minimum replicas (`0` = scale to zero; production keeps `>= 1`) |
| `max_replicas` | `1` | Maximum replicas |
| `concurrency_target` | `100` | Target concurrent requests per replica — the scaling metric |
| `cooldown_period` | `60` | Seconds idle before scaling back toward `min_replicas` |
| `readiness_timeout` | `"90s"` | How long the interceptor buffers a request while the backend scales from zero (per-route; add-on >= 0.15) |
| `request_timeout` | `"120s"` | Total request lifecycle timeout |
| `interceptor_namespace` | `"keda"` | Namespace where the add-on control plane is installed |
| `ingress_class_name` | `null` | IngressClass for the interceptor Ingress (`null` = cluster default, the ALB class on EKS Auto Mode) |
| `alb` | `null` | ALB wiring `{ load_balancer_name, listen_ports }`; `null` renders a plain (non-ALB) Ingress |

## Outputs

| Name | Description |
| --- | --- |
| `interceptor_route_name` | Name of the InterceptorRoute (app namespace) |
| `scaled_object_name` | Name of the external-push ScaledObject (`<deployment>-http`, app namespace) |
| `ingress_name` | Name of the interceptor Ingress (`<namespace>-http-interceptor`, interceptor namespace) |

## Notes

**No `group.name` annotation.** The interceptor Ingress joins the app's shared
ALB via the `IngressClass` + `load_balancer_name` only. EKS Auto Mode groups
Ingresses by `IngressClassParams`, and the
`alb.ingress.kubernetes.io/group.name` annotation is not supported there — so
setting it would split the ALB instead of joining it. The Ingress health-checks
the interceptor proxy on its admin port (`/livez`), so the ALB target stays
healthy regardless of any app's scale state.

**The web Service stays.** `scale_to_zero` suppresses the web process's *own*
Ingress (the host is served through the interceptor), but keeps its ClusterIP
Service — it is what the interceptor forwards to once the backend is up.

**Plan-time CRD dependency.** The InterceptorRoute and ScaledObject are rendered
with `kubernetes_manifest`, which resolves the CRD schema against the live
cluster at plan time — the same contract as the operator-backed addons. The
`http.keda.sh` / `keda.sh` CRDs must exist (they ship with the add-on control
plane and KEDA), or plan fails.

Reference: [KEDA HTTP add-on](https://github.com/kedacore/http-add-on).
