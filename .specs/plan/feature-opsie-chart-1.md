---
goal: Create the `opsie` Helm chart in the helm-charts repository (MSSQL first, Valkey required, three deployment topologies)
version: 1.0
date_created: 2026-10-11
last_updated: 2026-10-11
owner: Opsie platform team
status: 'In Progress'
tags: [feature, helm, chart, opsie, mssql, valkey, argocd]
---

# Introduction

![Status: In Progress](https://img.shields.io/badge/status-In%20Progress-yellow)

This plan creates `charts/opsie` in the `AB-Lindex/helm-charts` repository. The master design is the draft `.specs/drafts/helm-chart.md` in the `AB-Lindex/opsie` repository; where this plan and the draft differ, the draft wins and this plan is corrected. The chart deploys the Opsie application with an external MSSQL (or PostgreSQL) database and a required Valkey-compatible service (bundled sub-chart or external), in one of three topologies: `all-in-one`, `split-ingest`, `split-all`.

Phases 1 to 8 are implemented on the branch `feature/opsie-chart`; phases 9 and 10 need a cluster, a pullable image and a merge decision. See section 9.

**Warning:** this repository has no `/.specs/PRD.md`. The draft named above acts as the requirements document. Create a PRD or link the draft from the chart README if a PRD is wanted later.

## 1. Requirements & Constraints

- **REQ-001**: The chart is `charts/opsie`, chart name `opsie`, `apiVersion: v2`, `type: application`, first `version: 0.1.0`, `appVersion: "v0"`.
- **REQ-002**: `topology` accepts exactly `all-in-one` (default), `split-ingest`, `split-all`. Parts and module mapping are in section 2.0.
- **REQ-003**: Valkey is required in every topology: exactly one of `valkey.enabled=true` (sub-chart) or `redis.enabled=true` (external) must be set.
- **REQ-004**: `database.type` is `mssql` (default) or `postgres`. `memory`, `DEVMODE` and `ENABLE_MOCK_DATA` are never rendered.
- **REQ-005**: One `Deployment` and one `ClusterIP` `Service` per part, including `processor`. Names: `<base>` for `all`, `<base>-ingest`, `<base>-processor`, `<base>-app`. `<base>` is `fullnameOverride` (default `opsie`); an empty `fullnameOverride` falls back to `<release>-<chart>`.
- **REQ-006**: Every Deployment uses `RollingUpdate` with `maxSurge: 1`, `maxUnavailable: 0`, configurable through `strategy.rollingUpdate`.
- **REQ-007**: Topology spread is on by default for every part, built from `topologySpread.constraints` (default: `topologyKey: agentpool`, `maxSkew: 1`, `ScheduleAnyway`). The chart fills `labelSelector` with the part's own selector labels unless the user-supplied constraint already has one. A part's own `topologySpreadConstraints` replaces the shared list for that part.
- **REQ-008**: `PodDisruptionBudget` per part, `podDisruptionBudget.enabled: auto|true|false`; `auto` renders it only when the part's effective replica count is 2 or more. Default `maxUnavailable: 1`.
- **REQ-009**: MSSQL migration through `database.migrate.mode`: `hook` (default), `initContainer`, `none`. Image and tag are identical to the Deployments.
- **REQ-010**: External routing through `ingresses[]` and `httpRoutes[]` (both lists, empty by default, any number of entries). In split topologies every entry routes the prefix `/api/events` to `ingest` and everything else to `app`.
- **REQ-011**: TLS modes `none`, `proxy`, `native` as specified in the draft section "Proposal / Values structure" (design point "TLS modes").
- **REQ-012**: `ServiceMonitor` (off by default) selects every Service of the release and scrapes `/metrics` on the `http` port over plain HTTP.
- **REQ-013**: `extraObjects` renders arbitrary manifests (maps or strings) through `tpl`.
- **REQ-014**: The default OIDC redirect URL is `https://<first host>/api/auth/callback` taken from the first `ingresses` entry with a host, else the first `httpRoutes` entry with a hostname. The callback path `/api/auth/callback` is verified in `backend/internal/auth/routes.go` in the Opsie repository.
- **SEC-001**: The chart contains no `Secret` template and no value that holds a secret. Every secret input is an existing Secret referenced by name (`existingSecret`) with configurable keys.
- **SEC-002**: Containers run as uid/gid 1001, `allowPrivilegeEscalation: false`, all capabilities dropped. `readOnlyRootFilesystem` stays unset until verified (see RISK-006).
- **SEC-003**: Secrets are injected only into the parts that use them (section 2.0 matrix). `DB_CONNECTION_STRING` is always `secretKeyRef`, never in the ConfigMap or in rendered values.
- **CON-001**: Release automation (`.github/workflows/release.yml`, chart-releaser) publishes on every push to `main` when `Chart.yaml` `version` has no release. Therefore all work happens on a branch and is merged to `main` only after Phase 9 passes.
- **CON-002**: The Valkey dependency is the upstream `valkey` chart from `https://valkey.io/valkey-helm/` (classic, non-OCI repository). No Bitnami chart or image is used anywhere.
- **CON-003**: The public image address is unknown. `image.repository` defaults to `TBD` and `image.tag` to `v0`; rendering fails while the repository is `TBD`.
- **CON-004**: The Opsie application has no `/metrics` endpoint yet; it is an application prerequisite (DEP-002). Chart work does not wait for it, only the end-to-end check does.
- **CON-005**: MSSQL authentication is SQL authentication only; the chart treats the connection string as opaque.
- **GUD-001**: Validation errors are collected and reported in one `fail` call, each stating what is wrong, the value path, the offending value and what to do.
- **GUD-002**: Every new or renamed value updates `values.yaml`, `values.schema.json`, `_validate.tpl` (if cross-value) and its test in the same change.
- **GUD-003**: Follow the `etcd-backup` layout conventions (`Chart.yaml`, `README.md`, `values.yaml`, `templates/`).
- **PAT-001**: One helper per concept in `_helpers.tpl`; names, labels, image, Redis address and per-part settings are each built in exactly one place.
- **PAT-002**: Every template file renders nothing (empty output) when its feature is off, so `helm template` output is minimal for the default topology.

Update the status tag of each task as the plan progresses (`[📋 Planned]` to `[⏳ In Progress]` to `[✅ Completed: YYYY-MM-DD]`), and set the front matter `status` accordingly.

## 1.1. Repository Context

- **Repository Type**: Multi-chart repository (one chart per `charts/<name>/`); not a product repository.
- **PRD Location**: none in this repository. Master design: `AB-Lindex/opsie` `/.specs/drafts/helm-chart.md` (companion draft for later work: `/.specs/drafts/mssql-entra-auth.md`).
- **Related Features**: `charts/etcd-backup` (layout example); Opsie docs `docs/configuration.md`, `docs/deployment.md`, `docs/mssql-migration.md`, `docs/database-setup.md`.
- **Technology Stack**: Helm 3 (Go templates, JSON schema), helm-unittest, GitHub Actions, chart-releaser, Kubernetes (Deployment, Job, Ingress, Gateway API HTTPRoute, Prometheus Operator ServiceMonitor), Valkey sub-chart `valkey` `0.12.0` (appVersion 9.1.2; confirm in TASK-001 and TASK-050).
- **Cross-Product Dependencies**: the chart's contract (environment variable names, modules, `/app/mssql-migrate`, ports 8080/8443) is defined in the Opsie repository. A change of any of them there requires a chart change.

## 2. Implementation Steps

### 2.0. Reference tables

Environment-variable and part contract used by the tasks below.

Part to module mapping (`MODULES` / `NOT_MODULES` are set on the container; `all` sets neither):

| Topology | Part | Environment | Replicas default |
| --- | --- | --- | --- |
| `all-in-one` | `all` | none | 1 |
| `split-ingest` | `ingest` | `MODULES=ingestion` | 1 |
| `split-ingest` | `app` | `NOT_MODULES=ingestion` | 1 |
| `split-all` | `ingest` | `MODULES=ingestion` | 2 |
| `split-all` | `processor` | `MODULES=alert-processing` | 2 |
| `split-all` | `app` | `NOT_MODULES=ingestion,alert-processing` | 2 |

Environment per part (`yes` = rendered, `-` = not rendered). The common ConfigMap `<base>-config` holds the non-secret variables marked "ConfigMap"; everything else is rendered inline in the container by the helper `opsie.partEnv`.

| Variable | Source | all | ingest | processor | app |
| --- | --- | --- | --- | --- | --- |
| `DB_TYPE` | ConfigMap | yes | yes | yes | yes |
| `DB_CONNECTION_STRING` | `secretKeyRef` `database.existingSecret` / `existingSecretKey` | yes | yes | yes | yes |
| `USE_REDIS=true`, `REDIS_ADDR`, `REDIS_DB` | ConfigMap | yes | yes | yes | yes |
| `REDIS_PASSWORD` | `secretKeyRef` (valkey or redis source) | yes | yes | yes | yes |
| `ALERT_REOPEN_WINDOW`, `ALERT_ZOMBIE_THRESHOLD` (only when set) | ConfigMap | yes | yes | yes | yes |
| `MODULES` / `NOT_MODULES` | inline | - | yes | yes | yes |
| `JWT_SECRET`, `JWT_SECRET_NEXT` (optional), `JWT_SECRET_PREVIOUS` (optional) | `secretKeyRef` `auth.jwt.existingSecret`, keys `jwt-secret`, `jwt-secret-next`, `jwt-secret-previous` | yes | - | - | yes |
| `OIDC_ISSUER`, `OIDC_REDIRECT_URL`, `OIDC_SCOPES` | inline | yes | - | - | yes |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | `secretKeyRef` `auth.oidc.existingSecret`, keys `client-id`, `client-secret` | yes | - | - | yes |
| `SESSION_CACHE_TTL` (only when set) | inline | yes | - | - | yes |
| `THEMES_PATH=/app/themes/custom` and ConfigMap volume | inline, `themes.existingConfigMap` | yes | - | - | yes |
| `ADMIN_EMAIL_FILE` and ConfigMap volume | inline, `auth.adminEmail.existingConfigMap` | yes | - | - | yes |
| `TRUST_FORWARDED_HEADERS`, `HTTPS_REDIRECT`, `HSTS_MAX_AGE`, `TLS_CERT_FILE`, `TLS_KEY_FILE`, `TLS_PORT` and TLS Secret volume | inline, per `tls.mode` | yes | yes | - | yes |

Rows with `-` for `app` apply to `app` in both split topologies. `extraEnv` and `extraEnvFrom` (global and per part) are appended last on every part.

Probes (all parts, `http` port): liveness `GET /healthz`, readiness `GET /readyz`. Ports: container `http` 8080 always; `https` 8443 only when `tls.mode=native` on parts that serve traffic.

### Implementation Phase 1: Scaffold, tooling and CI

- **GOAL-001**: A lint-clean, empty-bodied `charts/opsie` that packages with its Valkey dependency, plus CI that lints and tests every chart change and a release workflow that can fetch the dependency.

- **TASK-001**: Create `charts/opsie/Chart.yaml` `[✅ Completed: 2026-10-11]`
  - Fields: `apiVersion: v2`, `name: opsie`, `description`, `type: application`, `version: 0.1.0`, `appVersion: "v0"`, `kubeVersion: ">=1.35.0-0"`, `home: https://github.com/AB-Lindex/helm-charts`, `sources` (this repository and `https://github.com/AB-Lindex/opsie`).
  - `dependencies`: `name: valkey`, `version: 0.12.0` (latest at plan date; use the latest published `valkey` chart version at implementation time and record it), `repository: https://valkey.io/valkey-helm/`, `condition: valkey.enabled`.
  - Run `helm dependency update charts/opsie` and commit `charts/opsie/Chart.lock`. The downloaded `charts/opsie/charts/*.tgz` is ignored by the existing `*.tgz` entry in `.gitignore`.

- **TASK-002**: Create `charts/opsie/.helmignore` `[✅ Completed: 2026-10-11]`
  - Exclude `tests/`, `ci/`, `.specs/`, editor files, so the published package contains only chart content.

- **TASK-003**: Update `.github/workflows/release.yml` `[✅ Completed: 2026-10-11]`
  - Add a step before "Run chart-releaser": `helm repo add valkey https://valkey.io/valkey-helm/`. The step name is `Add chart dependency repositories`.
  - Keep `chart-releaser-action@v1.6.0` and its `CR_TOKEN` unchanged.
  - Dependencies: TASK-001.

- **TASK-004**: Create `.github/workflows/ci.yml` (trigger `pull_request` on paths `charts/**` and `.github/workflows/**`) `[✅ Completed: 2026-10-11]`
  - Steps: checkout (`fetch-depth: 0`), `azure/setup-helm`, `helm repo add valkey https://valkey.io/valkey-helm/`, `helm dependency build charts/opsie`, install the helm-unittest plugin pinned to a version, `helm lint charts/opsie -f charts/opsie/ci/<fixture>` for each fixture in TASK-005, `helm unittest charts/opsie`, `bash charts/opsie/tests/schema-test.sh`, `helm template --kube-version 1.35.0` of each fixture piped to `kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.35.0`, and `helm/chart-testing-action` `ct lint --charts charts/opsie` with a `ct.yaml` at the repository root (`chart-dirs: [charts]`, `chart-repos: [valkey=https://valkey.io/valkey-helm/]`, `validate-maintainers: false`).
  - The kind install step is not part of this workflow (Phase 9, manual) because no public image exists.

- **TASK-005**: Create test fixtures in `charts/opsie/ci/` `[✅ Completed: 2026-10-11]`
  - Files: `all-in-one-values.yaml`, `split-ingest-values.yaml`, `split-all-values.yaml`. Each sets `image.repository: example.invalid/opsie`, `image.tag: v0.0.0-test`, `topology`, `database.existingSecret: opsie-database`, `auth.jwt.existingSecret: opsie-jwt`, `valkey.enabled: true`, `valkey.auth.usersExistingSecret: opsie-valkey`.
  - These are inputs for lint, template and unit tests; they contain no secret values.

- **TASK-006**: Create `charts/opsie/tests/` scaffolding `[✅ Completed: 2026-10-11]`
  - `tests/schema-test.sh`: bash script with a helper `expect_fail <description> <expected-substring> <helm template args...>` that runs `helm template charts/opsie ...`, requires a non-zero exit and requires the substring in stderr; and `expect_ok <description> <args...>`. The script exits non-zero if any case fails and prints one line per case.
  - `tests/` holds helm-unittest suites named `<template>_test.yaml`; each suite sets `templates:` and uses the fixtures through `values:` file references or inline `set:`.

- **TASK-007**: Write and run unit tests validating TASK-001–TASK-006 `[✅ Completed: 2026-10-11]`
  - Files: `charts/opsie/tests/schema-test.sh` (cases `scaffold-*`), CI run of `helm lint`.
  - Dependencies: TASK-001, TASK-002, TASK-003, TASK-004, TASK-005, TASK-006 must be completed first.
  - Positive cases: `helm dependency build charts/opsie` succeeds and `Chart.lock` is unchanged; `helm lint charts/opsie -f charts/opsie/ci/all-in-one-values.yaml` exits 0; `helm package charts/opsie` produces `opsie-0.1.0.tgz` that contains `opsie/charts/valkey-<version>.tgz` and does not contain `tests/` or `ci/`; `actionlint` passes for both workflow files.
  - Negative cases: changing the dependency version in `Chart.yaml` without updating `Chart.lock` makes `helm dependency build` exit non-zero (check performed on a temporary copy of the chart); `expect_fail` self-test: a case that is expected to fail but succeeds makes `schema-test.sh` exit non-zero.
  - Validation criteria: all listed cases pass; the CI workflow runs green on the branch; phase is not complete until this task passes.

### Implementation Phase 2: Values, schema, helpers and validation

- **GOAL-002**: The full `values.yaml` surface, `values.schema.json`, shared helpers and a collecting `_validate.tpl`, so every invalid combination fails with a precise message before any workload template exists.

- **TASK-010**: Create `charts/opsie/values.yaml` `[✅ Completed: 2026-10-11]`
  - Content: the values outline in the draft section "Values structure (outline)", complete with comments, defaults and the commented example Secrets under `extraObjects` (names `opsie-database`, `opsie-jwt`, `opsie-oidc`, `opsie-valkey`, `opsie-redis` and their keys). Defaults: `fullnameOverride: opsie`, `image.repository: TBD`, `image.tag: v0`, `topology: all-in-one`, `topologySpread.enabled: true`, `database.type: mssql`, `database.migrate.mode: hook`, `podDisruptionBudget.enabled: auto`, `valkey.enabled: false`, `redis.enabled: false`.
  - Additions to the draft outline (see ASSUMPTION-002): `auth.sessionCacheTtl: ""`, `auth.adminEmail: {existingConfigMap: "", key: admin-emails}`, `image.pullSecrets: []`, `tls.mountPath: /app/tls`.
  - Per-part blocks under `parts.<all|ingest|processor|app>`: `replicaCount`, `resources`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints`, `annotations`, `podLabels`, `podAnnotations`, `extraEnv`.

- **TASK-011**: Create `charts/opsie/values.schema.json` (JSON Schema draft-07) `[✅ Completed: 2026-10-11]`
  - Enums: `topology`, `database.type` (`mssql`, `postgres`), `tls.mode`, `database.migrate.mode`, `podDisruptionBudget.enabled` (`auto`, `true`, `false`; boolean or string `auto`).
  - Types and bounds: `replicaCount` is empty string or integer `>= 0`; `ingresses[]` requires `name`; `httpRoutes[]` requires `name` and `parentRefs` (array, `minItems: 1`); `valkey` has `additionalProperties: true`; the schema root does not forbid unknown keys except where listed.

- **TASK-012**: Create `charts/opsie/templates/_helpers.tpl` `[✅ Completed: 2026-10-11]`
  - `opsie.name`, `opsie.fullname` (`fullnameOverride` else `<release>-<chart>`, trunc 63, trim `-`), `opsie.chart`, `opsie.labels`, `opsie.selectorLabels` (takes part; includes `app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/component: <part>`), `opsie.partFullname` (`<base>` for `all`, `<base>-<part>` otherwise), `opsie.serviceAccountName`, `opsie.image` (`image.tag` else `.Chart.AppVersion`).
  - `opsie.parts`: returns the part names for the topology (see section 2.0).
  - `opsie.replicas`: part value if set, else topology default.
  - `opsie.redisAddr`: `redis.addr` when `redis.enabled`; else `<valkey.fullnameOverride | <release>-valkey>:6379` (single place, per draft Valkey section).
  - `opsie.redisPasswordSecretRef`: name and key of the password Secret (`valkey.auth.usersExistingSecret` with key `valkey.auth.aclUsers.default.passwordKey` or `default`; or `redis.existingSecret` with `redis.existingSecretKey`).
  - `opsie.migrateServiceAccountName`, `opsie.oidcRedirectUrl` (explicit value, else derived per REQ-014, else empty).
  - Names of all service accounts derive from `opsie.fullname` only (federated-credential subject must be predictable).

- **TASK-013**: Create `charts/opsie/templates/_validate.tpl` and include it from `templates/configmap.yaml` (a template that always renders) `[✅ Completed: 2026-10-11]`
  - Helper `opsie.validate` appends every problem to a list and calls `fail` once with `opsie: <n> configuration problems:` followed by numbered lines. Message form: `<what is wrong> (<value path>). <what to do>`.
  - Rules (each has a test in TASK-019):
    - V01 `database.type` outside `mssql`, `postgres` (name `memory` explicitly in the message).
    - V02 `image.repository` equals `TBD` or is empty.
    - V03 `database.existingSecret` empty.
    - V04 `auth.jwt.existingSecret` empty.
    - V05 `topology` outside the three values.
    - V06 neither `valkey.enabled` nor `redis.enabled`.
    - V07 both `valkey.enabled` and `redis.enabled`.
    - V08 `redis.enabled` without `redis.addr` or without `redis.existingSecret`.
    - V09 `valkey.enabled` without `valkey.auth.usersExistingSecret`, or `valkey.auth.enabled` false.
    - V10 non-empty `parts.processor` values (any of `replicaCount`, `resources`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints`, `annotations`, `podLabels`, `podAnnotations`, `extraEnv`) with a topology other than `split-all`; same rule for `parts.all` outside `all-in-one` and `parts.ingest` / `parts.app` in `all-in-one`.
    - V11 `podDisruptionBudget` with both `minAvailable` and `maxUnavailable` set.
    - V12 `tls.mode=native` without `tls.existingSecret`.
    - V13 `tls.httpsRedirect=true` without `tls.mode=native`.
    - V14 `ingresses` or `httpRoutes` entry without `name`, or duplicate names within one list.
    - V15 `httpRoutes` entry without `parentRefs`.
    - V16 `httpRoutes` non-empty and `gateway.networking.k8s.io/v1` absent from `.Capabilities.APIVersions` (skipped when `.Capabilities.APIVersions` has no cluster information, i.e. `helm template` without `--api-versions`; implement with the check `has "gateway.networking.k8s.io/v1" .Capabilities.APIVersions` guarded by `.Capabilities.APIVersions | len` > the Helm built-in minimum, and document the behaviour in a template comment).
    - V17 `auth.oidc.issuer` set without `auth.oidc.existingSecret`.
    - V18 OIDC issuer set and the redirect URL neither given nor derivable (no host in any entry).
    - V19 (not an error, tested as positive behaviour): `database.migrate.mode` of `initContainer` or `hook` with `database.type=postgres` renders no migration; `hook` mode with `serviceAccount.create=false` and a non-empty `serviceAccount.name` is valid.
    - V20 `database.migrate.initContainerParts` contains a part that does not exist in the topology.
    - V21 `topologySpread.enabled=true` with an empty `topologySpread.constraints` and no part-specific list.

- **TASK-014**: Create `charts/opsie/templates/NOTES.txt` skeleton `[✅ Completed: 2026-10-11]`
  - Initial content: the placeholder-image reminder (shown when `image.tag` is `v0`) and the validation call. The final text is written in TASK-062.

- **TASK-019**: Write and run unit tests validating TASK-010–TASK-014 `[✅ Completed: 2026-10-11]`
  - Files: `charts/opsie/tests/validate_test.yaml` (helm-unittest, `failedTemplate.errorMessage` assertions on `templates/configmap.yaml`), `charts/opsie/tests/helpers_test.yaml` (helper results are asserted through rendered output once Phase 3 exists; in this phase only `fail` behaviour and rendering without error are asserted), `charts/opsie/tests/schema-test.sh` cases `schema-*`.
  - Dependencies: TASK-010, TASK-011, TASK-012, TASK-013, TASK-014 must be completed first.
  - Positive cases: each fixture in `ci/` passes `helm lint` and `helm template` with no error; rule V19 behaviours render without error; V16 is skipped under `helm template` without cluster information; an `ingresses` entry with a unique `name` passes.
  - Negative cases: one test per rule V01–V18, V20, V21 using values that break only that rule, asserting the exact message text including the value path; one test with two simultaneous problems (misspelled `topology: split-al` and no Valkey source) asserts both numbered lines are in a single error (mirrors the draft's example); schema cases in `schema-test.sh` for `topology: bad`, `database.type: memory`, `tls.mode: bad`, `database.migrate.mode: bad`, `podDisruptionBudget.enabled: maybe`, `parts.app.replicaCount: -1`, `ingresses[0]` without `name`, `httpRoutes[0]` without `parentRefs`.
  - Validation criteria: all cases pass; `helm unittest charts/opsie` and `schema-test.sh` exit 0; phase is not complete until this task passes.

### Implementation Phase 3: Workload core

- **GOAL-003**: Deployments, Services, ServiceAccount, ConfigMap and PodDisruptionBudgets render correctly for all three topologies, with spread, rollout and disruption behaviour as designed.

- **TASK-020**: Create `charts/opsie/templates/serviceaccount.yaml` `[✅ Completed: 2026-10-11]`
  - Renders when `serviceAccount.create=true`; name `opsie.serviceAccountName` (default base name), annotations from `serviceAccount.annotations`. Does not set `automountServiceAccountToken`.

- **TASK-021**: Create `charts/opsie/templates/configmap.yaml` `[✅ Completed: 2026-10-11]`
  - ConfigMap `<base>-config` with the "ConfigMap" variables from section 2.0 (`DB_TYPE`, `USE_REDIS`, `REDIS_ADDR`, `REDIS_DB`, alert settings only when non-empty). Includes `opsie.validate`.
  - Labels: `opsie.labels`.

- **TASK-022**: Create `charts/opsie/templates/deployment.yaml` `[✅ Completed: 2026-10-11]`
  - Loop over `opsie.parts`; one `Deployment` per part named `opsie.partFullname`, labels `opsie.labels` plus `app.kubernetes.io/component`, `spec.selector.matchLabels` = `opsie.selectorLabels` (component label included from the first release; selectors are immutable).
  - `replicas`: `opsie.replicas`. `strategy`: `type: RollingUpdate` and `.Values.strategy.rollingUpdate`.
  - Pod template: annotations = global `podAnnotations` + part `podAnnotations` + `checksum/config` (sha256 of the rendered ConfigMap); labels = selector labels + `podLabels` + part `podLabels`; `serviceAccountName`; `imagePullSecrets` from `image.pullSecrets`; `securityContext` = `podSecurityContext` (default `runAsNonRoot: true`, `runAsUser: 1001`, `runAsGroup: 1001`, `fsGroup: 1001`, `seccompProfile: RuntimeDefault`); container `securityContext` default `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`; `resources` = part `resources` else global `resources`; `nodeSelector`, `tolerations`, `affinity` from the part; `topologySpreadConstraints` from helper `opsie.topologySpread` (TASK-024).
  - Container `opsie`: `image` from `opsie.image`, `imagePullPolicy`, `ports` per section 2.0, probes per section 2.0, `envFrom` = ConfigMap `<base>-config` + `extraEnvFrom`, `env` = `opsie.partEnv` (TASK-030 to TASK-033) + `extraEnv` + part `extraEnv`.
  - Deployment `metadata.annotations` = `parts.<part>.annotations`.

- **TASK-023**: Create `charts/opsie/templates/service.yaml` `[✅ Completed: 2026-10-11]`
  - One `ClusterIP` Service per part, named `opsie.partFullname`, selector `opsie.selectorLabels`, port `80` named `http` to target port `http`; additional port `443` named `https` to target `https` only when `tls.mode=native` and the part serves traffic (not `processor`). Carries `opsie.labels` plus the component label (the `ServiceMonitor` selects on release labels, so the component label identifies the part per target).

- **TASK-024**: Add helper `opsie.topologySpread` in `_helpers.tpl` `[✅ Completed: 2026-10-11]`
  - Input: part. Output: nothing when `topologySpread.enabled=false`; else the part's `topologySpreadConstraints` when non-empty, else `topologySpread.constraints`; every constraint without a `labelSelector` gets `labelSelector.matchLabels` = `opsie.selectorLabels` of that part (a user-supplied `labelSelector` is kept unchanged).

- **TASK-025**: Create `charts/opsie/templates/pdb.yaml` `[✅ Completed: 2026-10-11]`
  - Per part, `policy/v1` `PodDisruptionBudget` named `opsie.partFullname`, selector `opsie.selectorLabels`. Rendered when `podDisruptionBudget.enabled` is `true`, or is `auto` and `opsie.replicas` >= 2; never when `false`. Uses `maxUnavailable` (default 1) or `minAvailable`, whichever is set (percentages pass through unchanged).

- **TASK-029**: Write and run unit tests validating TASK-020–TASK-025 `[✅ Completed: 2026-10-11]`
  - Files: `charts/opsie/tests/deployment_test.yaml`, `service_test.yaml`, `pdb_test.yaml`, `configmap_test.yaml`, `serviceaccount_test.yaml`.
  - Dependencies: TASK-020, TASK-021, TASK-022, TASK-023, TASK-024, TASK-025 must be completed first.
  - Positive cases: `all-in-one` renders one Deployment named `opsie` with no `MODULES`/`NOT_MODULES`; `split-ingest` renders `opsie-ingest` (`MODULES=ingestion`) and `opsie-app` (`NOT_MODULES=ingestion`); `split-all` renders `opsie-ingest`, `opsie-processor` (`MODULES=alert-processing`), `opsie-app` (`NOT_MODULES=ingestion,alert-processing`); default replicas 1/1/1/2/2/2 per section 2.0 and `parts.<part>.replicaCount` overrides; every Deployment has `maxSurge: 1`, `maxUnavailable: 0`, the component label in selector and template labels, uid 1001, probes on `/healthz` and `/readyz`; a Service exists for every part including `processor`; `checksum/config` changes when ConfigMap values change; default spread constraint on `agentpool` has the part's own `labelSelector` (ingest selector does not match app pods); a part-level `topologySpreadConstraints` replaces the shared list and a user `labelSelector` is preserved; `topologySpread.enabled=false` renders no constraints; PDB absent at 1 replica (`auto`), present at 2 replicas with `maxUnavailable: 1`, `all` gets a PDB when `parts.all.replicaCount: 2`, forced `true` renders at 1 replica, forced `false` renders none at 3, `minAvailable: 1` with `maxUnavailable` unset renders `minAvailable`; ServiceAccount name defaults to `opsie` and honours `serviceAccount.name`, annotations and `create: false`; `fullnameOverride: ""` yields `<release>-opsie` names; `fullnameOverride: other` yields `other-ingest` etc.
  - Negative cases: V10 (processor values in `all-in-one`) and V11 (PDB both fields) fail with the exact message; `serviceAccount.create=false` renders no ServiceAccount; no `https` Service port or container port when `tls.mode` is `none` or `proxy`; the `processor` Deployment has no `JWT_*`, `OIDC_*` or `THEMES_PATH` (completed in TASK-034); names longer than 63 characters are truncated.
  - Validation criteria: all positive and negative cases pass; `helm lint` and `kubeconform` pass for all three fixtures; phase is not complete until this task passes.

### Implementation Phase 4: Environment, secrets and TLS wiring

- **GOAL-004**: Every part receives exactly the environment, Secrets and volumes in the section 2.0 matrix, for both Valkey sources, both databases and all TLS modes.

- **TASK-030**: Implement helper `opsie.partEnv` (database, Redis) in `_helpers.tpl` `[✅ Completed: 2026-10-11]`
  - Adds `DB_CONNECTION_STRING` (`secretKeyRef` `database.existingSecret` / `database.existingSecretKey`, default key `connection-string`) and `REDIS_PASSWORD` (`secretKeyRef` from `opsie.redisPasswordSecretRef`) to every part. Adds `MODULES` / `NOT_MODULES` per section 2.0.

- **TASK-031**: Extend `opsie.partEnv` with authentication and web settings for parts that run `api` (`all`, `app`) `[✅ Completed: 2026-10-11]`
  - `JWT_SECRET` (required key `jwt-secret`), `JWT_SECRET_NEXT` and `JWT_SECRET_PREVIOUS` (`optional: true`), `OIDC_ISSUER`, `OIDC_SCOPES`, `OIDC_REDIRECT_URL` (`opsie.oidcRedirectUrl`), `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` (`secretKeyRef` `auth.oidc.existingSecret`, keys `client-id`, `client-secret`), `SESSION_CACHE_TTL` when `auth.sessionCacheTtl` is set. OIDC variables render only when `auth.oidc.issuer` is set.
  - Never set `DEVMODE`, `ENABLE_MOCK_DATA`, `JWT_ISSUER`.

- **TASK-032**: Add themes and admin-email file mounts for parts that run `api` `[✅ Completed: 2026-10-11]`
  - `themes.existingConfigMap` mounted read-only at `/app/themes/custom` with `THEMES_PATH=/app/themes/custom`; `auth.adminEmail.existingConfigMap` mounted read-only at `/app/config/admin` with `ADMIN_EMAIL_FILE=/app/config/admin/<key>`. Neither renders when unset.

- **TASK-033**: Add TLS handling for parts that serve traffic (`all`, `ingest`, `app`) `[✅ Completed: 2026-10-11]`
  - `none`: no TLS variables. `proxy`: `TRUST_FORWARDED_HEADERS=true`. `native`: mount `tls.existingSecret` (type `kubernetes.io/tls`) read-only at `tls.mountPath` (`/app/tls`), set `TLS_CERT_FILE=/app/tls/tls.crt`, `TLS_KEY_FILE=/app/tls/tls.key`, `TLS_PORT=8443`, container port `https` 8443. `HTTPS_REDIRECT=true` when `tls.httpsRedirect`; `HSTS_MAX_AGE` when `tls.hstsMaxAge` is not 0 (passed through unchanged; documented as a duration such as `720h`, so the `0` default in the draft outline is changed to the string `"0"` or left unset). Probes stay on the `http` port in all modes. `processor` receives none of these.

- **TASK-034**: Enforce least-privilege secret distribution `[✅ Completed: 2026-10-11]`
  - Two helpers decide distribution: `opsie.partRunsApi` (true for `all`, `app`) and `opsie.partServesTraffic` (true for `all`, `ingest`, `app`). `opsie.partEnv`, volumes and Service ports use only these, so no other conditional on part names exists in the templates.

- **TASK-039**: Write and run unit tests validating TASK-030–TASK-034 `[✅ Completed: 2026-10-11]`
  - Files: `charts/opsie/tests/env_test.yaml`, `tls_test.yaml`, `valkey_wiring_test.yaml`.
  - Dependencies: TASK-030, TASK-031, TASK-032, TASK-033, TASK-034 must be completed first.
  - Positive cases: `valkey.enabled=true` renders `REDIS_ADDR: opsie-valkey:6379` and `REDIS_PASSWORD` from the Secret named in `valkey.auth.usersExistingSecret` key `default`; `aclUsers.default.passwordKey: pw` switches the key to `pw`; `valkey.fullnameOverride: x` gives `x:6379`; `redis.enabled=true` renders `REDIS_ADDR` from `redis.addr`, `REDIS_DB`, and the Secret key `redis.existingSecretKey`; `USE_REDIS: "true"` in every topology; `DB_CONNECTION_STRING` is a `secretKeyRef` in all parts and the ConfigMap never contains it; `database.type: postgres` sets `DB_TYPE: postgres`; JWT, OIDC, themes and admin-email mounts appear in `all` and `app` only; `JWT_SECRET_NEXT` and `JWT_SECRET_PREVIOUS` have `optional: true`; `tls.mode=proxy` sets `TRUST_FORWARDED_HEADERS`; `tls.mode=native` mounts the Secret, sets the three TLS variables and the `https` port on `all`/`ingest`/`app` and the Service; `httpsRedirect` and `hstsMaxAge` render under native; `extraEnv`, `extraEnvFrom` and `parts.<part>.extraEnv` are appended; no rendered manifest in any fixture contains `DEVMODE`, `ENABLE_MOCK_DATA` or a literal connection string.
  - Negative cases: `ingest` and `processor` have no `JWT_*`, `OIDC_*`, `THEMES_PATH`, `ADMIN_EMAIL_FILE`; `processor` has no TLS variables or volumes; V06, V07, V08, V09, V12, V13, V17, V18 produce their messages; OIDC variables absent when `auth.oidc.issuer` is empty.
  - Validation criteria: all cases pass with zero regressions in Phase 1–3 suites; phase is not complete until this task passes.

### Implementation Phase 5: Database migration

- **GOAL-005**: `/app/mssql-migrate` runs before new pods serve traffic in the three modes `hook`, `initContainer`, `none`, with an optional dedicated service account.

- **TASK-040**: Create `charts/opsie/templates/migrate-job.yaml` (mode `hook`) `[✅ Completed: 2026-10-11]`
  - Rendered when `database.type=mssql`, `database.migrate.enabled=true` and `database.migrate.mode=hook`.
  - `Job` named `<base>-migrate` with annotations `helm.sh/hook: pre-install,pre-upgrade`, `helm.sh/hook-delete-policy: before-hook-creation`, `helm.sh/hook-weight: "0"`, merged with `database.migrate.annotations` (user annotations win). No `ttlSecondsAfterFinished`. `backoffLimit` and `activeDeadlineSeconds` from values; `restartPolicy: Never`.
  - Pod: image from `opsie.image`, `imagePullSecrets`, command `["/app/mssql-migrate"]`, args `["--dry-run"]` when `database.migrate.dryRun`, env `DB_CONNECTION_STRING` only (`secretKeyRef`) plus `database.migrate.extraEnv`, `database.migrate.resources`, `database.migrate.podLabels` / `podAnnotations`, the chart's pod and container security contexts. It does not reference the chart's ServiceAccount, ConfigMap or Valkey.
  - `serviceAccountName`: `opsie.migrateServiceAccountName` (empty means the namespace default account).

- **TASK-041**: Create the optional hook ServiceAccount in the same template file `[✅ Completed: 2026-10-11]`
  - Rendered when `database.migrate.serviceAccount.create=true`: `ServiceAccount` `<base>-migrate` with `database.migrate.serviceAccount.annotations` and `helm.sh/hook: pre-install,pre-upgrade`, `helm.sh/hook-weight: "-5"`, `helm.sh/hook-delete-policy: before-hook-creation`. The Job uses it. When `create=false` and `name` is set, the Job uses that existing account.

- **TASK-042**: Add the init-container variant to `deployment.yaml` (mode `initContainer`) `[✅ Completed: 2026-10-11]`
  - An init container `migrate` in the pods of every part in `database.migrate.initContainerParts` (empty = every part), same image, command, args and `DB_CONNECTION_STRING` env as the Job, `database.migrate.resources`. No Job renders in this mode.

- **TASK-043**: Document mode `none` behaviour in templates `[✅ Completed: 2026-10-11]`
  - Mode `none`, or `database.migrate.enabled=false`, or `database.type=postgres`, renders no migration. A template comment states that Postgres schema handling is outside the chart until open question 1 of the draft is resolved.

- **TASK-049**: Write and run unit tests validating TASK-040–TASK-043 `[✅ Completed: 2026-10-11]`
  - Files: `charts/opsie/tests/migrate_job_test.yaml`, `migrate_initcontainer_test.yaml`.
  - Dependencies: TASK-040, TASK-041, TASK-042, TASK-043 must be completed first.
  - Positive cases: default values render the `opsie-migrate` Job with both hook annotations, `backoffLimit: 1`, `activeDeadlineSeconds: 600`, the same image string as the Deployments, only `DB_CONNECTION_STRING` in env, no `ttlSecondsAfterFinished`; `dryRun: true` adds `--dry-run`; user annotation `argocd.argoproj.io/hook: PreSync` is present next to the Helm hook annotations; `serviceAccount.create: true` renders `opsie-migrate` ServiceAccount with weight `-5` and the Job uses it, annotations propagate; `serviceAccount.name: existing` with `create: false` uses it and renders no ServiceAccount; `mode: initContainer` renders no Job and an init container in every part of each topology; `initContainerParts: [app]` limits it to `app`; `database.migrate.podLabels` land on the Job pod.
  - Negative cases: `mode: none` renders nothing; `migrate.enabled: false` renders nothing; `database.type: postgres` renders nothing in any mode; `initContainerParts: [nonexistent]` fails with V20; Job pod has no `envFrom` and does not mount the chart ServiceAccount when no migrate account is set (`serviceAccountName` absent).
  - Validation criteria: all cases pass; `kubeconform` passes for the rendered Job; phase is not complete until this task passes.

### Implementation Phase 6: External routing

- **GOAL-006**: `ingresses[]` and `httpRoutes[]` render correct routing for all topologies and derive the OIDC redirect URL.

- **TASK-050**: Create `charts/opsie/templates/ingress.yaml` `[✅ Completed: 2026-10-11]`
  - One `networking.k8s.io/v1` `Ingress` per entry, named `<base>-<entry.name>`, `ingressClassName` from `className` (omitted when empty), `annotations`, `tls` pass-through.
  - Entry `hosts[]`: `{host, paths: [{path, pathType}]}`; `paths` empty defaults to `[{path: /, pathType: Prefix}]`. Backend service for non-events paths: `all` in `all-in-one`, `app` otherwise, port `http` (number 80).
  - In split topologies each host additionally gets `{path: /api/events, pathType: Prefix}` to the `ingest` Service, first in the list.

- **TASK-051**: Create `charts/opsie/templates/httproute.yaml` `[✅ Completed: 2026-10-11]`
  - One `gateway.networking.k8s.io/v1` `HTTPRoute` per entry, named `<base>-<entry.name>`, `parentRefs` and `hostnames` pass-through, `annotations`.
  - Generated rules: `all-in-one` one rule `PathPrefix /` to `<base>` port 80. Split topologies: rule 1 `PathPrefix /api/events` to `<base>-ingest` port 80; rule 2 `PathPrefix /` to `<base>-app` port 80. The chart never creates a `Gateway` or `GatewayClass`.
  - Entry fields `filters` (list copied into every generated rule) and `matchHeaders` (list merged into every generated match) cover the "extra filters or matches" statement of the draft (ASSUMPTION-003).

- **TASK-052**: Implement the OIDC redirect default in `opsie.oidcRedirectUrl` `[✅ Completed: 2026-10-11]`
  - `auth.oidc.redirectUrl` when set; else `https://<host>/api/auth/callback` using the first `ingresses` entry that has a host, else the first `httpRoutes` entry that has a hostname; else empty (rule V18 reports it when an issuer is set).

- **TASK-059**: Write and run unit tests validating TASK-050–TASK-052 `[✅ Completed: 2026-10-11]`
  - Files: `charts/opsie/tests/ingress_test.yaml`, `httproute_test.yaml`, `oidc_redirect_test.yaml`.
  - Dependencies: TASK-050, TASK-051, TASK-052 must be completed first.
  - Positive cases: default values render no Ingress and no HTTPRoute; two `ingresses` entries (different `className`) render `opsie-users` and `opsie-senders`; `all-in-one` Ingress routes only to `opsie`; split Ingress puts `/api/events` to `opsie-ingest` and `/` to `opsie-app`; two `httpRoutes` entries with different `parentRefs` render two routes; split HTTPRoute has the two generated rules; `filters` and `matchHeaders` appear on every rule; redirect URL derives from the first Ingress host, from the first HTTPRoute hostname when no Ingress host exists, and the explicit value wins.
  - Negative cases: V14 (missing `name`, duplicate `name`) and V15 (missing `parentRefs`) fail with the exact message; V16 fails when `--api-versions` omits `gateway.networking.k8s.io/v1` but cluster information is simulated, and is skipped otherwise; OIDC issuer with no host anywhere and no explicit redirect fails with V18; `className: ""` omits `ingressClassName`.
  - Validation criteria: all cases pass; `kubeconform` validates Ingress output (HTTPRoute schema from the Gateway API CRD catalog via `-schema-location`); phase is not complete until this task passes.

### Implementation Phase 7: Monitoring, extra objects and notes

- **GOAL-007**: `ServiceMonitor`, `extraObjects`, helpful `NOTES.txt`.

- **TASK-060**: Create `charts/opsie/templates/servicemonitor.yaml` `[✅ Completed: 2026-10-11]`
  - Rendered when `metrics.serviceMonitor.enabled=true`: one `monitoring.coreos.com/v1` `ServiceMonitor` named `<base>`, `selector.matchLabels` = `app.kubernetes.io/name` and `app.kubernetes.io/instance` (no component label, so every part's Service is selected), `endpoints: [{port: http, path: metrics.serviceMonitor.path, interval, scheme: http}]`, `labels` from `metrics.serviceMonitor.labels`, `namespaceSelector.matchNames: [<release namespace>]`. No TLS and no authentication settings in any TLS mode. Adds `podTargetLabels`/`relabelings` so the component label appears on each target (`app.kubernetes.io/component`).

- **TASK-061**: Create `charts/opsie/templates/extraobjects.yaml` `[✅ Completed: 2026-10-11]`
  - For each item in `extraObjects`: a string is passed through `tpl` with the root context, a map is `toYaml` then `tpl`; items separated by `---`.

- **TASK-062**: Write the final `charts/opsie/templates/NOTES.txt` `[✅ Completed: 2026-10-11]`
  - Content: placeholder image/tag reminder; the Services created per part; how to reach the UI when `ingresses`/`httpRoutes` are empty (`kubectl port-forward svc/<ui service> 8080:80`); the warning that `/metrics` must not be exposed through catch-all routes (draft open question 11); the reminder that a changed existing Secret does not restart pods.

- **TASK-069**: Write and run unit tests validating TASK-060–TASK-062 `[✅ Completed: 2026-10-11]`
  - Files: `charts/opsie/tests/servicemonitor_test.yaml`, `extraobjects_test.yaml`, `notes_test.yaml`.
  - Dependencies: TASK-060, TASK-061, TASK-062 must be completed first.
  - Positive cases: no `ServiceMonitor` by default; enabled renders one object whose selector matches the labels of every Service in `split-all` (assert label subset equality), scheme `http` and port `http` also with `tls.mode=native`; `labels` and `interval` propagate; `extraObjects` renders a map item and a templated string item (`{{ .Release.Name }}`); NOTES contains the placeholder warning.
  - Negative cases: `extraObjects: []` renders nothing; the ServiceMonitor has no `tlsConfig`, `basicAuth` or `bearerTokenSecret`; a string item that is not valid YAML after `tpl` fails the render (helm error asserted).
  - Validation criteria: all cases pass; full `helm unittest charts/opsie` green; phase is not complete until this task passes.

### Implementation Phase 8: Documentation

- **GOAL-008**: A README that lets an operator install, configure and upgrade the chart without reading the draft.

- **TASK-070**: Write `charts/opsie/README.md` `[✅ Completed: 2026-10-11]`
  - Sections: overview; repository usage (`helm repo add ab-lindex https://ab-lindex.github.io/helm-charts/`, `helm install opsie ab-lindex/opsie -f values.yaml`, release name `opsie` so names match); prerequisites (external database, Valkey/Redis with pub/sub, Microsoft Garnet unsupported, Gateway API and Prometheus Operator CRDs only if used); required Secrets with the exact names and keys from the `extraObjects` examples; topologies and replica semantics (copy the part table and the replica semantics from the draft); image placeholders (must set `image.repository` and `image.tag`); migration modes with the Argo CD `PreSync` mapping, sync-wave options and the "database Secret must exist before the hook on first install" caveat; TLS modes; routing (`ingresses`, `httpRoutes`, `/api/events` split, `/metrics` exposure warning); JWT rotation (link to Opsie `docs/deployment.md#rotating-jwt_secret`); Secret changes do not restart pods; two releases per namespace need their own `fullnameOverride`; Workload identity readiness table; changing `topology` after deployment is not tested.
  - Valkey section: sub-chart versus external, `valkey.fullnameOverride` pin, password Secret shape.

- **TASK-071**: Update `README.md` at the repository root `[✅ Completed: 2026-10-11]`
  - Add a chart list with links to `charts/etcd-backup` and `charts/opsie`, and the Helm repository URL.

- **TASK-072**: Add `charts/opsie/values.yaml` documentation comments in `helm-docs` style (`# -- description`) `[✅ Completed: 2026-10-11]`
  - Every top-level value has a one-line description. No generated table is committed unless `helm-docs` is added to CI (not planned).

- **TASK-079**: Write and run documentation checks validating TASK-070–TASK-072 `[✅ Completed: 2026-10-11]`
  - Files: `charts/opsie/tests/docs-test.sh` (run in CI).
  - Dependencies: TASK-070, TASK-071, TASK-072 must be completed first.
  - Positive cases: every top-level key in `values.yaml` is mentioned in `README.md` or has a `# --` comment (script compares `helm show values` keys with the README text); every relative link in both README files resolves; the Secret names and keys in the README equal those in the `values.yaml` `extraObjects` examples.
  - Negative cases: a deliberately undocumented top-level key in a temporary copy of `values.yaml` makes the script exit non-zero; a broken relative link makes it exit non-zero.
  - Validation criteria: script exits 0 on the branch and non-zero on both negative fixtures; markdown files follow the repository markdown instructions (ATX headings, language on fenced blocks); phase is not complete until this task passes.

### Implementation Phase 9: Cluster verification

- **GOAL-009**: Behaviour that cannot be proven by rendering is verified on a real cluster, and the open questions that depend on it are closed in the draft.

- **TASK-080**: Provision test prerequisites `[⚠️ Blocked: needs a pullable Opsie image and tag (draft open question 10)]`
  - kind or AKS test cluster; an MSSQL instance reachable from it; Argo CD instance; Secrets `opsie-database`, `opsie-jwt`, `opsie-valkey` created by hand; Gateway API CRDs and Prometheus Operator CRDs for the optional checks.
  - Fallback: build the image from the Opsie `Dockerfile` locally and load it into kind with `kind load docker-image`, set `image.repository` accordingly.

- **TASK-081**: Install each topology and verify rollout behaviour `[⚠️ Blocked: TASK-080]`
  - For `all-in-one`, `split-ingest`, `split-all`: `helm install opsie charts/opsie -f ci/<fixture>` then `helm upgrade` with a new tag; confirm one-pod-at-a-time rollout without capacity dip, spread across node pools (AKS), PDB behaviour on `kubectl drain`, `POST /api/events/{key}` routed to `ingest` in split topologies.

- **TASK-082**: Verify migration (draft open question 2) `[⚠️ Blocked: TASK-080]`
  - Confirm: Argo CD maps `pre-install,pre-upgrade` to `PreSync`; a failing Job blocks the sync and leaves old pods running; hook ServiceAccount (`create: true`) exists before the Job and remains afterwards; init-container mode with concurrent pods is serialized by `sp_getapplock` (run at least 3 pods at once against an unmigrated database); `dryRun: true` changes nothing.

- **TASK-083**: Verify Valkey sub-chart behaviour (draft open question 4) `[⚠️ Blocked: TASK-080]`
  - Confirm: with release name `opsie` the sub-chart Service is `opsie-valkey:6379`; `valkey.fullnameOverride` pins the name for another release name; `usersExistingSecret` with `aclUsers.default` and key `default` authenticates Opsie's `REDIS_PASSWORD`; the sub-chart image `docker.io/valkey/valkey` can be pulled; record the verified sub-chart version in `Chart.yaml` and `Chart.lock`. Update `opsie.redisAddr` if the Service name differs.

- **TASK-084**: Verify metrics scraping `[⚠️ Blocked: Opsie application `/metrics` endpoint (DEP-002)]`
  - With the endpoint present: `ServiceMonitor` targets appear for every part, `/metrics` answers over plain HTTP also with `tls.mode=native` and `httpsRedirect=true`.

- **TASK-085**: Record results and update the draft `[📋 Planned]`
  - Files (Opsie repository): `.specs/drafts/helm-chart.md` open questions 2, 4, 5 resolved or amended; values added by this plan (ASSUMPTION-002, ASSUMPTION-003) copied into the outline.

- **TASK-089**: Run the verification suite and record pass/fail `[⚠️ Blocked: TASK-080]`
  - Files: `charts/opsie/tests/e2e/README.md` (checklist with the commands used and observed output summaries).
  - Dependencies: TASK-081, TASK-082, TASK-083 must be completed first (TASK-084 when DEP-002 is met).
  - Positive cases: each topology installs and becomes Ready; upgrade completes with no unavailable replicas; migration hook succeeds on a clean database and reports no-op on a second run; sessions survive a pod restart (stored in Valkey); a user can sign in through the Ingress or HTTPRoute with the derived OIDC redirect URL.
  - Negative cases: wrong connection string makes the hook Job fail and the sync/upgrade stop with old pods serving; install without `image.repository` fails at render time; install with neither Valkey source fails at render time with the collected message; deleting the Valkey password Secret makes pods fail to start (documented behaviour).
  - Validation criteria: all cases recorded as passed; phase is not complete until this task passes.

### Implementation Phase 10: Release and cleanup

- **GOAL-010**: First chart release published, old in-repo chart retired.

- **TASK-090**: Release readiness check on the branch `[📋 Planned]`
  - `Chart.yaml` `version` is `0.1.0` (no existing release), `Chart.lock` committed, CI green, Phase 9 complete. Decide whether the first release ships with the `TBD` / `v0` placeholders (the draft expects it likely does) and state it in the pull request description.

- **TASK-091**: Merge to `main` `[📋 Planned]`
  - Dependencies: TASK-090. Merging triggers chart-releaser; confirm the `opsie-0.1.0` GitHub release and the `gh-pages` `index.yaml` entry, and `helm search repo ab-lindex/opsie`.

- **TASK-092**: Retire the old chart in the Opsie repository `[📋 Planned]`
  - Dependencies: TASK-091 (published chart exists).
  - Files in `AB-Lindex/opsie`: delete `helm-chart/` including its `*.md` files; replace `helm` references in `README.md` and `docs/` with a pointer to `https://ab-lindex.github.io/helm-charts/` (chart `opsie`); remove or update uses of `helm-chart/` in `Taskfile.yml`, workflows and scripts. Documentation text worth keeping is copied into `charts/opsie/README.md` before deletion.
  - Separate pull request in the Opsie repository; requires explicit approval before deleting.

- **TASK-099**: Write and run verification of TASK-090–TASK-092 `[📋 Planned]`
  - Files: none new; commands recorded in the pull request descriptions.
  - Dependencies: TASK-090, TASK-091, TASK-092 must be completed first.
  - Positive cases: `helm repo update && helm search repo ab-lindex/opsie` lists `0.1.0`; `helm template opsie ab-lindex/opsie -f <fixture>` renders from the published package (dependency included); `grep -R "helm-chart" ` in the Opsie repository finds no remaining reference.
  - Negative cases: a second push to `main` without a version bump publishes no duplicate release (chart-releaser skips it); `helm install` from the published chart without `image.repository` fails with the V02 message.
  - Validation criteria: all checks pass; zero references to the old chart remain; phase is not complete until this task passes.

## 3. Alternatives

- **ALT-001**: Keep the chart in the Opsie repository. Rejected in the draft: `helm-charts` already has the release pipeline and the published repository.
- **ALT-002**: Validate with `values.schema.json` only. Rejected: schemas cannot express cross-value or cluster-dependent rules and give generic messages; hence the collecting `_validate.tpl` (draft open question 9).
- **ALT-003**: Test with `ct install` in CI on kind. Deferred: needs a public image (CON-003); Phase 9 is manual until then.
- **ALT-004**: Test only with `helm template` and `grep`. Rejected: helm-unittest gives structured assertions and `failedTemplate` checks for the exact error messages.
- **ALT-005**: Render per-part configuration in separate ConfigMaps. Rejected: one common ConfigMap plus inline per-part env keeps one ConfigMap, and inline env changes roll pods without a checksum.
- **ALT-006**: Use `chart-releaser-action` `charts_repos` input instead of an explicit `helm repo add` step. Not chosen: the explicit step has deterministic behaviour; revisit if the action documents the input format unambiguously.

## 4. Dependencies

- **DEP-001**: Helm 3.x (CI pins one 3.x release), Kubernetes 1.35+ for rendering checks (`kubeconform --kubernetes-version 1.35.0`) and the kind test cluster, helm-unittest plugin (pinned in CI), kubeconform, chart-testing (`ct`), actionlint.
- **DEP-002**: Opsie application changes (not part of this plan): `GET /metrics` on the plain HTTP `PORT`, unauthenticated, never redirected to HTTPS, for every module (draft "Metrics" and open question 11). Blocks only TASK-084 and the metrics half of TASK-089.
- **DEP-003**: Public image address and tag scheme (draft open question 10). Blocks TASK-080 unless the local-image fallback is used.
- **DEP-004**: Upstream Valkey chart `valkey` `0.12.0` from `https://valkey.io/valkey-helm/`.
- **DEP-005**: GitHub Actions workflow `release.yml` (chart-releaser-action v1.6.0) and Pages-hosted Helm repository `https://ab-lindex.github.io/helm-charts/`.
- **DEP-006**: Opsie facts relied on: ports 8080/8443, `/healthz` and `/readyz`, `/app/mssql-migrate` (idempotent, `--dry-run`, `sp_getapplock`), env variable names in `docs/configuration.md`, module names `api`, `frontend-proxy`, `ingestion`, `alert-processing`, callback `/api/auth/callback`.

## 5. Files

- **FILE-001**: `charts/opsie/Chart.yaml`, `charts/opsie/Chart.lock`, `charts/opsie/.helmignore`
- **FILE-002**: `charts/opsie/values.yaml`, `charts/opsie/values.schema.json`
- **FILE-003**: `charts/opsie/templates/_helpers.tpl`, `charts/opsie/templates/_validate.tpl`
- **FILE-004**: `charts/opsie/templates/deployment.yaml`, `service.yaml`, `serviceaccount.yaml`, `configmap.yaml`, `pdb.yaml`
- **FILE-005**: `charts/opsie/templates/migrate-job.yaml`
- **FILE-006**: `charts/opsie/templates/ingress.yaml`, `httproute.yaml`
- **FILE-007**: `charts/opsie/templates/servicemonitor.yaml`, `extraobjects.yaml`, `NOTES.txt`
- **FILE-008**: `charts/opsie/README.md`, `README.md` (repository root)
- **FILE-009**: `charts/opsie/ci/all-in-one-values.yaml`, `split-ingest-values.yaml`, `split-all-values.yaml`
- **FILE-010**: `charts/opsie/tests/*_test.yaml`, `charts/opsie/tests/schema-test.sh`, `charts/opsie/tests/docs-test.sh`, `charts/opsie/tests/e2e/README.md`
- **FILE-011**: `.github/workflows/ci.yml` (new), `.github/workflows/release.yml` (edited), `ct.yaml` (new)
- **FILE-012**: In the Opsie repository: `.specs/drafts/helm-chart.md` (updated), `helm-chart/` (deleted in TASK-092)

## 6. Testing

- **TEST-001**: helm-unittest suites per template (Phases 3 to 7), run by `helm unittest charts/opsie`; covers topologies, replicas, spread, PDB, env/Secret distribution, TLS, migration modes, routing, ServiceMonitor, extraObjects.
- **TEST-002**: Validation suite `validate_test.yaml`: one negative test per rule V01–V21 with exact message, plus a multi-error test.
- **TEST-003**: `schema-test.sh`: schema enum, type and required-field failures.
- **TEST-004**: `helm lint` and `kubeconform -strict` on the three fixtures in CI.
- **TEST-005**: `ct lint` in CI.
- **TEST-006**: `docs-test.sh`: values keys documented, links resolve.
- **TEST-007**: Manual cluster verification (Phase 9): rollout, drain, migration, Valkey, metrics, OIDC sign-in.
- **TEST-008**: Positive and negative cases for every phase are listed in that phase's final testing task; each phase's goal is met only when its testing task passes.

## 7. Risks & Assumptions

- **RISK-001**: The first publish happens on merge to `main` (CON-001); a merge before Phase 9 would release an unverified chart. Mitigation: branch protection or an explicit gate in TASK-090.
- **RISK-002**: The upstream Valkey chart is pre-1.0 and its value keys (`auth.usersExistingSecret`, `auth.aclUsers`, `dataStorage`) may change. Mitigation: pinned version, `valkey_wiring_test.yaml` asserts our use, TASK-083 verifies against the real chart.
- **RISK-003**: Argo CD may map hook annotations differently than documented (draft open question 2). Mitigation: `database.migrate.annotations` accepts native Argo CD annotations; TASK-082 verifies.
- **RISK-004**: `.Capabilities.APIVersions` detection (V16) behaves differently across Helm and Argo CD renderers; a false positive would block valid installs. Mitigation: skip when cluster information is unavailable, test both paths, and let a documented escape be `helm install --api-versions`.
- **RISK-005**: Gateway API rules for a catch-all route forward `/metrics` publicly (draft open question 11). Mitigation: README and NOTES warn until decided.
- **RISK-006**: `readOnlyRootFilesystem` is not enabled because the server's writes outside mounted volumes are unverified; revisit after Phase 9.
- **RISK-007**: Chart and application drift (draft open question 6). Mitigation: DEP-006 lists the contract; the Opsie repository gets a follow-up to remind chart updates when environment variables change.
- **ASSUMPTION-001**: Helm 3 and Kubernetes 1.35 or newer are the supported targets (confirmed by the requester). `Chart.yaml` sets `kubeVersion: ">=1.35.0-0"`, so templates use only stable APIs (`apps/v1`, `batch/v1`, `policy/v1`, `networking.k8s.io/v1`, `gateway.networking.k8s.io/v1`) with no `.Capabilities.APIVersions` fallbacks for older versions, except the Gateway API CRD check (V16) and the Prometheus Operator CRD, which are not part of Kubernetes. CI installs a kind node image of 1.35 or newer.
- **ASSUMPTION-002**: The values `auth.sessionCacheTtl`, `auth.adminEmail.existingConfigMap` / `key`, `image.pullSecrets` and `tls.mountPath`, and hardcoded probe timings (liveness: `initialDelaySeconds: 10`, `periodSeconds: 20`, `failureThreshold: 3`; readiness: `periodSeconds: 10`, `failureThreshold: 3`) are additions to the draft outline, required by statements in the draft (session cache TTL "exposed", admin email file, `imagePullSecrets` in open question 10). They are copied back into the draft in TASK-085.
- **ASSUMPTION-003**: The draft's "extra filters or matches can be added per rule" is implemented minimally as entry-level `filters` and `matchHeaders` applied to every generated rule; the draft is clarified in TASK-085 if per-rule control is wanted.
- **ASSUMPTION-004**: Alert settings are given to every part, not only `ingest` and `processor`, because `app` runs `alert-processing` in `split-ingest` and the variables are harmless elsewhere.
- **ASSUMPTION-005**: `OPSIE_INTEGRATIONS_RELOAD_CHANNEL` has no dedicated value; the default is identical on every part, and a custom channel is set through global `extraEnv`, which reaches every part.
- **ASSUMPTION-006**: Postgres schema handling stays outside the chart (draft open question 1); `database.type=postgres` renders no migration.

## 8. Related Specifications / Further Reading

- Master design (Opsie repository): `.specs/drafts/helm-chart.md`
- Deferred companion design: `.specs/drafts/mssql-entra-auth.md`
- Opsie docs: `docs/configuration.md`, `docs/deployment.md`, `docs/mssql-migration.md`, `docs/database-setup.md`, `docs/distributed-background-processes.md`
- Layout example in this repository: `charts/etcd-backup`
- Release workflow: `.github/workflows/release.yml`
- Upstream Valkey chart: https://valkey.io/valkey-helm/ (source `https://github.com/valkey-io/valkey-helm`)
- helm-unittest: https://github.com/helm-unittest/helm-unittest
- Helm chart-releaser action: https://github.com/helm/chart-releaser-action

## 9. Implementation notes (2026-10-11)

Where the implementation differs from or adds to the plan:

- `values.schema.json` rejects an unknown `topology` and a missing `name` or `parentRefs` before the templates run, so rules V05 and the missing-name and missing-`parentRefs` parts of V14 and V15 are unreachable from the command line. The template checks stay as a second line of defence; the cases are tested through the schema (`schema-test.sh`). The draft's two-problem example (misspelled topology) therefore cannot occur; the multi-error test uses a missing database Secret plus no Valkey source.
- The collected error uses "problem" for one and "problems" for several.
- The pod checksum is computed from the helper `opsie.configData`, which also renders the ConfigMap data, because helm-unittest only loads the templates a suite lists.
- `opsie.valkeyFullname` mirrors the sub-chart's own naming (including the release-contains-name shortcut), so `REDIS_ADDR` matches the sub-chart Service for every release name.
- V16 detects cluster information by the presence of `apps/v1/Deployment` in `.Capabilities.APIVersions` (a cluster and Argo CD list group/version/Kind entries; plain `helm template` lists group/versions only). Use `--api-versions apps/v1/Deployment` to simulate a cluster.
- `podDisruptionBudget.minAvailable` needs `maxUnavailable: null` as well, because `maxUnavailable: 1` is the default; documented in `values.yaml` and the README.
- `helm package` unpacks the sub-chart (`charts/valkey/`) instead of embedding the `.tgz`; TASK-007 checks for that.
- `hstsMaxAge` defaults to `""` (unset); a value of `"0"` also renders nothing.
- Extra fixture `ci/full-values.yaml` covers routing, ServiceMonitor, native TLS and the migration service account for `kubeconform` (with the CRD catalog for HTTPRoute and ServiceMonitor).
- `release.yml` also moves `actions/checkout` from v3 to v4 so `actionlint` passes.
- `ct lint` could not be run locally (no `yamale`); CI installs it through `chart-testing-action`. `yamllint` rules of the default `ct` configuration were checked by hand against `Chart.yaml`, `values.yaml` and the fixtures.
- Verified without a cluster for TASK-083: with release name `opsie` the sub-chart Service renders as `opsie-valkey` and the `default` user password key is `default`. Authentication against a running Valkey is still to be verified.

Open: Phase 9 (TASK-080 to TASK-089) needs a cluster and a pullable image; TASK-085 follows from it. Phase 10 (merge to `main`, retiring `helm-chart/` in the Opsie repository) waits for Phase 9 and an explicit go-ahead.
