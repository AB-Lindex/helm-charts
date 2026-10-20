{{/*
Collects every configuration problem the schema does not cover and reports them in one failure.
Message form: <what is wrong> (<value path>). <what to do>.
*/}}
{{- define "opsie-email.validate" -}}
{{- $v := .Values }}
{{- $errs := list }}

{{- if or (not $v.image.repository) (eq (toString $v.image.repository) "TBD") }}
{{- $errs = append $errs (printf "image.repository is not set (image.repository, currently %q). Set image.repository to the opsie-email image you want to run." (toString $v.image.repository)) }}
{{- end }}

{{- if not $v.routes.url }}
{{- $errs = append $errs "No route snapshot URL is set (routes.url). Set it to the mail-routes endpoint of Opsie, for example http://opsie-internal:8090/api/internal/mail-routes." }}
{{- end }}

{{- if not $v.opsie.intakeUrl }}
{{- $errs = append $errs "No Opsie intake URL is set (opsie.intakeUrl). Set it to the base URL of the Opsie Service that serves /api/events, for example http://opsie:80." }}
{{- end }}

{{- if eq $v.blob.provider "azure" }}
{{- if not $v.blob.azure.container }}
{{- $errs = append $errs "No Azure container is set (blob.azure.container). Set the name of the blob container." }}
{{- end }}
{{- if and (has $v.blob.azure.auth (list "workload-identity" "sas")) (not $v.blob.azure.accountUrl) }}
{{- $errs = append $errs (printf "No account URL is set (blob.azure.accountUrl) for blob.azure.auth %s. Set it to https://<account>.blob.core.windows.net." $v.blob.azure.auth) }}
{{- end }}
{{- if and (has $v.blob.azure.auth (list "connection-string" "sas")) (not $v.blob.existingSecret) }}
{{- $errs = append $errs (printf "No blob credential Secret is set (blob.existingSecret) for blob.azure.auth %s. Set it to an existing Secret with the key azure-connection-string or azure-sas-token." $v.blob.azure.auth) }}
{{- end }}
{{- end }}

{{- if eq $v.blob.provider "s3" }}
{{- if not $v.blob.s3.bucket }}
{{- $errs = append $errs "No S3 bucket is set (blob.s3.bucket). Set the bucket name." }}
{{- end }}
{{- if and (not $v.blob.s3.region) (not $v.blob.s3.endpoint) }}
{{- $errs = append $errs "No S3 region is set (blob.s3.region). Set the region, or blob.s3.endpoint for S3-compatible storage." }}
{{- end }}
{{- end }}

{{- if and (eq $v.blob.provider "filesystem") (not $v.blob.filesystem.existingClaim) }}
{{- $errs = append $errs "No volume claim is set (blob.filesystem.existingClaim). The root file system is read-only, so the filesystem provider needs an existing PersistentVolumeClaim." }}
{{- end }}

{{- if $errs }}
{{- fail (printf "opsie-email: %d problems:\n- %s" (len $errs) (join "\n- " $errs)) }}
{{- end }}
{{- end }}
