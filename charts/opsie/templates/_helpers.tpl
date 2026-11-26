{{/*
Chart name used in labels.
*/}}
{{- define "opsie.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Base name of every resource: fullnameOverride (default opsie), else <release>-<chart>.
All names, including service accounts, derive from here so federated credential subjects are predictable.
*/}}
{{- define "opsie.fullname" -}}
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
Base name plus a suffix, truncated so the suffix always survives. Input: dict "root" . "suffix" "config".
*/}}
{{- define "opsie.nameWith" -}}
{{- $suffix := printf "-%s" .suffix }}
{{- printf "%s%s" (include "opsie.fullname" .root | trunc (int (sub 63 (len $suffix))) | trimSuffix "-") $suffix }}
{{- end }}

{{/*
Name of a part's Deployment and Service: <base> for all, <base>-<part> otherwise. Input: dict "root" . "part" "ingest".
*/}}
{{- define "opsie.partFullname" -}}
{{- if eq .part "all" }}
{{- include "opsie.fullname" .root }}
{{- else }}
{{- include "opsie.nameWith" (dict "root" .root "suffix" .part) }}
{{- end }}
{{- end }}

{{- define "opsie.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels common to every resource.
*/}}
{{- define "opsie.labels" -}}
helm.sh/chart: {{ include "opsie.chart" . }}
app.kubernetes.io/name: {{ include "opsie.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels of one part; the component label is part of the selector from the first release (selectors are immutable).
Input: dict "root" . "part" "ingest".
*/}}
{{- define "opsie.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opsie.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .part }}
{{- end }}

{{/*
Common labels plus the component label. Input: dict "root" . "part" "ingest".
*/}}
{{- define "opsie.partLabels" -}}
{{ include "opsie.labels" .root }}
app.kubernetes.io/component: {{ .part }}
{{- end }}

{{/*
Names of the parts of the chosen topology as a JSON list; empty for an unknown topology (reported by opsie.validate).
*/}}
{{- define "opsie.parts" -}}
{{- if eq .Values.topology "all-in-one" }}
{{- list "all" | toJson }}
{{- else if eq .Values.topology "split-ingest" }}
{{- list "ingest" "app" | toJson }}
{{- else if eq .Values.topology "split-all" }}
{{- list "ingest" "processor" "app" | toJson }}
{{- else }}
{{- list | toJson }}
{{- end }}
{{- end }}

{{/*
Effective replica count of a part: its own replicaCount, else the topology default. Input: dict "root" . "part" "app".
*/}}
{{- define "opsie.replicas" -}}
{{- $v := (index .root.Values.parts .part).replicaCount }}
{{- if or (kindIs "invalid" $v) (and (kindIs "string" $v) (eq $v "")) }}
{{- if eq .root.Values.topology "split-all" }}2{{ else }}1{{ end }}
{{- else }}
{{- int $v }}
{{- end }}
{{- end }}

{{/*
True (non-empty output) for parts that run the api module and so receive JWT, OIDC, themes and the admin email file.
*/}}
{{- define "opsie.partRunsApi" -}}
{{- if or (eq . "all") (eq . "app") }}true{{ end }}
{{- end }}

{{/*
True (non-empty output) for parts that serve user or sender traffic and so receive TLS settings and an https port.
*/}}
{{- define "opsie.partServesTraffic" -}}
{{- if ne . "processor" }}true{{ end }}
{{- end }}

{{/*
The part that runs the internal-api module (mail route sync): all in all-in-one, else app.
*/}}
{{- define "opsie.internalPart" -}}
{{- ternary "all" "app" (eq .Values.topology "all-in-one") }}
{{- end }}

{{/*
The part that serves POST /api/events (the intake of opsie-email): all in all-in-one, else ingest.
*/}}
{{- define "opsie.intakePart" -}}
{{- ternary "all" "ingest" (eq .Values.topology "all-in-one") }}
{{- end }}

{{/*
Name of the opsie-email Deployment and its attachment API Service: <base>-email.
*/}}
{{- define "opsie.emailName" -}}
{{- include "opsie.nameWith" (dict "root" . "suffix" "email") }}
{{- end }}

{{- define "opsie.emailImage" -}}
{{- printf "%s:%s" .Values.email.image.repository (toString .Values.email.image.tag) }}
{{- end }}

{{/*
Selector labels of the opsie-email pods; email is a component of the release next to the parts.
*/}}
{{- define "opsie.emailSelectorLabels" -}}
{{- include "opsie.selectorLabels" (dict "root" . "part" "email") }}
{{- end }}

{{/*
Labels of the opsie-email Services. No app.kubernetes.io/name label: the ServiceMonitor selects on it and would look for
the internal port on these Services.
*/}}
{{- define "opsie.emailServiceLabels" -}}
helm.sh/chart: {{ include "opsie.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Base URL of the attachment API of opsie-email, as Opsie calls it.
*/}}
{{- define "opsie.emailAttachmentsUrl" -}}
{{- printf "http://%s:%d" (include "opsie.emailName" .) (.Values.email.service.attachments.port | int) }}
{{- end }}

{{/*
True (non-empty output) when the opsie-email pods authenticate to Azure Blob Storage with workload identity.
*/}}
{{- define "opsie.emailWorkloadIdentity" -}}
{{- if and (eq .Values.email.blob.provider "azure") (eq .Values.email.blob.azure.auth "workload-identity") }}true{{ end }}
{{- end }}

{{- define "opsie.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "opsie.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Service account of the migration hook or init container; empty means the namespace default.
*/}}
{{- define "opsie.migrateServiceAccountName" -}}
{{- if .Values.database.migrate.serviceAccount.create }}
{{- default (include "opsie.nameWith" (dict "root" . "suffix" "migrate")) .Values.database.migrate.serviceAccount.name }}
{{- else }}
{{- .Values.database.migrate.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "opsie.image" -}}
{{- printf "%s:%s" .Values.image.repository (toString (default .Chart.AppVersion .Values.image.tag)) }}
{{- end }}

{{/*
Values of the Valkey sub-chart in use: valkeySentinel when it is enabled, else valkey.
*/}}
{{- define "opsie.valkeyValues" -}}
{{- $s := .Values.valkeySentinel | default dict }}
{{- if $s.enabled }}
{{- $s | toJson }}
{{- else }}
{{- .Values.valkey | default dict | toJson }}
{{- end }}
{{- end }}

{{/*
Name of the Valkey sub-chart Service; mirrors the sub-chart's own fullname rules.
*/}}
{{- define "opsie.valkeyFullname" -}}
{{- $v := include "opsie.valkeyValues" . | fromJson }}
{{- if $v.fullnameOverride }}
{{- $v.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "valkey" $v.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
REDIS_MODE: sentinel for valkeySentinel, redis.mode for an external service, else standalone.
*/}}
{{- define "opsie.redisMode" -}}
{{- if (.Values.valkeySentinel | default dict).enabled }}sentinel
{{- else if .Values.redis.enabled }}{{ .Values.redis.mode | default "standalone" }}
{{- else }}standalone
{{- end }}
{{- end }}

{{/*
REDIS_ADDR: the external address, the Sentinel Service on 26379, or the sub-chart Service on 6379. The one place it is built.
*/}}
{{- define "opsie.redisAddr" -}}
{{- if .Values.redis.enabled }}
{{- .Values.redis.addr }}
{{- else if (.Values.valkeySentinel | default dict).enabled }}
{{- printf "%s-sentinel:26379" (include "opsie.valkeyFullname" .) }}
{{- else }}
{{- printf "%s:6379" (include "opsie.valkeyFullname" .) }}
{{- end }}
{{- end }}

{{/*
Secret name and key of the Redis password as JSON. Valkey: the key named after the default ACL user unless aclUsers.default.passwordKey is set.
*/}}
{{- define "opsie.redisPasswordSecretRef" -}}
{{- if .Values.redis.enabled }}
{{- dict "name" .Values.redis.existingSecret "key" .Values.redis.existingSecretKey | toJson }}
{{- else }}
{{- $v := include "opsie.valkeyValues" . | fromJson }}
{{- $auth := $v.auth | default dict }}
{{- $users := $auth.aclUsers | default dict }}
{{- $default := $users.default | default dict }}
{{- dict "name" ($auth.usersExistingSecret | default "") "key" ($default.passwordKey | default "default") | toJson }}
{{- end }}
{{- end }}

{{/*
Secret name and key of the Sentinel password as JSON; empty unless the mode is sentinel.
*/}}
{{- define "opsie.redisSentinelPasswordSecretRef" -}}
{{- if .Values.redis.enabled }}
{{- if eq (include "opsie.redisMode" .) "sentinel" }}
{{- dict "name" .Values.redis.existingSecret "key" .Values.redis.existingSecretSentinelKey | toJson }}
{{- end }}
{{- else if (.Values.valkeySentinel | default dict).enabled }}
{{- $sentinel := .Values.valkeySentinel.sentinel | default dict }}
{{- dict "name" ($sentinel.existingSecret | default "") "key" ($sentinel.passwordKey | default "sentinel") | toJson }}
{{- end }}
{{- end }}

{{/*
First host given by an Ingress entry, else the first HTTPRoute hostname; empty when there is none.
*/}}
{{- define "opsie.firstHost" -}}
{{- $host := "" }}
{{- range .Values.ingresses }}
{{- range .hosts }}
{{- if and (not $host) .host }}{{ $host = .host }}{{ end }}
{{- end }}
{{- end }}
{{- if not $host }}
{{- range .Values.httpRoutes }}
{{- range (.hostnames | default list) }}
{{- if not $host }}{{ $host = . }}{{ end }}
{{- end }}
{{- end }}
{{- end }}
{{- $host }}
{{- end }}

{{/*
OIDC redirect URL: the explicit value, else https://<first host>/api/auth/callback, else empty.
*/}}
{{- define "opsie.oidcRedirectUrl" -}}
{{- if .Values.auth.oidc.redirectUrl }}
{{- .Values.auth.oidc.redirectUrl }}
{{- else }}
{{- $host := include "opsie.firstHost" . }}
{{- if $host }}{{ printf "https://%s/api/auth/callback" $host }}{{ end }}
{{- end }}
{{- end }}

{{/*
Public base URL of share links: the explicit value, else https://<first host>, else empty.
*/}}
{{- define "opsie.shareBaseUrl" -}}
{{- if .Values.shareLinks.publicBaseUrl }}
{{- .Values.shareLinks.publicBaseUrl | trimSuffix "/" }}
{{- else }}
{{- $host := include "opsie.firstHost" . }}
{{- if $host }}{{ printf "https://%s" $host }}{{ end }}
{{- end }}
{{- end }}

{{/*
Topology spread constraints of a part as YAML; nothing when disabled. A constraint without labelSelector gets the part's own selector.
Input: dict "root" . "part" "app"; the email component passes its own constraints as "own" (it is not a key of parts).
*/}}
{{- define "opsie.topologySpread" -}}
{{- $root := .root }}
{{- $part := .part }}
{{- if $root.Values.topologySpread.enabled }}
{{- $own := list }}
{{- if hasKey . "own" }}
{{- $own = .own }}
{{- else }}
{{- $own = (index $root.Values.parts $part).topologySpreadConstraints }}
{{- end }}
{{- $list := ternary $own $root.Values.topologySpread.constraints (not (empty $own)) }}
{{- $out := list }}
{{- range $list }}
{{- $c := deepCopy . }}
{{- if not $c.labelSelector }}
{{- $_ := set $c "labelSelector" (dict "matchLabels" (include "opsie.selectorLabels" (dict "root" $root "part" $part) | fromYaml)) }}
{{- end }}
{{- $out = append $out $c }}
{{- end }}
{{- if $out }}
{{- toYaml $out }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Non-secret environment shared by every part; the ConfigMap data, and the input of the pod checksum annotation.
*/}}
{{- define "opsie.configData" -}}
DB_TYPE: {{ .Values.database.type | quote }}
USE_REDIS: "true"
REDIS_ADDR: {{ include "opsie.redisAddr" . | quote }}
REDIS_MODE: {{ include "opsie.redisMode" . | quote }}
{{- if or (not .Values.alertEvents.enabled) (not .Values.sse.enabled) }}
ALERT_EVENTS_DISABLED: "true"
{{- end }}
INTERNAL_PORT: {{ .Values.internal.port | int | toString | quote }}
{{- with .Values.alerts.reopenWindow }}
ALERT_REOPEN_WINDOW: {{ . | quote }}
{{- end }}
{{- with .Values.alerts.zombieThreshold }}
ALERT_ZOMBIE_THRESHOLD: {{ . | quote }}
{{- end }}
{{- if .Values.shareLinks.enabled }}
SHARE_LINKS_ENABLED: "true"
{{- with include "opsie.shareBaseUrl" . }}
PUBLIC_BASE_URL: {{ . | quote }}
{{- end }}
{{- with .Values.shareLinks.lifetime }}
SHARE_LINK_LIFETIME: {{ . | quote }}
{{- end }}
{{- end }}
{{- with .Values.rego.evalTimeout }}
REGO_EVAL_TIMEOUT: {{ . | quote }}
{{- end }}
{{- with .Values.rego.cacheBytes }}
REGO_CACHE_BYTES: {{ . | int64 | toString | quote }}
{{- end }}
{{- if .Values.rego.helpers.existingConfigMap }}
REGO_HELPERS_DIR: {{ .Values.rego.helpers.mountPath | quote }}
{{- end }}
{{- end }}

{{/*
Environment of a part as YAML list items; the ConfigMap carries the non-secret variables.
Secrets reach only the parts that use them: partRunsApi gets JWT, OIDC, themes and the admin email file,
partServesTraffic gets TLS. Never renders DEVMODE, ENABLE_MOCK_DATA or JWT_ISSUER.
Input: dict "root" . "part" "app".
*/}}
{{- define "opsie.partEnv" -}}
{{- $root := .root }}
{{- $part := .part }}
{{- $v := $root.Values -}}
- name: DB_CONNECTION_STRING
  valueFrom:
    secretKeyRef:
      name: {{ $v.database.existingSecret }}
      key: {{ $v.database.existingSecretKey }}
{{- $pw := include "opsie.redisPasswordSecretRef" $root | fromJson }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $pw.name }}
      key: {{ $pw.key }}
{{- $spw := include "opsie.redisSentinelPasswordSecretRef" $root }}
{{- if $spw }}
{{- $spw = $spw | fromJson }}
- name: REDIS_SENTINEL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $spw.name }}
      key: {{ $spw.key }}
{{- end }}
{{- if eq $part "ingest" }}
- name: MODULES
  value: ingestion
{{- else if eq $part "processor" }}
- name: MODULES
  value: alert-processing
{{- else if eq $part "app" }}
- name: NOT_MODULES
  value: {{ ternary "ingestion,alert-processing" "ingestion" (eq $v.topology "split-all") }}
{{- end }}
{{- if include "opsie.partRunsApi" $part }}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $v.auth.jwt.existingSecret }}
      key: jwt-secret
- name: JWT_SECRET_NEXT
  valueFrom:
    secretKeyRef:
      name: {{ $v.auth.jwt.existingSecret }}
      key: jwt-secret-next
      optional: true
- name: JWT_SECRET_PREVIOUS
  valueFrom:
    secretKeyRef:
      name: {{ $v.auth.jwt.existingSecret }}
      key: jwt-secret-previous
      optional: true
{{- if $v.auth.oidc.issuer }}
- name: OIDC_ISSUER
  value: {{ $v.auth.oidc.issuer | quote }}
- name: OIDC_SCOPES
  value: {{ $v.auth.oidc.scopes | quote }}
- name: OIDC_REDIRECT_URL
  value: {{ include "opsie.oidcRedirectUrl" $root | quote }}
- name: OIDC_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ $v.auth.oidc.existingSecret }}
      key: client-id
- name: OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $v.auth.oidc.existingSecret }}
      key: client-secret
{{- end }}
{{- if $v.auth.sessionCacheTtl }}
- name: SESSION_CACHE_TTL
  value: {{ $v.auth.sessionCacheTtl | quote }}
{{- end }}
{{- if $v.auth.sessionCacheStaleGrace }}
- name: SESSION_CACHE_STALE_GRACE
  value: {{ $v.auth.sessionCacheStaleGrace | quote }}
{{- end }}
{{- if not $v.sse.enabled }}
- name: SSE_DISABLED
  value: "true"
{{- end }}
{{- with $v.sse.maxConnectionsPerUser }}
- name: SSE_MAX_CONNECTIONS_PER_USER
  value: {{ . | toString | quote }}
{{- end }}
{{- with $v.sse.maxConnections }}
- name: SSE_MAX_CONNECTIONS
  value: {{ . | toString | quote }}
{{- end }}
{{- if $v.themes.existingConfigMap }}
- name: THEMES_PATH
  value: /app/themes/custom
{{- end }}
{{- with $v.branding.environmentName }}
- name: ENVIRONMENT_NAME
  value: {{ . | quote }}
{{- end }}
{{- with $v.branding.environmentColor }}
- name: ENVIRONMENT_COLOR
  value: {{ . | quote }}
{{- end }}
{{- with $v.branding.companyLogoUrl }}
- name: COMPANY_LOGO_URL
  value: {{ . | quote }}
{{- end }}
{{- if $v.auth.adminEmail.existingConfigMap }}
- name: ADMIN_EMAIL_FILE
  value: {{ printf "/app/config/admin/%s" $v.auth.adminEmail.key | quote }}
{{- end }}
{{- if $v.email.enabled }}
- name: EMAIL_DOMAIN
  value: {{ $v.email.domain | quote }}
- name: EMAIL_ROUTES_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $v.email.existingSecret }}
      key: routes-token
- name: EMAIL_ROUTES_TOKEN_NEXT
  valueFrom:
    secretKeyRef:
      name: {{ $v.email.existingSecret }}
      key: routes-token-next
      optional: true
- name: EMAIL_ATTACHMENT_API_URL
  value: {{ include "opsie.emailAttachmentsUrl" $root | quote }}
- name: EMAIL_ATTACHMENT_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $v.email.existingSecret }}
      key: attachments-secret
{{- end }}
{{- end }}
{{- if include "opsie.partServesTraffic" $part }}
{{- if eq $v.tls.mode "proxy" }}
- name: TRUST_FORWARDED_HEADERS
  value: "true"
{{- else if eq $v.tls.mode "native" }}
- name: TLS_CERT_FILE
  value: {{ printf "%s/tls.crt" $v.tls.mountPath | quote }}
- name: TLS_KEY_FILE
  value: {{ printf "%s/tls.key" $v.tls.mountPath | quote }}
- name: TLS_PORT
  value: "8443"
{{- if $v.tls.httpsRedirect }}
- name: HTTPS_REDIRECT
  value: "true"
{{- end }}
{{- if and $v.tls.hstsMaxAge (ne (toString $v.tls.hstsMaxAge) "0") }}
- name: HSTS_MAX_AGE
  value: {{ $v.tls.hstsMaxAge | toString | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Volumes of a part as YAML list items; empty when the part mounts nothing. Input: dict "root" . "part" "app".
*/}}
{{- define "opsie.partVolumes" -}}
{{- $v := .root.Values }}
{{- if $v.rego.helpers.existingConfigMap }}
- name: rego-helpers
  configMap:
    name: {{ $v.rego.helpers.existingConfigMap }}
{{- end }}
{{- if include "opsie.partRunsApi" .part }}
{{- if $v.themes.existingConfigMap }}
- name: themes
  configMap:
    name: {{ $v.themes.existingConfigMap }}
{{- end }}
{{- if $v.auth.adminEmail.existingConfigMap }}
- name: admin-email
  configMap:
    name: {{ $v.auth.adminEmail.existingConfigMap }}
{{- end }}
{{- end }}
{{- if and (include "opsie.partServesTraffic" .part) (eq $v.tls.mode "native") }}
- name: tls
  secret:
    secretName: {{ $v.tls.existingSecret }}
{{- end }}
{{- end }}

{{/*
Volume mounts matching opsie.partVolumes. Input: dict "root" . "part" "app".
*/}}
{{- define "opsie.partVolumeMounts" -}}
{{- $v := .root.Values }}
{{- if $v.rego.helpers.existingConfigMap }}
- name: rego-helpers
  mountPath: {{ $v.rego.helpers.mountPath }}
  readOnly: true
{{- end }}
{{- if include "opsie.partRunsApi" .part }}
{{- if $v.themes.existingConfigMap }}
- name: themes
  mountPath: /app/themes/custom
  readOnly: true
{{- end }}
{{- if $v.auth.adminEmail.existingConfigMap }}
- name: admin-email
  mountPath: /app/config/admin
  readOnly: true
{{- end }}
{{- end }}
{{- if and (include "opsie.partServesTraffic" .part) (eq $v.tls.mode "native") }}
- name: tls
  mountPath: {{ $v.tls.mountPath }}
  readOnly: true
{{- end }}
{{- end }}

{{/*
Migration container (hook Job and init container share it): same image, command and database Secret.
Input: root context.
*/}}
{{- define "opsie.migrateContainer" -}}
name: migrate
image: {{ include "opsie.image" . | quote }}
imagePullPolicy: {{ .Values.image.pullPolicy }}
command:
  - /app/mssql-migrate
{{- if .Values.database.migrate.dryRun }}
args:
  - --dry-run
{{- end }}
env:
  - name: DB_CONNECTION_STRING
    valueFrom:
      secretKeyRef:
        name: {{ .Values.database.existingSecret }}
        key: {{ .Values.database.existingSecretKey }}
  {{- with .Values.database.migrate.extraEnv }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- with .Values.database.migrate.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.securityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
True (non-empty output) when a migration is rendered in the given mode.
*/}}
{{- define "opsie.migrateMode" -}}
{{- if and (eq .root.Values.database.type "mssql") .root.Values.database.migrate.enabled (eq .root.Values.database.migrate.mode .mode) }}true{{ end }}
{{- end }}
