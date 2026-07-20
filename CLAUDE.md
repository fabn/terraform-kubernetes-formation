# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Terraform module for deploying Heroku-style application stacks on Kubernetes.
Published on Terraform Registry as `fabn/formation/kubernetes`.

The core takes a Heroku-Procfile-like `formation` map; each entry becomes one
`fabn/workload/kubernetes` instance. At most one entry sets `web = true`
(enforced by validation) and gets Service + Ingress + probes; every other
process runs headless. Worker-only stacks simply omit the web entry. The
module also creates a shared Secret/ConfigMap (content-hash named), a
generated `SECRET_KEY_BASE` and a registry pull secret. It is framework-neutral: nothing injects `RAILS_ENV` — callers pass it
via `env`.

Backing services are **addons** under `modules/`: independent submodules with
a uniform contract — outputs `env` (plaintext config) and `sensitive_env`
(credentials) merged into the stack by the caller, Heroku-addon style. New
services are new addon modules, never new toggles in the core.

One-off tasks (`heroku run` / release-phase equivalent) are the `run`
submodule: a Job that inherits envFrom / pull secrets / service account from a
live Deployment while the image and command stay explicit inputs.

## Contribution Conventions

- **English everywhere** — code, comments, commit messages, issues, PRs.
- **PRs**: use `Closes #<n>` when the PR addresses a tracked issue; keep the
  description coherent with what is actually implemented — if the diff
  changes during review, update the description before merging.

## Commands

### Terraform Operations

```bash
# Format check (recursive)
terraform fmt -check -recursive

# Format files
terraform fmt -recursive

# Initialize module
terraform init

# Validate terraform
terraform validate

# Run unit tests (mocked providers)
terraform test

# Run specific test
terraform test -filter=tests/formation.tftest.hcl

# Run E2E tests (requires a Kind cluster, see .github/kind-config.yml)
terraform -chdir=e2e init
terraform -chdir=e2e test
```

### Git Hooks (Lefthook)

```bash
# Install hooks
lefthook install

# Run all validations manually
lefthook run validate-all

# Pre-commit runs: actionlint, terraform fmt (with auto-fix)
# Pre-push runs: actionlint, terraform fmt -check, terraform validate
```

## Architecture

### Module Structure

```
.
├── main.tf              # Namespace, shared Secret/ConfigMap, registry pull secret
├── workloads.tf         # One fabn/workload/kubernetes instance per formation entry
├── variables.tf         # Input variables (formation map + app-level config)
├── outputs.tf           # Output values
├── versions.tf          # Provider requirements
│
├── modules/             # Submodules
│   ├── postgres/        # Bitnami PostgreSQL chart + generated password
│   ├── redis/           # Bitnami Redis chart, no auth, AOF + noeviction
│   ├── memcached/       # memcached on fabn/workload/kubernetes, ephemeral
│   ├── addons/          # Wrapper: sizes postgres/redis/memcached behind one map
│   └── run/             # One-off Job (heroku run / release phase equivalent)
│
├── examples/            # Usage examples
│   ├── minimal/
│   └── full-featured/
│
├── tests/               # Unit tests (mocked providers)
└── e2e/                 # E2E harness + tests (real Kind cluster)
```

### Key Design Decisions

- **Web vs headless**: the web process keeps the bare app name (Heroku-like:
  `myapp` + `myapp-worker`) and gets Service/Ingress/probes; other processes
  get `service_type = null`.
- **Addons are separate modules, not core toggles**: addons have different
  providers and lifecycles (helm must not leak into the core), and
  per-environment addon swaps stay invisible to the core. The `addons`
  wrapper sizes them behind one Heroku-like map and mirrors the managed
  companion `fabn/addons/aws` (same map shape + `env`/`sensitive_env`
  contract), so a stack swaps in-cluster for cloud by switching module source.
- **Bitnami legacy images**: postgres/redis values files pin
  `bitnamilegacy/*` repositories with `global.security.allowInsecureImages`
  (chart >= 15.x rejects unrecognised registries, bitnami/charts#30850).
- **`create_namespace = false`** is for composition roots where addons must
  exist in the namespace before the formation's inputs are computable.

## Testing

- `tests/` — unit tests with `mock_provider`, no cluster needed. Assertions on
  planned/applied values (naming, validation rules, addon env contracts).
- `e2e/` — a root module wrapping the formation + helper modules
  (ingress-controller, http, namespace) that runs against a Kind cluster with
  host ports 80/443 mapped (`.github/kind-config.yml`). The http helper
  asserts real request/response behaviour through ingress-nginx.

## CI/CD

- **GitHub Actions** — unit tests + E2E with Kind clusters
- **Release Drafter** — automatic release notes generation; registry releases
  are git tags (`v*`)
- **Dependabot** — dependency updates

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and add tests
4. Run `lefthook run validate-all`
5. Submit a pull request
