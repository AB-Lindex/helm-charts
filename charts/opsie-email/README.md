# opsie-email Helm Chart

Deploys [opsie-email](https://github.com/AB-Lindex/opsie-email), the SMTP front end of the Opsie email integration. It accepts mail for `alerts+<integration key>@<domain>`, forwards it to Opsie as an alert envelope, stores attachments in blob storage and serves them back to Opsie.

## Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Required Secrets](#required-secrets)
- [Blob storage](#blob-storage)
- [Services](#services)
- [Network policy](#network-policy)
- [Pairing with the opsie chart](#pairing-with-the-opsie-chart)
- [Values reference](#values-reference)

## Prerequisites

- Helm 3 and Kubernetes 1.32 or newer.
- A running Opsie release with `email.enabled: true` (chart `opsie`), in the same namespace or with the shared Secret replicated.
- A blob store: Azure Blob Storage, S3-compatible storage, or a `ReadWriteMany` volume. The `memory` provider is never offered.
- Public port 25 reachable on a static IP, and an MX record for the email domain pointing at it.

## Installation

```sh
helm install opsie-email ab-lindex/opsie-email -f values.yaml
```

The default resource names (`opsie-email`, `opsie-email-smtp`, `opsie-email-metrics`) come from `fullnameOverride: opsie-email`. The attachment Service is then reachable at `http://opsie-email:8082`, the value the `opsie` chart expects in `email.attachments.url`.

A minimal values file for Azure with workload identity:

```yaml
image:
  repository: registry.example/opsie-email
  tag: v1.2.3
existingSecret: opsie-email-shared
routes:
  url: http://opsie-internal:8090/api/internal/mail-routes
opsie:
  intakeUrl: http://opsie:80
smtp:
  acceptDomains: [mail.example.com]
blob:
  provider: azure
  azure:
    container: opsie-email
    accountUrl: https://account.blob.core.windows.net
serviceAccount:
  annotations:
    azure.workload.identity/client-id: 00000000-0000-0000-0000-000000000000
service:
  smtp:
    loadBalancerIP: 203.0.113.10
    annotations:
      service.beta.kubernetes.io/azure-pip-name: opsie-email
      service.beta.kubernetes.io/azure-load-balancer-resource-group: rg-opsie
```

## Required Secrets

The chart references Secrets by name and never renders one.

`existingSecret` is the Secret shared with the `opsie` release (same name as `email.existingSecret` there):

| Key | Purpose |
| --- | --- |
| `routes-token` | Bearer token for route sync, at least 32 characters |
| `attachments-secret` | Bearer secret that Opsie sends to the attachment API, at least 32 characters |

`blob.existingSecret` holds the blob credentials and is not used with the filesystem provider or Azure workload identity:

| Key | Used when |
| --- | --- |
| `azure-connection-string` | `blob.azure.auth: connection-string` |
| `azure-sas-token` | `blob.azure.auth: sas` |
| `s3-access-key-id`, `s3-secret-access-key` | `blob.provider: s3`; leave `blob.existingSecret` empty to use the default AWS credential chain |

Secrets reach the pod as environment variables, so a changed Secret needs a restart. Rotation of the shared Secret is described in the `opsie` chart README.

## Blob storage

| Provider | Needs |
| --- | --- |
| `azure` | `blob.azure.container`; `blob.azure.accountUrl` for `workload-identity` and `sas` |
| `s3` | `blob.s3.bucket` and `blob.s3.region` or `blob.s3.endpoint` |
| `filesystem` | `blob.filesystem.existingClaim`, mounted at `/data/blobs` |

With `blob.azure.auth: workload-identity` (default) the pod gets the label `azure.workload.identity/use: "true"` and no blob Secret is mounted. Annotate the ServiceAccount through `serviceAccount.annotations` with `azure.workload.identity/client-id` (required, enforced by the schema) and optionally `azure.workload.identity/tenant-id`, and give the federated identity the `Storage Blob Data Contributor` role on the container. With `serviceAccount.create: false` the annotation is expected on the existing account.

## Services

| Service | Type | Port | Purpose |
| --- | --- | --- | --- |
| `<base>-smtp` | `LoadBalancer`, `externalTrafficPolicy: Local` | 25 to 2525 | Public mail intake. `Local` keeps the client address that route `allowedRanges` check. |
| `<base>` | `ClusterIP` | 8082 | Attachment API for Opsie |
| `<base>-metrics` | `ClusterIP` | 9090 | Prometheus metrics, keep cluster-internal |

Probes use the HTTP port 8080 (`/healthz`, `/readyz`); the pod is not ready until the first route snapshot is loaded.

## Network policy

With `networkPolicy.enabled` (default) the chart renders:

- an ingress policy: port 2525 from anywhere, the attachment API only from the Opsie pods (`networkPolicy.opsie`), the metrics port only from `networkPolicy.metricsPeers` (closed while the list is empty);
- an egress policy: DNS, the Opsie pods on `networkPolicy.opsie.ports` (8080 intake, 8090 route sync), the blob endpoint (`networkPolicy.egress.blobTo` and `blobPort`, omitted for the filesystem provider) and, with workload identity, port 443 to `networkPolicy.egress.entraTo`.

A NetworkPolicy cannot match host names. The defaults for `blobTo` and `entraTo` allow any address on the port; narrow them to the CIDRs of your storage account and `login.microsoftonline.com`, or to an in-cluster object store. The policies need a CNI that enforces NetworkPolicy.

## Pairing with the opsie chart

| `opsie` chart | This chart |
| --- | --- |
| `email.existingSecret` | `existingSecret` (same Secret, same keys) |
| `email.attachments.url: http://opsie-email:8082` | Service `<base>` on port 8082 |
| `email.networkPolicy.opsieEmail` (label `app.kubernetes.io/name: opsie-email`) | pod labels of this chart |
| `http://opsie-internal:8090/api/internal/mail-routes` | `routes.url` |
| Service `opsie` (port 80) or `opsie-ingest` | `opsie.intakeUrl` |

## Values reference

Every value is documented in [values.yaml](values.yaml); [values.schema.json](values.schema.json) rejects a missing `existingSecret`, the `memory` provider and workload identity without a client id. Further checks run at render time and name the value to change.
