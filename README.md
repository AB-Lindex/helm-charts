# helm-charts

Helm charts maintained by AB-Lindex.

## Charts

| Chart | Description |
| --- | --- |
| [etcd-backup](charts/etcd-backup/README.md) | CronJob that backs up an etcd cluster to local or S3-compatible storage |
| [opsie](charts/opsie/README.md) | Opsie on-call and alert management with external MSSQL or PostgreSQL and Valkey, optionally with the opsie-email SMTP front end |
| [opsie-email](charts/opsie-email/README.md) | Deprecated: part of the `opsie` chart from 0.8.0, see the [migration guide](docs/migrating-opsie-email.md) |

## Usage

The charts are published as a Helm repository:

```sh
helm repo add ab-lindex https://ab-lindex.github.io/helm-charts/
helm repo update
helm search repo ab-lindex
```
