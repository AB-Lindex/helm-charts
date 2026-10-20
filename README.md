# helm-charts

Helm charts maintained by AB-Lindex.

## Charts

| Chart | Description |
| --- | --- |
| [etcd-backup](charts/etcd-backup/README.md) | CronJob that backs up an etcd cluster to local or S3-compatible storage |
| [opsie](charts/opsie/README.md) | Opsie on-call and alert management with external MSSQL or PostgreSQL and Valkey |
| [opsie-email](charts/opsie-email/README.md) | SMTP front end of the Opsie email integration with blob storage for attachments |

## Usage

The charts are published as a Helm repository:

```sh
helm repo add ab-lindex https://ab-lindex.github.io/helm-charts/
helm repo update
helm search repo ab-lindex
```
