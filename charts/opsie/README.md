# opsie Helm Chart

Deploys [Opsie](https://github.com/AB-Lindex/opsie) to Kubernetes: one image, three deployment topologies, an external MSSQL (or PostgreSQL) database and a required Valkey service, either bundled as a sub-chart or external.

## Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Required Secrets](#required-secrets)
- [Image](#image)
- [Topologies](#topologies)
- [Valkey](#valkey)
- [Database migration](#database-migration)
- [TLS](#tls)
- [Routing](#routing)
- [Server-Sent Events stream](#server-sent-events-stream)
- [Metrics](#metrics)
- [Email integration](#email-integration)
- [Authentication](#authentication)
- [Operations](#operations)
- [Workload identity readiness](#workload-identity-readiness)
- [Validation](#validation)
- [Values reference](#values-reference)

## Prerequisites

- Helm 3 and Kubernetes 1.32 or newer.
- An external database with transaction support, MSSQL (primary) or PostgreSQL. The chart never creates a database, and the `memory` provider, `DEVMODE` and `ENABLE_MOCK_DATA` are never offered.
- A Valkey or Redis service with pub/sub: either the bundled `valkey` sub-chart or an external one. Microsoft Garnet is not supported because it lacks pub/sub.
- The Gateway API CRDs only if `httpRoutes` is used, and the Prometheus Operator CRDs only if `metrics.serviceMonitor.enabled` is used. The chart installs neither.

## Installation

```sh
helm repo add ab-lindex https://ab-lindex.github.io/helm-charts/
helm repo update
helm install opsie ab-lindex/opsie -f values.yaml
```

Use the release name `opsie`: the default resource names (`opsie`, `opsie-ingest`, `opsie-processor`, `opsie-app`, `opsie-config`, `opsie-migrate`) come from `fullnameOverride: opsie`, and the Valkey sub-chart Service follows the release name (`opsie-valkey`). Two releases in one namespace need their own `fullnameOverride` and release name.

A minimal values file:

```yaml
image:
  repository: registry.example/opsie
  tag: v1.2.3
database:
  existingSecret: opsie-database
auth:
  jwt:
    existingSecret: opsie-jwt
valkey:
  enabled: true
  auth:
    usersExistingSecret: opsie-valkey
```

## Required Secrets

The chart has no `Secret` template and no value that holds a secret. Every secret input is an existing Secret named in values. Create them with a SealedSecret, an ExternalSecret, or by hand; the examples are also commented under `extraObjects` in [values.yaml](values.yaml).

| Secret | Value that names it | Keys |
| --- | --- | --- |
| `opsie-database` | `database.existingSecret` | `connection-string` (`database.existingSecretKey`), form `sqlserver://user:pass@host:1433?database=opsie` |
| `opsie-jwt` | `auth.jwt.existingSecret` | `jwt-secret` (at least 32 characters), optional `jwt-secret-next`, optional `jwt-secret-previous` |
| `opsie-oidc` | `auth.oidc.existingSecret` | `client-id`, `client-secret` |
| `opsie-valkey` | `valkey.auth.usersExistingSecret` | `default` (the key is the ACL user name) |
| `opsie-redis` | `redis.existingSecret` | `password` (`redis.existingSecretKey`) |
| `opsie-email-shared` | `email.existingSecret` | `routes-token` (at least 32 characters), optional `routes-token-next`, `attachments-secret` (at least 32 characters); only with `email.enabled` |

Secrets reach only the parts that use them. The database connection string and the Redis password go to every part; JWT, OIDC, themes and the admin email file go only to the parts that run the `api` module (`all` and `app`); TLS settings go to the parts that serve traffic (`all`, `ingest`, `app`).

A changed existing Secret or ConfigMap does not restart the pods, because the chart does not own it. Restart the Deployments after such a change, or let a controller such as [Reloader](https://github.com/stakater/Reloader) do it. Reloader watches Secrets and ConfigMaps and rolls the Deployments that use them; enable it per Deployment with `parts.<part>.annotations` (for example `reloader.stakater.com/auto: "true"`).

## Image

The public image address is not decided yet. `image.repository` is `TBD` and `image.tag` is `v0`, and rendering fails while the repository is `TBD`. Set both in your values file. An empty `image.tag` falls back to the chart `appVersion` (`v0`). The same image and tag run in every part and in the migration step.

## Topologies

`topology` selects the parts. Changing it after deployment should work but is not tested.

| Topology | Parts | Default replicas |
| --- | --- | --- |
| `all-in-one` (default) | `all` | 1 |
| `split-ingest` | `ingest`, `app` | 1 each |
| `split-all` | `ingest`, `processor`, `app` | 2 each |

| Part | Environment | Runs | Serves |
| --- | --- | --- | --- |
| `all` | none | every module | everything |
| `ingest` | `MODULES=ingestion` | ingestion | `POST /api/events/{key}` |
| `processor` | `MODULES=alert-processing` | background alert processors | health endpoints and metrics |
| `app` in `split-ingest` | `NOT_MODULES=ingestion` | api, frontend-proxy, alert-processing | UI and API |
| `app` in `split-all` | `NOT_MODULES=ingestion,alert-processing` | api, frontend-proxy | UI and API |

Every part is a `Deployment` with a `ClusterIP` `Service` of the same name, including `processor`, so every part can be scraped. Each part accepts `replicaCount`, `resources`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints`, `annotations`, `podLabels`, `podAnnotations` and `extraEnv` under `parts.<part>`. Values for a part the topology does not have are an error.

Replica semantics:

- `ingest` replicas scale intake throughput.
- `processor` replicas are for availability: the processors coordinate through a Valkey lock, so one instance works and the others take over.
- `app` replicas scale the UI and API; sessions live in Valkey.
- `all` defaults to one replica and can be raised with `parts.all.replicaCount`.

Rollouts use `RollingUpdate` with `maxSurge: 1` and `maxUnavailable: 0` (`strategy.rollingUpdate`): one pod at a time, never below the replica count.

`topologySpread` is on for every part. The default constraint spreads over the AKS node pool label `agentpool` with `ScheduleAnyway`; the chart fills in each part's own `labelSelector`. A part's `topologySpreadConstraints` replaces the shared list, and a `labelSelector` you give is kept. On a cluster without the label the constraint is ignored.

`podDisruptionBudget.enabled: auto` renders a budget for a part only when it has two or more replicas; `true` and `false` force it. The default is `maxUnavailable: 1`. To use `minAvailable`, set `maxUnavailable: null` as well. The decision is made at render time, so change replica counts through Helm values only.

## Valkey

Valkey is required in every topology. Set exactly one of:

- `valkey.enabled: true` for the bundled sub-chart (the upstream [valkey-io/valkey-helm](https://github.com/valkey-io/valkey-helm) chart, pinned in `Chart.yaml`). Authentication is mandatory: `valkey.auth.usersExistingSecret` names a Secret whose key `default` holds the password. Everything else under `valkey` passes through to the sub-chart.
- `redis.enabled: true` for an external Valkey or Redis: `redis.addr`, `redis.db` and a password Secret in `redis.existingSecret`.

With the sub-chart, `REDIS_ADDR` is `<release>-valkey:6379`, which is `opsie-valkey:6379` for the release name `opsie`. For another release name, pin it with `valkey.fullnameOverride`.

## Database migration

With `database.type: mssql` the server does not migrate the schema; `/app/mssql-migrate` does, and it is idempotent. `database.migrate.mode` chooses how it runs:

| Mode | Rendered | Notes |
| --- | --- | --- |
| `hook` (default) | A `Job` with `pre-install,pre-upgrade` Helm hook annotations | Argo CD maps these to a `PreSync` hook. A failing Job blocks the sync and the old pods keep running. |
| `initContainer` | An init container in every part (limit with `database.migrate.initContainerParts`) | Runs on every pod start; concurrent runs are serialized by a database lock. |
| `none` | Nothing | Something else owns the step. |

`database.migrate.dryRun` passes `--dry-run`. The hook Job uses only the image and the database Secret, never the chart's ServiceAccount, ConfigMap or Valkey, because on a first install the hook runs before the rest of the release exists. This means the database Secret must exist before the hook on a first install: create it outside the release, or give it the annotations `helm.sh/hook: pre-install,pre-upgrade` and a lower `helm.sh/hook-weight` than the Job (see the `extraObjects` example in [values.yaml](values.yaml)).

`database.migrate.annotations` can add native Argo CD annotations such as `argocd.argoproj.io/hook: PreSync` or a sync-wave; they win over the Helm hook annotations. `parts.<part>.annotations` allows a sync-wave on each part's Deployment. Neither is set by default.

With `database.type: postgres` no migration is rendered: Postgres schema handling stays outside the chart.

## TLS

| `tls.mode` | Effect |
| --- | --- |
| `none` (default) | Plain HTTP. |
| `proxy` | Sets `TRUST_FORWARDED_HEADERS=true`. Every Ingress or Gateway in front must terminate TLS and overwrite `X-Forwarded-Proto`; the chart cannot verify that. |
| `native` | Mounts `tls.existingSecret` (type `kubernetes.io/tls`) at `tls.mountPath` and serves TLS on 8443. `tls.httpsRedirect` and `tls.hstsMaxAge` apply here. |

Probes stay on the plain HTTP port in every mode. With an `HTTPRoute`, the Gateway listener terminates TLS, so `proxy` is the matching mode. The internal port (see [Metrics](#metrics)) is plain HTTP in every mode and is never redirected.

## Routing

No external access is created by default. `ingresses` and `httpRoutes` are lists with any number of entries, each with a unique `name`; the resource is named `<base>-<name>`. In the split topologies every entry routes the prefix `/api/events` to `ingest` and everything else to `app`.

```yaml
ingresses:
  - name: users
    className: nginx
    hosts:
      - host: opsie.example.com
    tls:
      - secretName: opsie-tls
        hosts:
          - opsie.example.com
httpRoutes:
  - name: senders
    parentRefs:
      - name: gateway
        namespace: gateway-system
    hostnames:
      - events.example.com
```

`httpRoutes` entries also accept `filters` and `matchHeaders`, applied to every generated rule. The chart never creates a `Gateway` or `GatewayClass`, and does not check that entries are consistent with each other.

Warning: `/metrics` is no longer served on the HTTP or HTTPS port, so a catch-all route cannot expose it. It lives on the internal port, which no `ingresses` or `httpRoutes` entry references (see [Metrics](#metrics)).

## Server-Sent Events stream

The UI keeps one long-lived Server-Sent Events request per visible browser tab open to `GET /api/stream`. The application sends a heartbeat every 15 to 25 seconds and closes each stream cleanly after 24 to 36 minutes (a 30 minute lifetime with 20% jitter); the browser reconnects by itself. The stream is served by the parts that run `api` (`all` and `app`).

`sse.enabled` (default `true`) renders, for every `ingresses` and `httpRoutes` entry, a second resource named `<base>-<name>-stream` that matches only the path `/api/stream` and sends it to the same part as the main route. The main Ingress and HTTPRoute stay unchanged, so the stream settings never leak onto the other paths:

- The stream `Ingress` copies `className` and `tls` from its entry and takes the entry's `annotations` merged with `sse.ingress.annotations`; the latter win. The defaults (`proxy-read-timeout`, `proxy-send-timeout`, `proxy-buffering: "off"`) target ingress-nginx. For another controller, replace them with that controller's read-timeout and no-buffering settings.
- The stream `HTTPRoute` copies `parentRefs`, `hostnames`, `filters` and `matchHeaders` and sets `timeouts` from `sse.httpRoute.timeouts` (Gateway API 1.1 or newer; an empty map renders no `timeouts`). The Gateway implementation must also not buffer responses.

Requirements on whatever sits in front of Opsie:

- **HTTP/2 must be served to browsers.** With HTTP/1.1 a browser allows about 6 connections per origin and every open tab holds one for the stream, which starves normal requests. Check the protocol column in the browser's network tools (`h2`) or run `curl -sI --http2 -o /dev/null -w '%{http_version}\n' https://<host>/`.
- No response buffering: the application also sends `X-Accel-Buffering: no`, which ingress-nginx honours.
- A read or request timeout above the heartbeat interval of 25 seconds, and any absolute request limit above the 36 minute maximum stream lifetime. The defaults of 3600 seconds satisfy both.

`sse.maxConnectionsPerUser` (`SSE_MAX_CONNECTIONS_PER_USER`, application default 10) and `sse.maxConnections` (`SSE_MAX_CONNECTIONS`, application default 2000) are per pod. Above the per-user cap the oldest stream of that user is closed and the new one accepted; above the pod cap new requests receive `429` with `Retry-After`. `sse.enabled: false` sets `SSE_DISABLED=true`: the endpoint answers `404`, no stream routing is rendered and the UI hides the connection indicator.

## Metrics

Every part serves `GET /metrics` unauthenticated on the internal port (`internal.port`, `INTERNAL_PORT`, default `8090`), a plain-HTTP listener that is always on. The chart adds a named `internal` container port and Service port to every part, and the `ServiceMonitor` scrapes that port. `/metrics` answers `404` on the HTTP and HTTPS ports, so it is never reachable through `ingresses` or `httpRoutes`, and `tls.httpsRedirect` does not affect scrapes. The port must differ from 8080, and from 8443 with `tls.mode: native`. Probes stay on the HTTP port.

Upgrading from chart 0.3.x: `metrics.port` (`METRICS_PORT`) was removed and rendering fails while it is set; use `internal.port`. Scrapers that used the HTTP port must move to the `internal` port.

`metrics.serviceMonitor.enabled: true` renders one `ServiceMonitor` that selects every Service of the release and scrapes over plain HTTP, also with native TLS. The component label identifies the part on each target. Use `metrics.serviceMonitor.labels` to match your Prometheus `serviceMonitorSelector`.

## Email integration

`email.enabled: true` connects Opsie to the separate `opsie-email` service, which receives mail by SMTP and delivers envelopes to Opsie. The chart does not deploy `opsie-email`; its release is installed on its own.

| Value | Purpose |
| --- | --- |
| `email.enabled` | Switches the integration on (default `false`) |
| `email.domain` | `EMAIL_DOMAIN`: recipients are `alerts+<integration key>@<domain>` |
| `email.existingSecret` | The Secret shared with the `opsie-email` release |
| `email.attachments.url` | `EMAIL_ATTACHMENT_API_URL`: base URL of the attachment API of `opsie-email` |
| `email.networkPolicy.*` | Restricts the internal port, see below |

The three required values are checked at render time. The parts that run the `api` module (`all` and `app`) receive `EMAIL_DOMAIN`, `EMAIL_ATTACHMENT_API_URL` and the credentials; `ingest` and `processor` receive no email variable.

### Shared Secret

One existing Secret holds every credential. The chart references it by name and never renders it. Create it in the namespace of both releases:

```sh
kubectl create secret generic opsie-email-shared \
  --from-literal=routes-token="$(openssl rand -hex 32)" \
  --from-literal=attachments-secret="$(openssl rand -hex 32)"
```

| Key | Read by Opsie | Read by `opsie-email` |
| --- | --- | --- |
| `routes-token` | accepted as route sync bearer token | sent as route sync bearer token |
| `routes-token-next` (optional) | also accepted | not read |
| `attachments-secret` | sent as attachment API bearer token | verified |

The `opsie-email` release must reference the same Secret name and keys. Both releases must live in the same namespace, or the operator must replicate the Secret. Secrets reach the pods as environment variables, so a changed Secret needs a restart.

Rotating the route sync token takes three steps and causes no outage:

1. Add the new token as `routes-token-next` and restart Opsie.
2. Set `routes-token` to the new token and `routes-token-next` to the old one, then restart both releases in any order.
3. Remove `routes-token-next` and restart Opsie.

### Route sync and the internal Service

With `email.enabled` the chart renders the ClusterIP Service `<base>-internal` (`opsie-internal`). It selects the part that serves route sync (`all`, or `app` in the split topologies), so `opsie-email` reads its routes from `http://opsie-internal:8090/api/internal/mail-routes` whatever the topology. Neither this Service nor the internal port is referenced by `ingresses` or `httpRoutes`.

### Network policy

With `email.networkPolicy.enabled` (default) the chart renders an ingress NetworkPolicy for the pods behind `<base>-internal`. It keeps the HTTP (and HTTPS) port open to everyone, and allows the internal port only from the `opsie-email` pods (`email.networkPolicy.opsieEmail`, in the release namespace unless a `namespaceSelector` is given) and from `email.networkPolicy.metricsPeers`. Because the same port serves unauthenticated `/metrics`, list the Prometheus pods or namespace there:

```yaml
email:
  networkPolicy:
    metricsPeers:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: monitoring
```

Rendering fails when `metrics.serviceMonitor.enabled` and the policy are both on and `metricsPeers` is empty, because scraping would stop silently. A NetworkPolicy only works with a CNI that enforces it. `email.networkPolicy.egress.enabled` adds an Egress policy that lets those pods reach `opsie-email` on `email.networkPolicy.egress.attachmentsPort`; an Egress policy isolates all other egress of the pods (database, Valkey, DNS), so enable it only together with your own egress rules.

## Authentication

- `JWT_SECRET` comes from `auth.jwt.existingSecret`. Rotation is a Secret change (`jwt-secret`, `jwt-secret-next`, `jwt-secret-previous`) followed by a restart; see [rotating JWT_SECRET](https://github.com/AB-Lindex/opsie/blob/main/docs/deployment.md#rotating-jwt_secret).
- OIDC is configured with `auth.oidc.issuer`, `auth.oidc.scopes` and the client Secret. The redirect URL defaults to `https://<first host>/api/auth/callback`, from the first `ingresses` entry with a host, else the first `httpRoutes` hostname. With several entries, set `auth.oidc.redirectUrl` explicitly.
- `auth.sessionCacheTtl` sets `SESSION_CACHE_TTL` (at most 30s) for the parts that run `api`.
- `auth.adminEmail.existingConfigMap` mounts the admin email file; `themes.existingConfigMap` mounts custom themes at `/app/themes/custom`.

## Operations

- Alert settings: `alerts.reopenWindow` and `alerts.zombieThreshold`.
- Extra environment for every part: `extraEnv` and `extraEnvFrom`; per part: `parts.<part>.extraEnv`. A custom `OPSIE_INTEGRATIONS_RELOAD_CHANNEL` is set through `extraEnv` so every part receives it.
- Resources, scheduling and metadata of every part: `resources`, `podLabels`, `podAnnotations`, `podSecurityContext`, `securityContext`. Containers run as uid and gid 1001 without privilege escalation and with all capabilities dropped. `readOnlyRootFilesystem` is not set until verified.
- `serviceAccount` controls the ServiceAccount shared by every part; `nameOverride` changes the chart name used in labels.
- `extraObjects` renders arbitrary manifests (maps or strings) through `tpl`, for example SealedSecrets.
- Reaching the UI without routing: `kubectl port-forward svc/opsie 8080:80` (`svc/opsie-app` in split topologies).

## Workload identity readiness

Opsie connects to MSSQL with SQL authentication only; passwordless access needs an application change first. The chart keeps the door open without Azure-specific values:

| A workload identity setup needs | Provided by |
| --- | --- |
| A pod label | `podLabels`, `parts.<part>.podLabels`, `database.migrate.podLabels` |
| A service account annotation | `serviceAccount.annotations`, `database.migrate.serviceAccount.annotations` |
| A service account label | `serviceAccount.labels`, `database.migrate.serviceAccount.labels` |
| Disable token automount on the service account | `serviceAccount.automountServiceAccountToken: false` |
| A predictable service account name | `serviceAccount.name` (default `opsie`); the migration account is `<base>-migrate` |
| A migration service account that exists when the hook runs | `database.migrate.serviceAccount.create` |
| A passwordless connection string | `database.existingSecret`; the chart treats the string as opaque |

## Validation

`values.schema.json` checks the shape of single values (enums, types, required fields). `templates/_validate.tpl` checks rules across values and reports every problem in one error, for example:

```text
Error: execution error at (opsie/templates/configmap.yaml:1:4): opsie: 2 configuration problems:
  1. No database Secret is named (database.existingSecret). Set it to an existing Secret holding the connection string under database.existingSecretKey.
  2. No Valkey source is selected (valkey.enabled, redis.enabled). Set valkey.enabled=true for the bundled sub-chart, or redis.enabled=true with redis.addr for an external Valkey/Redis.
```

`httpRoutes` are additionally checked against the cluster's Gateway API. That check is skipped by plain `helm template`; add `--api-versions apps/v1/Deployment` to simulate a cluster.

## Values reference

Every value is documented in [values.yaml](values.yaml). The top-level keys are:

| Key | Purpose |
| --- | --- |
| `fullnameOverride`, `nameOverride` | Resource naming |
| `image` | Repository, tag, pull policy and pull secrets |
| `topology`, `parts`, `topologySpread`, `strategy`, `podDisruptionBudget` | Parts, replicas, scheduling and rollout |
| `serviceAccount` | The shared ServiceAccount |
| `database` | Type, connection Secret and migration |
| `valkey`, `redis` | The Valkey source |
| `auth`, `themes` | JWT, OIDC, session cache, admin emails and themes |
| `tls` | TLS mode |
| `alerts` | Alert tuning |
| `metrics` | ServiceMonitor |
| `internal` | Port of the internal listener (`/metrics`, mail route sync) |
| `email` | Email integration: domain, shared Secret, attachment API, network policy |
| `sse` | Server-Sent Events stream: caps, kill switch and stream routing |
| `podLabels`, `podAnnotations`, `extraEnv`, `extraEnvFrom`, `resources`, `podSecurityContext`, `securityContext` | Settings for every part |
| `ingresses`, `httpRoutes` | External routing |
| `extraObjects` | Extra manifests |
