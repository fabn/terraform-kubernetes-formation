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
- **Labels drive the release notes and the version bump**
  (`.github/release-drafter.yml`), so every PR carries two:
  - one **version** label — `major` / `minor` / `patch`. There is no default at
    review time: an unlabelled PR silently resolves to `patch`, which is wrong
    for anything that adds an input or an addon. New inputs/modules ⇒ `minor`.
  - one **category** label — `enhancement` (or `feature`), `bug` (`fix`,
    `bugfix`), `chore`, `dependencies`. First matching category wins, so don't
    stack two: a feature PR labelled `chore` lands in the wrong section.
  - The autolabeler only guesses from paths and branch/title patterns (`*.md` ⇒
    `chore`, `fix/*` or a title matching `/fix/i` ⇒ `bug`, `feature/*` ⇒
    `enhancement`), so a docs-touching feature PR arrives mislabelled — fix it
    by hand rather than trusting it.
- **Dependabot PRs** arrive with `dependencies` only (set in
  `.github/dependabot.yml`), so they resolve to the default `patch`. That is
  correct for an ordinary provider/chart bump, but **add a version label by hand**
  when the bump changes this module's own contract: a provider major, a raised
  `required_version`, or a chart bump that changes rendered resources ⇒ `minor`
  (`major` if consumers must change their code). Terraform updates come as one
  grouped PR across every directory (`/`, `/modules/*`, `/e2e`, `/e2e/modules/*`,
  `/examples/*`) because splitting them makes `terraform init` fail on
  conflicting constraints — so judge the label on the widest change in the group.
- **Every submodule has its own README** (`modules/<name>/README.md`): what it
  is, the `env` / `sensitive_env` contract, its inputs, its HA & placement
  surface, caveats, a usage example. The root `README.md` stays a TL;DR — a
  one-line-per-addon table linking out — so module docs live next to the code
  they describe and the root file doesn't drift.

### HA & placement surface

Any submodule that runs a **multi-instance, stateful or failover-capable**
workload must expose the full availability surface, not a subset. It is what
makes a module usable in production, and retrofitting it later is a breaking
change to somebody's plan:

- **PodDisruptionBudget** — check what the operator does on its own first: CNPG
  manages the PDBs (so the knob is `enable_pdb`, a way to turn them *off* for
  dev), the Dragonfly operator creates one with `maxUnavailable = 1` above one
  replica (so the knob customises `spec.pdb`), mariadb-operator creates none (so
  the knob is a full `pod_disruption_budget` passthrough). Without one, a node
  drain can take every instance at once.
- **Spread across failure domains** — either pod anti-affinity or topology spread
  constraints, whichever the CRD models, with the **hard vs soft choice exposed**
  (`required` / `DoNotSchedule` fits real clusters, `preferred` /
  `ScheduleAnyway` fits single-node and dev) and the topology key configurable
  (node vs zone). Where the CRD offers both, expose both: an operator's
  anti-affinity shorthand usually spreads on one key only, so zone spreading
  still needs the constraints.
- **Node affinity** — set-based `required` + `preferred` match expressions, the
  **same object shape as the formation web process** (`key` / `operator` /
  `values`, `weight` on preferred, operators validated against
  `In/NotIn/Exists/DoesNotExist/Gt/Lt`). This is what pins a primary or master to
  on-demand capacity (`karpenter.sh/capacity-type In [on-demand]`) — a Spot
  reclaim otherwise costs a failover, or the whole dataset for an in-memory
  store. Not expressible with a plain `nodeSelector`, so `node_selector` alone
  does not satisfy this.
- Plus the small companions that make placement usable: `node_selector`,
  `tolerations`, `priority_class_name`, and a replica/instance count.

Render each of these **only when set**, so enabling nothing leaves the produced
manifest byte-for-byte unchanged, and cover every knob in the module's tests
(default-absent, rendered, invalid-value-rejected). Mirror a CRD's own
mutual-exclusion rules in a variable `validation` (e.g. Dragonfly's `spec.pdb`
rejects `minAvailable` + `maxUnavailable` together) so the failure lands at plan
time instead of mid-apply.

Read the upstream Go types before adding a knob: `kubernetes_manifest` sends the
manifest as-is, so a field the CRD doesn't define fails only against a real
cluster — the mocked unit tests can't catch it. Note where the field actually
lives, too: CNPG's `topologySpreadConstraints` is cluster-level while its
anti-affinity knobs sit under `spec.affinity`, and mariadb-operator keeps
`nodeAffinity` and its `antiAffinityEnabled` shorthand under the same
`spec.affinity` key (so they must be merged, not overwritten).

Single-instance-by-construction addons (the Bitnami chart wrappers, `memcached`,
the `run` Job) are exempt — but their README says so explicitly, and points at
the HA-capable alternative, instead of leaving the omission to be guessed.

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
├── modules/             # Submodules, each with its own README.md
│   ├── postgres/        # Bitnami PostgreSQL chart + generated password
│   ├── postgres-cnpg/   # CloudNativePG Cluster: HA primary + replicas, PITR to S3
│   ├── mariadb/         # mariadb-operator MariaDB: HA replication, S3 backups
│   ├── redis/           # Bitnami Redis chart, no auth, AOF + noeviction
│   ├── dragonfly/       # Operator-backed Dragonfly: HA master + replica, cache mode
│   ├── memcached/       # memcached on fabn/workload/kubernetes, ephemeral
│   ├── addons/          # Wrapper: sizes postgres/redis/memcached behind one map
│   └── run/             # One-off Job (heroku run / release phase equivalent)
│
├── examples/            # Usage examples
│   ├── minimal/
│   ├── full-featured/
│   ├── postgres-cnpg/
│   ├── mariadb/
│   └── dragonfly/
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

- **GitHub Actions** — unit tests + E2E with Kind clusters. The E2E workflow
  is `paths-ignore`d for docs/examples-only changes (`**.md`, `examples/**`),
  which the harness never exercises; `[skip ci]` in a commit message skips it
  too. Both fmt/validate still run via the unit-test workflows.
- **Release Drafter** — automatic release notes generation; registry releases
  are git tags (`v*`)
- **Dependabot** — dependency updates

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and add tests
4. Run `lefthook run validate-all`
5. Submit a pull request
