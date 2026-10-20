{{- define "opsie-email.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Base name of every resource: fullnameOverride (default opsie-email), else <release>-<chart>.
*/}}
{{- define "opsie-email.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Base name plus a suffix, truncated so the suffix always survives. Input: dict "root" . "suffix" "smtp".
*/}}
{{- define "opsie-email.nameWith" -}}
{{- $suffix := printf "-%s" .suffix }}
{{- printf "%s%s" (include "opsie-email.fullname" .root | trunc (int (sub 63 (len $suffix))) | trimSuffix "-") $suffix }}
{{- end }}

{{- define "opsie-email.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "opsie-email.labels" -}}
helm.sh/chart: {{ include "opsie-email.chart" . }}
{{ include "opsie-email.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "opsie-email.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opsie-email.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "opsie-email.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "opsie-email.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "opsie-email.image" -}}
{{- printf "%s:%s" .Values.image.repository (toString (default .Chart.AppVersion .Values.image.tag)) }}
{{- end }}

{{/*
True (non-empty output) when the pod authenticates to Azure Blob Storage with workload identity.
*/}}
{{- define "opsie-email.workloadIdentity" -}}
{{- if and (eq .Values.blob.provider "azure") (eq .Values.blob.azure.auth "workload-identity") }}true{{ end }}
{{- end }}

{{/*
Peer of the Opsie pods for NetworkPolicy rules.
*/}}
{{- define "opsie-email.opsiePeer" -}}
{{- $np := .Values.networkPolicy.opsie }}
{{- $peer := dict "podSelector" $np.podSelector }}
{{- if $np.namespaceSelector }}
{{- $_ := set $peer "namespaceSelector" $np.namespaceSelector }}
{{- end }}
{{- toYaml $peer }}
{{- end }}
