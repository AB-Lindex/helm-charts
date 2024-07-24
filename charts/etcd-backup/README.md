# etcd-backup Helm Chart

This Helm chart facilitates automated backups of an etcd cluster to local storage or an S3-compatible storage solution. The chart can be configured to use PersistentVolumeClaims (PVCs), custom PersistentVolumes (PVs), or hostPaths for storing backups.

## Prerequisites

- Helm 3.0+
- Access to an S3-compatible storage service (if using S3 for backups)
- `kubeseal` CLI (if using SealedSecrets for storing sensitive information)

## Installation

1. **Add the Helm Repository**:
   Add the Helm repository that hosts the `etcd-backup` chart.
   
   ```sh
   helm repo add ab-lindex https://ab-lindex.github.io/helm-charts/
   helm repo update
   ```

2. **Install the Chart**:
   Install the chart with the release name `my-etcd-backup`:
   
   ```sh
   helm install my-etcd-backup ab-lindex/etcd-backup
   ```

3. **Custom Configuration**:
   You can customize the installation by creating a `values.yaml` file and specifying your values:
   
   ```sh
   helm install my-etcd-backup ab-lindex/etcd-backup -f values.yaml
   ```

## Configuration

The following table lists the configurable parameters of the `etcd-backup` chart and their default values.

| Setting                               | Default Value                            | Description                                                                                               |
|---------------------------------------|------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| `schedule`                            | `"0 5 * * *"`                            | The cron job schedule for backups.                                                                        |
| `s3.awsCliImage`                      | `"amazon/aws-cli:2.17.3"`                | The AWS CLI Docker image used for uploading to S3.                                                        |
| `s3.s3EndpointUrl`                    | `"http://minio.minio.svc.cluster.local:9000"` | The endpoint URL for the S3 service.                                                                  |
| `s3.enabled`                          | `false`                                  | Enables or disables S3 backups.                                                                           |
| `s3.bucketName`                       | `"etcd"`                                 | The S3 bucket name where backups will be stored.                                                          |
| `s3.existingSecret`                   | `false`                                  | Use an existing secret for S3 credentials.                                                                |
| `s3.createSecret`                     | `true`                                   | Create a new secret for S3 credentials.                                                                   |
| `s3.sealedSecret`                     | `false`                                  | Use SealedSecret for S3 credentials.                                                                      |
| `s3.secretName`                       | `"s3-secret"`                            | The name of the secret for S3 credentials.                                                                |
| `s3.accessKey`                        | `""`                                     | The S3 access key (base64 encoded if not using SealedSecret). To base64 encode: `echo -n 'your-access-key' \| base64`.<br>If using SealedSecret: `echo -n 'your-access-key' \| kubeseal --raw --from-file=/dev/stdin --namespace your-namespace --name s3-secret --scope cluster-wide` |
| `s3.secretKey`                        | `""`                                     | The S3 secret key (base64 encoded if not using SealedSecret). To base64 encode: `echo -n 'your-secret-key' \| base64`.<br>If using SealedSecret: `echo -n 'your-secret-key' \| kubeseal --raw --from-file=/dev/stdin --namespace your-namespace --name s3-secret --scope cluster-wide` |
| `s3.rotateInS3`                       | `false`                                  | Enables rotation of backups in S3.                                                                        |
| `s3.keepInS3Count`                    | `45`                                     | Number of backups to keep in S3.                                                                          |
| `backup.etcdBackupImage`              | `"quay.io/coreos/etcd:v3.5.6"`           | The image used for etcd backups.                                                                          |
| `backup.claimName`                    | `"etcd-backup-pvc"`                      | The name of the PersistentVolumeClaim.                                                                    |
| `backup.rotateOnDisk`                 | `false`                                  | Enables rotation of backups on disk.                                                                      |
| `backup.keepOnDiskCount`              | `30`                                     | Number of backups to keep on disk.                                                                        |
| `backup.pvc.enable`                   | `false`                                  | Use PVC for backup storage.                                                                               |
| `backup.pvc.storageClassName`         | `"standard"`                             | The storage class for the PVC.                                                                            |
| `backup.pvc.accessModes`              | `["ReadWriteOnce"]`                      | The access modes for the PVC.                                                                             |
| `backup.pvc.resources.requests.storage` | `10Gi`                                 | The storage size requested for the PVC.                                                                   |
| `backup.customPV.enable`              | `false`                                  | Use custom PV for backup storage.                                                                         |
| `backup.customPV.name`                | `"etcd-custom-pv"`                       | The name of the custom PV.                                                                                |
| `backup.customPV.storageClassName`    | `"smb"`                                  | The storage class for the custom PV.                                                                      |
| `backup.customPV.reclaimPolicy`       | `"Retain"`                               | The reclaim policy for the custom PV.                                                                     |
| `backup.customPV.driver`              | `"smb.csi.k8s.io"`                       | The CSI driver for the custom PV.                                                                         |
| `backup.customPV.useSealedSecret`     | `false`                                  | Use SealedSecret for custom PV credentials.                                                               |
| `backup.customPV.secretName`          | `"etcd-pv-secret"`                       | The name of the secret for custom PV credentials.                                                         |
| `backup.customPV.username`            | `""`                                     | The username for the custom PV (base64 encoded if not using SealedSecret). To base64 encode: `echo -n 'your-username' \| base64`.<br>If using SealedSecret: `echo -n 'your-username' \| kubeseal --raw --from-file=/dev/stdin --namespace your-namespace --name etcd-pv-secret --scope cluster-wide` |
| `backup.customPV.password`            | `""`                                     | The password for the custom PV (base64 encoded if not using SealedSecret). To base64 encode: `echo -n 'your-password' \| base64`.<br>If using SealedSecret: `echo -n 'your-password' \| kubeseal --raw --from-file=/dev/stdin --namespace your-namespace --name etcd-pv-secret --scope cluster-wide` |
| `backup.customPV.accessModes`         | `["ReadWriteOnce"]`                      | The access modes for the custom PV.                                                                       |
| `backup.customPV.resources.requests.storage` | `10Gi`                           | The storage size requested for the custom PV.                                                             |
| `backup.customPV.mountOptions`        | `["dir_mode=0777", "file_mode=0777"]`    | The mount options for the custom PV.                                                                      |
| `backup.customPV.options`             | `{}`                                     | Additional options for the custom PV.                                                                     |
| `backup.hostPath.enable`              | `false`                                  | Use hostPath for backup storage.                                                                          |
| `backup.hostPath.path`                | `"/var/lib/etcd-backup"`                 | The path on the host for backup storage.                                                                  |
| `hostPaths.etcdCerts`                 | `"/run/config/pki/etcd"`                 | Host paths for etcd certificates.                                                                         |

### SealedSecret Instructions

If you are using SealedSecrets for your S3 or PV credentials, follow these steps to generate the necessary values:

1. **Install kubeseal**: Ensure that you have `kubeseal` installed on your local machine. You can install it from the [SealedSecrets GitHub page](https://github.com/bitnami-labs/sealed-secrets).

2. **Generate Encrypted Secrets**:
   - **Generate Encrypted S3 Access Key**:
     ```sh
     echo -n 'your-access-key' \| kubeseal --raw --from-file=/dev/stdin --namespace your-namespace --name s3-secret --scope cluster-wide
     ```
   - **Generate Encrypted S3 Secret Key**:
     ```sh
     echo -n 'your-secret-key' \| kubeseal --raw --from-file=/dev/stdin --namespace your-namespace --name s3-secret --scope cluster-wide
     ```

3. **Replace the Access Key and Secret Key in values.yaml**:
   Copy the encrypted values generated by `kubeseal` and paste them into your `values.yaml` file.

   ```yaml
   s3:
     accessKey: <encrypted-access-key>
     secretKey: <encrypted-secret-key>
   ```

4. **Generate Encrypted Custom PV Credentials** (if needed):
   - **Generate Encrypted Username**:
     ```sh
     echo -n 'your-username' \| kubeseal --raw --from-file=/dev/stdin --namespace your-namespace --name etcd-pv-secret --scope cluster-wide
     ```
   - **Generate Encrypted Password**:
     ```sh
     echo -n 'your-password' \| kubeseal --raw --from-file=/dev/stdin --namespace your-namespace --name etcd-pv-secret --scope cluster-wide
     ```

5. **Replace the Username and Password in values.yaml**:
   Copy the encrypted values generated by `kubeseal` and paste them into your `values.yaml` file.

   ```yaml
   customPV:
     username: <encrypted-username>
     password: <encrypted-password>
   ```

6. **Important Note**:
   Ensure you generate the encrypted values in the correct cluster and namespace. SealedSecrets are tied to the namespace and cluster where they are created. If you switch clusters or namespaces, you will need to regenerate the encrypted values.

## Usage Examples

To install the chart with custom values:

```sh
helm install my-etcd-backup ab-lindex/etcd-backup -f values.yaml
```

To enable S3 backups and use an existing secret for credentials:

```yaml
s3:
  enabled: true
  existingSecret: true
  secretName: my-existing-s3-secret
```

To use a custom PersistentVolume for backup storage:

```yaml
backup:
  customPV:
    enable: true
    name: "etcd-custom-pv"
    storageClassName: "smb"
    reclaimPolicy: "Retain"
    driver: "smb.csi.k8s.io"
    useSealedSecret: false
    secretName: "etcd-pv-secret"
    username: "your-username"
    password: "your-password"
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
    mountOptions:
      - dir_mode=0777
      - file_mode=0777
    options: {}
```

## Support and Contributions

For support, please open an issue on the [GitHub repository](https://github.com/AB-Lindex/helm-charts).
