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
  - **exactly one category** label — `enhancement` (or `feature`), `bug` (`fix`,
    `bugfix`), `documentation` (`docs`), `dependencies`, `chore`. A PR is listed
    under **every** category it matches, so two category labels means the same
    entry printed twice in the release notes. Pick by what the change *is*:
    `documentation` for docs-only work, `chore` for what touches neither the
    module's contract nor its docs (workflow/tooling bumps, repo config,
    test-only work), the contract categories otherwise — a feature that also
    updates its README is still `enhancement`.
  - The autolabeler guesses from branch and title patterns only (`docs/*` ⇒
    `documentation`, `chore/*` ⇒ `chore`, `fix/*` or a title matching `/fix/i` ⇒
    `bug`, `feature/*` ⇒ `enhancement`) — author intent, not an inference from
    the diff. It deliberately has no `files:` rule: a `*.md` ⇒ `chore` rule used
    to fire on any PR touching a README, which with per-module READMEs is nearly
    every feature PR, and the second category duplicated it in the notes. Still
    check the labels by hand before merging; a mismatched branch name is enough
    to mislabel.
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
- **An HA-capable submodule's README carries a `#### Production block`**: every
  knob a production deployment sets, as one copy-pasteable HCL block, then two
  short lists — what is already right by default (so its absence from the block is
  deliberate) and what is left undefaulted because it needs cluster knowledge (a
  zone label key, a capacity-type label, a bucket). Defaults stay dev-cluster-safe;
  this is where the production opinion lives, instead of a `production_mode` flag
  that would add a second configuration axis to every module (see #41).

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
  `DoNotSchedule` is only the equal of `required` when paired with `min_domains`:
  skew is computed over *eligible* domains, so one eligible node means one domain,
  skew `0`, and the constraint permits everything it was meant to forbid — silently.
  A module whose **only** host-spreading lever is the constraints (`dragonfly`)
  must say so where the value is documented; one that models real anti-affinity
  (`postgres-cnpg`, the workload processes) is unaffected, and uses the
  constraints for zone spreading only, where `ScheduleAnyway` makes the question
  moot.
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
│   ├── keda-http/       # Per-app KEDA HTTP scale-to-zero for the web process
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
