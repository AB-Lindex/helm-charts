# opsie Helm Chart

Deploys [Opsie](https://github.com/AB-Lindex/opsie) to Kubernetes: one image, three deployment topologies, an external MSSQL (or PostgreSQL) database and a required Valkey service, bundled (standalone or with Sentinel) or external.

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
- [Rego helpers](#rego-helpers)
- [Authentication](#authentication)
- [Operations](#operations)
- [Workload identity readiness](#workload-identity-readiness)
- [Validation](#validation)
- [Values reference](#values-reference)

## Prerequisites

- Helm 3 and Kubernetes 1.32 or newer.
- An external database with transaction support, MSSQL (primary) or PostgreSQL. The chart never creates a database, and the `memory` provider, `DEVMODE` and `ENABLE_MOCK_DATA` are never offered.
- A Valkey or Redis service with pub/sub: either the bundled `valkey` sub-chart (standalone), the bundled `valkeySentinel` setup (replication with Sentinel) or an external one. Microsoft Garnet is not supported because it lacks pub/sub. Valkey Cluster (sharded) is not supported.
- The Gateway API CRDs only if `httpRoutes` is used, and the Prometheus Operator CRDs only if `metrics.serviceMonitor.enabled` is used. The chart installs neither.

## Installation

```sh
helm repo add ab-lindex https://ab-lindex.github.io/helm-charts/
helm repo update
helm install opsie ab-lindex/opsie -f values.yaml
```

Use the release name `opsie`: the default resource names (`opsie`, `opsie-ingest`, `opsie-processor`, `opsie-app`, `opsie-config`, `opsie-migrate`, and with `email.enabled` `opsie-email`) come from `fullnameOverride: opsie`, and the Valkey sub-chart Service follows the release name (`opsie-valkey`). Two releases in one namespace need their own `fullnameOverride` and release name.

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
| `opsie-valkey` | `valkey.auth.usersExistingSecret`, `valkeySentinel.auth.usersExistingSecret`, `valkeySentinel.sentinel.existingSecret` | `default` (the key is the ACL user name). With `valkeySentinel` also `replication-user` and `sentinel` (the Sentinel password); the three passwords differ |
| `opsie-redis` | `redis.existingSecret` | `password` (`redis.existingSecretKey`); in sentinel mode also `sentinel` (`redis.existingSecretSentinelKey`) |
| `opsie-email-shared` | `email.existingSecret` | `routes-token` (at least 32 characters), optional `routes-token-next`, `attachments-secret` (at least 32 characters); only with `email.enabled` |
| `opsie-email-blob` | `email.blob.existingSecret` | `azure-connection-string`, `azure-sas-token`, `s3-access-key-id` and `s3-secret-access-key`, depending on `email.blob`; only with `email.enabled`, optional |

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

- `valkey.enabled: true` for the bundled standalone sub-chart (the upstream [valkey-io/valkey-helm](https://github.com/valkey-io/valkey-helm) chart, pinned in `Chart.yaml`): one pod, no volume. Authentication is mandatory: `valkey.auth.usersExistingSecret` (default `opsie-valkey`) names a Secret whose key `default` holds the password. Everything else under `valkey` passes through to the sub-chart. When this pod restarts, every user is signed out.
- `valkeySentinel.enabled: true` for the bundled replication setup (the same upstream chart under the alias `valkeySentinel`): three Valkey pods, each with a `100Mi` volume on the cluster's default storage class (`valkeySentinel.persistence.size` and `.storageClass`), three Sentinels and a PodDisruptionBudget for each. Opsie runs with `REDIS_MODE=sentinel` and finds the primary through the Sentinel Service, so a restart or failover of a Valkey pod keeps the sessions. The Secret named in `valkeySentinel.auth.usersExistingSecret` and `valkeySentinel.sentinel.existingSecret` (default `opsie-valkey`) needs the keys `default`, `replication-user` and `sentinel`, with three different passwords. Everything else under `valkeySentinel` passes through to the sub-chart.
- `redis.enabled: true` for an external Valkey or Redis: `redis.addr` and a password Secret in `redis.existingSecret`. With `redis.mode: sentinel`, `redis.addr` is a comma separated list of Sentinel addresses and the same Secret holds the Sentinel password under `redis.existingSecretSentinelKey`. The external service must run Valkey 9 or later or Redis with pub/sub, with the user `default` (and, for Sentinel, the user `sentinel` and the master name `mymaster`). Opsie uses database 0.

Switching from `valkey.enabled` to `valkeySentinel.enabled` needs no other setting when the Secret has the three keys: `REDIS_MODE`, `REDIS_ADDR` and `REDIS_SENTINEL_PASSWORD` follow the switch.

| Source | `REDIS_MODE` | `REDIS_ADDR` (release `opsie`) |
| --- | --- | --- |
| `valkey.enabled` | `standalone` | `opsie-valkey:6379` |
| `valkeySentinel.enabled` | `sentinel` | `opsie-valkey-sentinel:26379` |
| `redis.enabled` | `redis.mode` | `redis.addr` |

The address follows the release name. For another release name, pin it with `valkey.fullnameOverride` or `valkeySentinel.fullnameOverride`. `valkeySentinel.nameOverride: valkey` is set so that the alias gives the same resource names as `valkey.enabled`; do not change it.

The spread constraints of `valkeySentinel` select the pods by `app.kubernetes.io/name` only, because the sub-chart does not template them. They match this namespace only; add `app.kubernetes.io/instance` when several releases run in one namespace.

### Restarts and upgrades

Opsie answers `503` with `Retry-After` while Valkey is unreachable and never signs users out because of it. A session that Valkey confirmed within the last `auth.sessionCacheTtl` plus `auth.sessionCacheStaleGrace` is still served from memory. All pods wait `terminationGracePeriodSeconds` (default `130`, the application's own shutdown timeout is 120 s) to finish running batches.

Switching an existing release from `valkey.enabled` to `valkeySentinel.enabled` logs everyone out once: the standalone instance has no volume, so its sessions do not carry over. Helm replaces the Deployment `opsie-valkey` with the StatefulSet `opsie-valkey` and keeps patching the shared ServiceAccount, init-scripts ConfigMap and Service `opsie-valkey` (none has an immutable field set). The Secret `opsie-valkey` is rendered by neither alias.

| Created by `valkey.enabled` only | Created by `valkeySentinel.enabled` only |
| --- | --- |
| Deployment `opsie-valkey` | StatefulSets `opsie-valkey` and `opsie-valkey-sentinel` |
| | Services `-headless`, `-read`, `-sentinel`, `-sentinel-hl` |
| | ConfigMap `-sentinel-scripts` |
| | PodDisruptionBudgets `opsie-valkey` and `opsie-valkey-sentinel` |

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

### Alert change notifications

On the stream, the application tells the browsers of the affected teams within seconds when an alert is created, reopened, closed, acknowledged or reassigned; the browser then refetches (the top bar shows *Live* instead of *Connected*). The events carry identifiers only and authorization stays in the existing endpoints. The `alert-processing` and `api` pods publish through the Valkey the chart already requires, and the pods that run `api` forward each event to the open streams of the users who may see it. The validation rules `V06` and `V07` already refuse a release without exactly one Valkey source, so a split topology without Redis cannot render.

- `alertEvents.enabled` (default `true`) is the opt-out. `false` sets `ALERT_EVENTS_DISABLED=true` on every part: nothing is published, the stream sends no alert events and the UI polls every 30 seconds as before. `sse.enabled: false` turns alert events off too. The opt-out does not remove the Valkey requirement.
- Metrics: `opsie_sse_events_sent_total{type}` counts the events written, `opsie_sse_events_dropped_total` counts events dropped because a slow stream's buffer was full, and `opsie_sse_publish_failures_total` counts failed publishes (alert changes then show up at the next poll).
- Changes made by an automatic close rule appear at the next poll (30 seconds, 120 seconds while the stream is live).

Upgrade notes: open tabs receive alert events after their next reconnect, at most 36 minutes after the upgrade. Split deployments need Valkey, which the chart already enforces. Set `alertEvents.enabled: false` to keep the previous polling behavior.

## Metrics

Every part serves `GET /metrics` unauthenticated on the internal port (`internal.port`, `INTERNAL_PORT`, default `8090`), a plain-HTTP listener that is always on. The chart adds a named `internal` container port and Service port to every part, and the `ServiceMonitor` scrapes that port. `/metrics` answers `404` on the HTTP and HTTPS ports, so it is never reachable through `ingresses` or `httpRoutes`, and `tls.httpsRedirect` does not affect scrapes. The port must differ from 8080, and from 8443 with `tls.mode: native`. Probes stay on the HTTP port.

Upgrading from chart 0.3.x: `metrics.port` (`METRICS_PORT`) was removed and rendering fails while it is set; use `internal.port`. Scrapers that used the HTTP port must move to the `internal` port.

`metrics.serviceMonitor.enabled: true` renders one `ServiceMonitor` that selects every Service of the release and scrapes over plain HTTP, also with native TLS. The component label identifies the part on each target. Use `metrics.serviceMonitor.labels` to match your Prometheus `serviceMonitorSelector`.

## Email integration

`email.enabled: true` switches on the email integration: Opsie accepts mail envelopes, and the chart deploys [opsie-email](https://github.com/AB-Lindex/opsie-email) next to it. opsie-email is the SMTP front end: it accepts mail for `alerts+<integration key>@<domain>`, forwards it to Opsie as an alert envelope, stores attachments in blob storage and serves them back to Opsie. It replaces the former `opsie-email` chart, which is deprecated; see [the migration guide](../../docs/migrating-opsie-email.md).

A minimal setup on Azure with workload identity:

```yaml
email:
  enabled: true
  domain: mail.example.com
  existingSecret: opsie-email-shared
  image:
    repository: registry.example/opsie-email
    tag: v1.2.3
  blob:
    azure:
      container: attachments
      accountUrl: https://account.blob.core.windows.net
  service:
    smtp:
      loadBalancerIP: 203.0.113.10
      annotations:
        service.beta.kubernetes.io/azure-pip-name: opsie-email
        service.beta.kubernetes.io/azure-load-balancer-resource-group: rg-opsie
```

| Value | Purpose |
| --- | --- |
| `email.enabled` | Switches the integration on (default `false`) |
| `email.domain` | `EMAIL_DOMAIN`: recipients are `alerts+<integration key>@<domain>`; also the default of `email.smtp.acceptDomains` |
| `email.existingSecret` | The Secret read by Opsie and by opsie-email, see below |
| `email.image.*` | `repository`, `tag` (required, no `appVersion` fallback) and `pullPolicy` of opsie-email; the pull secrets are `image.pullSecrets` |
| `email.replicaCount`, `email.resources`, `email.nodeSelector`, `email.tolerations`, `email.affinity`, `email.topologySpreadConstraints` | Scheduling of opsie-email. Without `email.topologySpreadConstraints` it uses `topologySpread.constraints` |
| `email.logLevel`, `email.forwardTimeout`, `email.routes.*`, `email.smtp.*` | opsie-email settings; an empty value keeps the application default |
| `email.blob.*` | Attachment storage, see below |
| `email.service.*` | The SMTP, attachment API and metrics Services |
| `email.networkPolicy.*` | NetworkPolicies, see below |
| `email.podLabels`, `email.podAnnotations`, `email.extraEnv`, `email.podSecurityContext`, `email.securityContext`, `email.terminationGracePeriodSeconds` | Pod settings of opsie-email. `email.podLabels` and `email.podAnnotations` are added to the top-level `podLabels` and `podAnnotations`, which reach opsie-email too; `extraEnv`, `podSecurityContext` and `securityContext` do not. opsie-email runs as uid 65532 with a read-only root file system |

The required values are checked at render time. The parts that run the `api` module (`all` and `app`) receive `EMAIL_DOMAIN`, `EMAIL_ATTACHMENT_API_URL` and the credentials; `ingest` and `processor` receive no email variable. opsie-email runs as the component `email` of the release (`app.kubernetes.io/name: opsie`, `app.kubernetes.io/component: email`) under the ServiceAccount of the release (`serviceAccount`), so a workload identity set up for Opsie also covers the blob access of opsie-email.

### Resources

| Resource | Type | Port | Purpose |
| --- | --- | --- | --- |
| Deployment `<base>-email` | | | opsie-email; ready once the first route snapshot is loaded (probes on the HTTP port 8080) |
| Service `<base>-email-smtp` | `LoadBalancer`, `externalTrafficPolicy: Local` | 25 to 2525 | Public mail intake. `Local` keeps the client address that route `allowedRanges` check |
| Service `<base>-email` | `ClusterIP` | 8082 | Attachment API for Opsie |
| Service `<base>-email-metrics` | `ClusterIP` | 9090 | Prometheus metrics, keep cluster-internal |
| Service `<base>-internal` | `ClusterIP` | `internal.port` | Route sync for opsie-email, see below |

With `fullnameOverride: opsie` these are `opsie-email`, `opsie-email-smtp`, `opsie-email-metrics` and `opsie-internal`. Opsie calls the attachment API at `http://<base>-email:<email.service.attachments.port>`; nothing needs to be configured for that. The public Service needs a static IP and an MX record for the email domain pointing at it.

### Shared Secret

One existing Secret holds every credential. The chart references it by name and never renders it. Create it in the namespace of the release:

```sh
kubectl create secret generic opsie-email-shared \
  --from-literal=routes-token="$(openssl rand -hex 32)" \
  --from-literal=attachments-secret="$(openssl rand -hex 32)"
```

| Key | Read by Opsie | Read by opsie-email |
| --- | --- | --- |
| `routes-token` | accepted as route sync bearer token | sent as route sync bearer token |
| `routes-token-next` (optional) | also accepted | not read |
| `attachments-secret` | sent as attachment API bearer token | verified |

Secrets reach the pods as environment variables, so a changed Secret needs a restart of both Deployments.

Rotating the route sync token takes three steps and causes no outage:

1. Add the new token as `routes-token-next` and restart Opsie.
2. Set `routes-token` to the new token and `routes-token-next` to the old one, then restart Opsie and opsie-email in any order.
3. Remove `routes-token-next` and restart Opsie.

### Blob storage

| Provider | Needs |
| --- | --- |
| `azure` | `email.blob.azure.container`; `email.blob.azure.accountUrl` for `workload-identity` (default) and `sas` |
| `s3` | `email.blob.s3.bucket` and `email.blob.s3.region` or `email.blob.s3.endpoint` |
| `filesystem` | `email.blob.filesystem.existingClaim`, mounted at `/data/blobs`; more than one replica needs a `ReadWriteMany` volume |

`email.blob.existingSecret` holds the blob credentials and is not used with the filesystem provider or Azure workload identity:

| Key | Used when |
| --- | --- |
| `azure-connection-string` | `email.blob.azure.auth: connection-string` |
| `azure-sas-token` | `email.blob.azure.auth: sas` |
| `s3-access-key-id`, `s3-secret-access-key` | `email.blob.provider: s3`; leave `email.blob.existingSecret` empty to use the default AWS credential chain |

With `email.blob.azure.auth: workload-identity` the opsie-email pods get the label `azure.workload.identity/use: "true"` and no blob Secret is mounted. The ServiceAccount of the release needs the annotation `azure.workload.identity/client-id` (and optionally `azure.workload.identity/tenant-id`), set through `serviceAccount.annotations` or present on the existing account when `serviceAccount.create` is `false`. Give the federated identity the `Storage Blob Data Contributor` role on the container.

### Route sync and the internal Service

With `email.enabled` the chart renders the ClusterIP Service `<base>-internal` (`opsie-internal`). It selects the part that serves route sync (`all`, or `app` in the split topologies), so opsie-email reads its routes from `http://opsie-internal:8090/api/internal/mail-routes` whatever the topology. opsie-email delivers mail to the part that serves `POST /api/events` (`<base>` in `all-in-one`, `<base>-ingest` otherwise) on port 80. Both URLs are derived. Neither the internal Service nor the internal port is referenced by `ingresses` or `httpRoutes`.

### Network policy

With `email.networkPolicy.enabled` (default) the chart renders:

- for the pods behind `<base>-internal`: an ingress policy that keeps the HTTP (and HTTPS) port open to everyone and allows the internal port only from the opsie-email pods and from `email.networkPolicy.metricsPeers`. Because the same port serves unauthenticated `/metrics`, list the Prometheus pods or namespace there;
- for the opsie-email pods, `<base>-email-ingress`: port 2525 from anywhere, the attachment API only from the Opsie pods that serve route sync, the metrics port only from `email.networkPolicy.metricsPeers` (closed while the list is empty);
- for the opsie-email pods, `<base>-email-egress`: DNS, the Opsie pods on port 8080 (intake) and `internal.port` (route sync), the blob endpoint (`email.networkPolicy.emailEgress.blobTo` and `blobPort`, omitted for the filesystem provider) and, with workload identity, port 443 to `email.networkPolicy.emailEgress.entraTo`.

```yaml
email:
  networkPolicy:
    metricsPeers:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: monitoring
```

Rendering fails when `metrics.serviceMonitor.enabled` and the policy are both on and `metricsPeers` is empty, because scraping would stop silently. A NetworkPolicy cannot match host names. The defaults for `blobTo` and `entraTo` allow any address on the port; narrow them to the CIDRs of your storage account and `login.microsoftonline.com`, or to an in-cluster object store. The policies only work with a CNI that enforces NetworkPolicy. `email.networkPolicy.egress.enabled` adds `<base>-internal-egress`, an Egress policy that lets the Opsie pods behind `<base>-internal` reach the attachment API; an Egress policy isolates all other egress of the pods (database, Valkey, DNS), so enable it only together with your own egress rules.

### Removed values

Rendering fails with a message that names the value while one of these is set: `email.attachments.url` (the URL is derived), `email.networkPolicy.opsieEmail` (the pods are selected by their labels) and `email.networkPolicy.egress.attachmentsPort` (use `email.service.attachments.port`).

## Rego helpers

Routing rules of type `rego` can call helper functions written in Rego. Put them in a ConfigMap with one `*.rego` file per helper package and mount it with `rego.helpers.existingConfigMap`:

```yaml
rego:
  helpers:
    existingConfigMap: opsie-rego-lib
```

| Value | Purpose |
| --- | --- |
| `rego.helpers.existingConfigMap` | ConfigMap with the helper files, mounted read-only on every part; sets `REGO_HELPERS_DIR` |
| `rego.helpers.mountPath` | Mount path and value of `REGO_HELPERS_DIR` (default `/etc/opsie/rego-lib`) |
| `rego.evalTimeout` | `REGO_EVAL_TIMEOUT`: time limit of one rule evaluation; empty keeps the application default |
| `rego.cacheBytes` | `REGO_CACHE_BYTES`: size limit of the compiled script cache; empty keeps the application default |

Only the top level of the folder is read. Every package must start with `custom` (`package custom.text`); scripts import them with `import data.custom.text`. The application watches the folder and loads a changed set as a whole or not at all, so a ConfigMap change rolls out without a restart. Replicas can briefly use different helper sets while the ConfigMap propagates. A folder that is missing at start is not retried until restart.

## Authentication

- `JWT_SECRET` comes from `auth.jwt.existingSecret`. Rotation is a Secret change (`jwt-secret`, `jwt-secret-next`, `jwt-secret-previous`) followed by a restart; see [rotating JWT_SECRET](https://github.com/AB-Lindex/opsie/blob/main/docs/deployment.md#rotating-jwt_secret).
- OIDC is configured with `auth.oidc.issuer`, `auth.oidc.scopes` and the client Secret. The redirect URL defaults to `https://<first host>/api/auth/callback`, from the first `ingresses` entry with a host, else the first `httpRoutes` hostname. With several entries, set `auth.oidc.redirectUrl` explicitly.
- `auth.sessionCacheTtl` sets `SESSION_CACHE_TTL` (at most 30s; the application default is 15s, `0` switches the cache off) and `auth.sessionCacheStaleGrace` sets `SESSION_CACHE_STALE_GRACE` (at most 15s, default 15s, `0` disables stale serving) for the parts that run `api`.
- `auth.adminEmail.existingConfigMap` mounts the admin email file; `themes.existingConfigMap` mounts custom themes at `/app/themes/custom`.
- `branding.environmentName` (with optional `branding.environmentColor`) shows a stamp such as DEV or QA above the sidebar menu; `branding.companyLogoUrl` shows a logo at the bottom of the sidebar. All are optional and reach the parts that run `api`.
- `shareLinks.enabled` turns on alert share links: a Share button on the alert card, and links the system itself can put in notifications. `shareLinks.publicBaseUrl` (`PUBLIC_BASE_URL`, scheme and host only) is the address users and chat services reach Opsie on. When empty, the chart uses `https://<first host>` from the first `ingresses` entry with a host, else the first `httpRoutes` hostname, and refuses to render if there is none. `shareLinks.lifetime` (`SHARE_LINK_LIFETIME`, for example `336h`) is optional. The variables reach every part through the ConfigMap.

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
  2. No Valkey source is selected (valkey.enabled, valkeySentinel.enabled, redis.enabled). Set valkey.enabled=true for the bundled standalone sub-chart, valkeySentinel.enabled=true for the bundled Sentinel setup, or redis.enabled=true with redis.addr for an external Valkey/Redis.
```

`httpRoutes` are additionally checked against the cluster's Gateway API. That check is skipped by plain `helm template`; add `--api-versions apps/v1/Deployment` to simulate a cluster.

## Values reference

Every value is documented in [values.yaml](values.yaml). The top-level keys are:

| Key | Purpose |
| --- | --- |
| `fullnameOverride`, `nameOverride` | Resource naming |
| `image` | Repository, tag, pull policy and pull secrets |
| `topology`, `parts`, `topologySpread`, `strategy`, `terminationGracePeriodSeconds`, `podDisruptionBudget` | Parts, replicas, scheduling and rollout |
| `serviceAccount` | The shared ServiceAccount |
| `database` | Type, connection Secret and migration |
| `valkey`, `valkeySentinel`, `redis` | The Valkey source |
| `auth`, `themes` | JWT, OIDC, session cache, admin emails and themes |
| `branding` | Optional environment stamp and company logo |
| `shareLinks` | Alert share links: switch, public base URL, lifetime |
| `tls` | TLS mode |
| `alerts` | Alert tuning |
| `rego` | Rego routing rules: helper folder, evaluation timeout, cache size |
| `metrics` | ServiceMonitor |
| `internal` | Port of the internal listener (`/metrics`, mail route sync) |
| `email` | Email integration: the opsie-email Deployment, its image, blob storage, Services, shared Secret and network policies |
| `sse` | Server-Sent Events stream: caps, kill switch and stream routing |
| `alertEvents` | Alert change notifications on the stream: opt-out switch |
| `podLabels`, `podAnnotations`, `extraEnv`, `extraEnvFrom`, `resources`, `podSecurityContext`, `securityContext` | Settings for every part |
| `ingresses`, `httpRoutes` | External routing |
| `extraObjects` | Extra manifests |
