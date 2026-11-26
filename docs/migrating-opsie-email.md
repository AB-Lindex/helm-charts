# Migrating from the opsie-email chart to the opsie chart

From `opsie` chart 0.8.0 the opsie-email Deployment, its Services and its NetworkPolicies are part of the `opsie` chart (`email.enabled: true`). The separate `opsie-email` chart is deprecated and is no longer developed. This guide moves an existing installation, one Argo CD `Application` pair per environment, to the single chart.

## Contents

- [What changes](#what-changes)
- [Impact](#impact)
- [Value mapping](#value-mapping)
- [Values per environment](#values-per-environment)
- [Procedure](#procedure)
- [Verification](#verification)
- [Rollback](#rollback)
- [Differences to be aware of](#differences-to-be-aware-of)
- [Findings in the current values files](#findings-in-the-current-values-files)

## What changes

| | Before | After |
| --- | --- | --- |
| Charts | `opsie` and `opsie-email`, two releases and two Applications | `opsie` only |
| Deployment, Services | `opsie-email`, `opsie-email-smtp`, `opsie-email-metrics` | the same names, rendered by the `opsie` chart |
| Pod labels | `app.kubernetes.io/name: opsie-email`, `app.kubernetes.io/instance: opsie-email` | `app.kubernetes.io/name: opsie`, `app.kubernetes.io/instance: opsie`, `app.kubernetes.io/component: email` |
| Route snapshot URL, intake URL | `routes.url`, `opsie.intakeUrl` | derived from the Services of the release |
| Attachment API URL in Opsie | `email.attachments.url` | derived: `http://opsie-email:8082` |
| ServiceAccount | its own `serviceAccount` values (the current values use the existing account `opsie`) | the ServiceAccount of the release (`serviceAccount`, currently `opsie`) |
| Values of opsie-email | top level of its own values file | under `email.` in the values of `opsie` |

The names of the Deployment and the three Services do not change, so the attachment API stays at `http://opsie-email:8082` and the public Service keeps its load balancer settings. The selector of a Deployment is immutable and the pod labels change, so Argo CD cannot take the existing Deployment over: the old Application must be removed before the new chart creates its replacement.

## Impact

- **SMTP intake is down** from the moment the old Application is removed until the new pod is ready and the load balancer is back, normally a few minutes. Sending mail servers queue and retry, so mail is delayed, not lost. Do it outside business hours anyway.
- **The public IP is kept.** It is the Azure public IP resource named in `service.beta.kubernetes.io/azure-pip-name`, which Kubernetes does not delete with the Service. The MX record does not change.
- **The Opsie pods are not restarted by the chart change.** Rendering the current values with chart 0.8.0 gives identical Opsie resources (including `EMAIL_ATTACHMENT_API_URL`); only the opsie-email resources are added. The pods roll only if you also change `image.tag`.
- **No data moves.** Attachments stay in the existing blob container, and the shared Secret `opsie-email` is rendered by the `opsie` Application (`extraObjects`) and is not touched.
- **No new federated credential.** opsie-email already runs as the ServiceAccount `opsie`, which is also the account of Opsie, so the subject `system:serviceaccount:techsvc:opsie` is unchanged.

## Value mapping

| opsie-email chart | `opsie` chart | Note |
| --- | --- | --- |
| `fullnameOverride: opsie-email` | remove | The name is `<base>-email`, `opsie-email` with `fullnameOverride: opsie` |
| `image.repository`, `image.tag`, `image.pullPolicy` | `email.image.repository`, `email.image.tag`, `email.image.pullPolicy` | The tag is required; there is no `appVersion` fallback |
| `image.pullSecrets` | `image.pullSecrets` | Shared with Opsie; the current values already list `dockerkey` in both |
| `existingSecret` | `email.existingSecret` | Already set in the Opsie values, same Secret |
| `replicaCount` | `email.replicaCount` | |
| `routes.url` | remove | Derived: `http://opsie-internal:8090/api/internal/mail-routes` |
| `routes.pollInterval`, `routes.maxAge` | `email.routes.pollInterval`, `email.routes.maxAge` | |
| `opsie.intakeUrl` | remove | Derived: `http://opsie-ingest:80` (`http://opsie:80` in `all-in-one`) |
| `forwardTimeout`, `logLevel` | `email.forwardTimeout`, `email.logLevel` | |
| `smtp.*` | `email.smtp.*` | `acceptDomains` defaults to `email.domain` when empty |
| `blob.*` | `email.blob.*` | Same structure |
| `service.smtp.*`, `service.attachments.port`, `service.metrics.port` | `email.service.*` | Same structure |
| `serviceAccount.*` | remove | opsie-email uses `serviceAccount` of the release. Annotations for workload identity belong there |
| `networkPolicy.enabled`, `networkPolicy.metricsPeers` | `email.networkPolicy.enabled`, `email.networkPolicy.metricsPeers` | One switch and one peer list for all email policies |
| `networkPolicy.opsie.*` | remove | The Opsie pods are selected by their labels |
| `networkPolicy.egress.blobTo`, `blobPort`, `entraTo` | `email.networkPolicy.emailEgress.blobTo`, `blobPort`, `entraTo` | |
| `podLabels`, `podAnnotations`, `extraEnv`, `resources`, `nodeSelector`, `tolerations`, `affinity`, `podSecurityContext`, `securityContext`, `terminationGracePeriodSeconds` | the same names under `email.` | |

In the Opsie values, remove `email.attachments.url`, `email.networkPolicy.opsieEmail` and `email.networkPolicy.egress.attachmentsPort`. Rendering fails with a message that names the value while one of them is set. A set `email.networkPolicy.egress.enabled` now renders the policy `opsie-internal-egress` instead of `opsie-email-egress`, because the name `opsie-email-egress` now belongs to the egress policy of the opsie-email pods.

## Values per environment

The `valuesObject` of the `opsie` Application changes as follows. The change is the same for both environments; only the four environment-specific values differ.

```yaml
        email:
          # attachments:                       # removed
          #   url: http://opsie-email:8082
          domain: <domain>                     # unchanged
          enabled: true                        # unchanged
          existingSecret: opsie-email          # unchanged
          networkPolicy:
            enabled: false                     # unchanged
          image:                               # new, from the opsie-email Application
            repository: lindexacrdev.azurecr.io/techsvc/opsie-email
            tag: v0.3
          replicaCount: 1                      # new
          smtp:                                # new
            domain: <domain>
          blob:                                # new
            azure:
              accountUrl: <blob account URL>
              container: attachments
          service:                             # new
            smtp:
              annotations:
                service.beta.kubernetes.io/azure-load-balancer-resource-group: <resource group>
                service.beta.kubernetes.io/azure-pip-name: <public IP name>
```

| Value | dev (`cloud1-dev`) | prod (`atlas`) |
| --- | --- | --- |
| `<domain>` (`email.domain`, `email.smtp.domain`) | `opsie.cloud1-dev.lindex.com` | `opsie.lindex.net` |
| `<blob account URL>` | `https://cloud1devopsieemailblobs.blob.core.windows.net` | `https://atlasopsieemailblobs.blob.core.windows.net` |
| `<resource group>` | `aks-cloud1-dev-rg` | `aks-atlas-rg` |
| `<public IP name>` | `cloud1-dev-opsie-email-ip` | `atlas-opsie-email-ip` |

`email.smtp.acceptDomains` is no longer needed: its old value was the email domain, which is now the default. Set it only when opsie-email must accept more domains.

Also change `metadata.labels.version` and `spec.source.targetRevision` of the `opsie` Application from `v0.7.1` to `v0.8.0`.

The values of opsie-email, the Application `opsie-email` and its `targetRevision: v0.1.0` are not needed after the migration.

## Procedure

Do the steps for dev first, check it, then repeat for prod.

1. **Prepare.** Check that chart 0.8.0 of `opsie` is published in the Helm repository (`helm search repo ab-lindex/opsie --versions`). Prepare the change of the `opsie` Application from the section above, but do not sync it. If the Application is defined in a GitOps repository, keep the change on a branch.
2. **Render before you apply.** With the new `valuesObject` extracted to a file, check the result:

   ```sh
   helm template opsie ab-lindex/opsie --version 0.8.0 --namespace techsvc -f new-values.yaml \
     --api-versions apps/v1/Deployment --api-versions gateway.networking.k8s.io/v1 >/dev/null
   ```

   Errors name the value to change.
3. **Remove the old Application with its resources.** The Application manifests in `values/` have no `resources-finalizer.argocd.argoproj.io` finalizer, so `kubectl delete application` would leave the Deployment and the Services behind. Use the CLI, which deletes the resources too:

   ```sh
   argocd app delete opsie-email --cascade
   kubectl --namespace techsvc get deployment,service -l app.kubernetes.io/instance=opsie-email
   ```

   The second command must list nothing before you continue. If the Application is defined in a GitOps repository, remove the definition there as well, or Argo CD creates it again.
4. **Update and sync the `opsie` Application** with the new `targetRevision` and values. The sync creates the Deployment `opsie-email` and the three Services. The ExternalSecret `opsie-email` already exists and is unchanged.
5. **Verify** with the checks below.
6. **Clean up.** Archive `values/opsie-email-dev.yaml` and `values/opsie-email-prod.yaml` and update `values/opsie-app-*.yaml` to the new values, so the folder matches the clusters.

## Verification

```sh
kubectl --namespace techsvc rollout status deployment/opsie-email
kubectl --namespace techsvc get pods -l app.kubernetes.io/component=email
kubectl --namespace techsvc get service opsie-email-smtp opsie-email opsie-email-metrics
kubectl --namespace techsvc logs deployment/opsie-email | tail
```

- The pod is `Ready`. It only becomes ready after the first route snapshot, so this proves the route sync URL and the shared Secret.
- `opsie-email-smtp` has the old `EXTERNAL-IP` (the public IP named in `azure-pip-name`).
- Send a test mail to `alerts+<integration key>@<domain>` and check that the alert appears in Opsie. With an attachment, also check that it can be opened, which proves the attachment API and the blob access (workload identity).
- `argocd app get opsie` is `Synced` and `Healthy`, and no resource is marked as owned by another Application.

## Rollback

Until step 3 nothing has changed in the cluster; drop the prepared change. After step 3:

1. Set the `opsie` Application back to `targetRevision: v0.7.1` with the previous values (with `email.attachments.url`, without the new `email.` values), and sync. This removes the new Deployment and Services.
2. Create the `opsie-email` Application again from `values/opsie-email-<env>.yaml`.

The data (blob container, Secret, public IP) is the same in both directions.

## Differences to be aware of

- **Topology spread.** The `opsie` chart spreads the pods of every component over `topologySpread.constraints` (by default `agentpool`, `ScheduleAnyway`). opsie-email now follows it; the old chart had no constraint. Replace it with `email.topologySpreadConstraints`, or switch it off for everything with `topologySpread.enabled: false`.
- **Rollout.** The Deployment uses the `strategy` of the release (`maxSurge: 1`, `maxUnavailable: 0`), the same as the old chart.
- **Pod labels.** Global `podLabels` and `podAnnotations` of the `opsie` values now reach the opsie-email pods too. They are empty in the current values.
- **ServiceMonitor.** The ServiceMonitor of the `opsie` chart scrapes the internal port of the Opsie parts only, as before; opsie-email metrics are not scraped by it. The old chart had no ServiceMonitor either.
- **Network policies.** They stay off with `email.networkPolicy.enabled: false`, as in the current values. When you enable them, one switch renders the policies of Opsie and of opsie-email; see the chart README.
- **ServiceAccount.** opsie-email always runs as the ServiceAccount of the release; a separate account for it is not offered. The current setup already shares the account `opsie`.

## Findings in the current values files

- `values/opsie-app-prod.yaml` is identical to `values/opsie-app-dev.yaml`: it names `cloud1-dev`, the dev domain, the dev Key Vault and the dev client id. It looks like a copy. Do not use it as the base for prod; take the prod Application from the cluster and apply the same change to it. The prod values of opsie-email (`atlas`) are used in the table above.
- The `values/` folder is listed in `.gitignore`, so it is not part of the repository and was not changed. This guide is the only record of the changes.
