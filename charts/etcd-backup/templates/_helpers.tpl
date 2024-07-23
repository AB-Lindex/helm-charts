{{- define "etcd-backup.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "etcd-backup.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

