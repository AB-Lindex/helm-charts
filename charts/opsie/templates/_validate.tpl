{{/*
Collects every configuration problem and reports them in one failure.
Message form: <what is wrong> (<value path>). <what to do>.
Included from templates/configmap.yaml, which always renders.
*/}}
{{- define "opsie.validate" -}}
{{- $v := .Values }}
{{- $errs := list }}
{{- $parts := include "opsie.parts" . | fromJsonArray }}
{{- $topologyOk := not (empty $parts) }}

{{- /* V01 */}}
{{- if not (has $v.database.type (list "mssql" "postgres")) }}
{{- $errs = append $errs (printf "database.type %q is not supported (database.type). Use one of: mssql, postgres. The memory provider is for development only and is not offered by this chart." (toString $v.database.type)) }}
{{- end }}

{{- /* V02 */}}
{{- if or (not $v.image.repository) (eq (toString $v.image.repository) "TBD") }}
{{- $errs = append $errs (printf "image.repository is not set (image.repository, currently %q). Set image.repository, and image.tag, to the Opsie image you want to run." (toString $v.image.repository)) }}
{{- end }}

{{- /* V03 */}}
{{- if not $v.database.existingSecret }}
{{- $errs = append $errs "No database Secret is named (database.existingSecret). Set it to an existing Secret holding the connection string under database.existingSecretKey." }}
{{- end }}

{{- /* V04 */}}
{{- if not $v.auth.jwt.existingSecret }}
{{- $errs = append $errs "No JWT Secret is named (auth.jwt.existingSecret). Set it to an existing Secret with the key jwt-secret (at least 32 characters)." }}
{{- end }}

{{- /* V05 */}}
{{- if not $topologyOk }}
{{- $errs = append $errs (printf "topology %q is not valid (topology). Use one of: all-in-one, split-ingest, split-all." (toString $v.topology)) }}
{{- end }}

{{- /* V06, V07 */}}
{{- if and (not $v.valkey.enabled) (not $v.redis.enabled) }}
{{- $errs = append $errs "No Valkey source is selected (valkey.enabled, redis.enabled). Set valkey.enabled=true for the bundled sub-chart, or redis.enabled=true with redis.addr for an external Valkey/Redis." }}
{{- end }}
{{- if and $v.valkey.enabled $v.redis.enabled }}
{{- $errs = append $errs "Two Valkey sources are selected (valkey.enabled, redis.enabled). Set exactly one of them to true." }}
{{- end }}

{{- /* V08 */}}
{{- if $v.redis.enabled }}
{{- if not $v.redis.addr }}
{{- $errs = append $errs "redis.enabled is true without an address (redis.addr). Set redis.addr to host:port of the Valkey/Redis service." }}
{{- end }}
{{- if not $v.redis.existingSecret }}
{{- $errs = append $errs "redis.enabled is true without a password Secret (redis.existingSecret). Set it to an existing Secret holding the password under redis.existingSecretKey." }}
{{- end }}
{{- end }}

{{- /* V09 */}}
{{- if $v.valkey.enabled }}
{{- if not $v.valkey.auth.usersExistingSecret }}
{{- $errs = append $errs "valkey.enabled is true without a password Secret (valkey.auth.usersExistingSecret). Set it to an existing Secret whose key default holds the password." }}
{{- end }}
{{- if not $v.valkey.auth.enabled }}
{{- $errs = append $errs "Valkey authentication is switched off (valkey.auth.enabled). Opsie does not run Valkey without a password; set it to true." }}
{{- end }}
{{- end }}

{{- /* V10 */}}
{{- if $topologyOk }}
{{- $partKeys := list "replicaCount" "resources" "nodeSelector" "tolerations" "affinity" "topologySpreadConstraints" "annotations" "podLabels" "podAnnotations" "extraEnv" }}
{{- range $name := list "all" "ingest" "processor" "app" }}
{{- if not (has $name $parts) }}
{{- $set := list }}
{{- range $key := $partKeys }}
{{- if not (empty (index (index $.Values.parts $name) $key)) }}{{ $set = append $set $key }}{{ end }}
{{- end }}
{{- if $set }}
{{- $errs = append $errs (printf "parts.%s sets %s but topology %q has no such part (parts.%s). Remove these values or choose a topology that has the part (parts: %s)." $name (join ", " $set) $.Values.topology $name (join ", " $parts)) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{- /* V11 */}}
{{- $pdb := $v.podDisruptionBudget }}
{{- if and (not (kindIs "invalid" $pdb.minAvailable)) (ne (toString $pdb.minAvailable) "") (not (kindIs "invalid" $pdb.maxUnavailable)) (ne (toString $pdb.maxUnavailable) "") }}
{{- $errs = append $errs (printf "Both minAvailable (%s) and maxUnavailable (%s) are set (podDisruptionBudget). Set only one; to use minAvailable also set maxUnavailable: null." (toString $pdb.minAvailable) (toString $pdb.maxUnavailable)) }}
{{- end }}

{{- /* V12, V13 */}}
{{- if and (eq $v.tls.mode "native") (not $v.tls.existingSecret) }}
{{- $errs = append $errs "tls.mode is native without a certificate Secret (tls.existingSecret). Set it to an existing kubernetes.io/tls Secret." }}
{{- end }}
{{- if and $v.tls.httpsRedirect (ne $v.tls.mode "native") }}
{{- $errs = append $errs (printf "tls.httpsRedirect is true but tls.mode is %q (tls.httpsRedirect). The redirect needs native TLS; set tls.mode=native or tls.httpsRedirect=false." (toString $v.tls.mode)) }}
{{- end }}

{{- /* V14, V15 */}}
{{- $names := list }}
{{- range $i, $e := $v.ingresses }}
{{- if not $e.name }}
{{- $errs = append $errs (printf "ingresses entry %d has no name (ingresses[%d].name). Give every entry a unique name." $i $i) }}
{{- else if has $e.name $names }}
{{- $errs = append $errs (printf "ingresses name %q is used twice (ingresses[%d].name). Names must be unique within the list." $e.name $i) }}
{{- end }}
{{- $names = append $names $e.name }}
{{- end }}
{{- $names = list }}
{{- range $i, $e := $v.httpRoutes }}
{{- if not $e.name }}
{{- $errs = append $errs (printf "httpRoutes entry %d has no name (httpRoutes[%d].name). Give every entry a unique name." $i $i) }}
{{- else if has $e.name $names }}
{{- $errs = append $errs (printf "httpRoutes name %q is used twice (httpRoutes[%d].name). Names must be unique within the list." $e.name $i) }}
{{- end }}
{{- $names = append $names $e.name }}
{{- if not $e.parentRefs }}
{{- $errs = append $errs (printf "httpRoutes entry %d has no parentRefs (httpRoutes[%d].parentRefs). Name the Gateway to attach to." $i $i) }}
{{- end }}
{{- end }}

{{- /* V16: only checked when the renderer has cluster information. A cluster (and Argo CD) lists group/version/Kind
       entries such as apps/v1/Deployment in .Capabilities.APIVersions; plain `helm template` lists group/versions only,
       so the check is skipped there. Add --api-versions apps/v1/Deployment to simulate a cluster. */}}
{{- if and $v.httpRoutes (.Capabilities.APIVersions.Has "apps/v1/Deployment") (not (.Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1")) }}
{{- $errs = append $errs "httpRoutes are set but the cluster has no gateway.networking.k8s.io/v1 API (httpRoutes). Install the Gateway API CRDs, or remove httpRoutes." }}
{{- end }}

{{- /* V17, V18 */}}
{{- if $v.auth.oidc.issuer }}
{{- if not $v.auth.oidc.existingSecret }}
{{- $errs = append $errs "auth.oidc.issuer is set without a client Secret (auth.oidc.existingSecret). Set it to an existing Secret with the keys client-id and client-secret." }}
{{- end }}
{{- if not (include "opsie.oidcRedirectUrl" .) }}
{{- $errs = append $errs "The OIDC redirect URL is not known (auth.oidc.redirectUrl). Set it, or give an ingresses entry a host or an httpRoutes entry a hostname to derive it from." }}
{{- end }}
{{- end }}

{{- /* V20 */}}
{{- if $topologyOk }}
{{- range $v.database.migrate.initContainerParts }}
{{- if not (has . $parts) }}
{{- $errs = append $errs (printf "database.migrate.initContainerParts names %q, which topology %q does not have (database.migrate.initContainerParts). Use parts from: %s." . $.Values.topology (join ", " $parts)) }}
{{- end }}
{{- end }}
{{- end }}

{{- /* V21 */}}
{{- if and $topologyOk $v.topologySpread.enabled (not $v.topologySpread.constraints) }}
{{- $bare := list }}
{{- range $name := $parts }}
{{- if empty (index $.Values.parts $name).topologySpreadConstraints }}{{ $bare = append $bare $name }}{{ end }}
{{- end }}
{{- if $bare }}
{{- $errs = append $errs (printf "topologySpread.enabled is true but no constraints exist for %s (topologySpread.constraints). Add constraints, give the part its own topologySpreadConstraints, or set topologySpread.enabled=false." (join ", " $bare)) }}
{{- end }}
{{- end }}

{{- /* V22: the range of internal.port is checked by the schema */}}
{{- if hasKey $v.metrics "port" }}
{{- $errs = append $errs "metrics.port was removed (metrics.port). Use internal.port; /metrics is served on the internal port of every part." }}
{{- end }}
{{- if eq (int $v.internal.port) 8080 }}
{{- $errs = append $errs "internal.port equals the HTTP port 8080 (internal.port). Use another port." }}
{{- end }}
{{- if and (eq $v.tls.mode "native") (eq (int $v.internal.port) 8443) }}
{{- $errs = append $errs "internal.port equals the HTTPS port 8443 (internal.port). Use another port." }}
{{- end }}

{{- /* V23 */}}
{{- if $v.email.enabled }}
{{- if not $v.email.domain }}
{{- $errs = append $errs "email.enabled is true without a domain (email.domain). Set it to the domain of the recipient addresses, for example mail.example.com." }}
{{- end }}
{{- if not $v.email.existingSecret }}
{{- $errs = append $errs "email.enabled is true without a Secret (email.existingSecret). Set it to the existing Secret shared with the opsie-email release, with the keys routes-token and attachments-secret." }}
{{- end }}
{{- if not $v.email.attachments.url }}
{{- $errs = append $errs "email.enabled is true without an attachment API URL (email.attachments.url). Set it to the base URL of the opsie-email attachment API, for example http://opsie-email:8082." }}
{{- end }}
{{- if and $v.email.networkPolicy.enabled $v.metrics.serviceMonitor.enabled (not $v.email.networkPolicy.metricsPeers) }}
{{- $errs = append $errs "The ServiceMonitor and the email network policy are both enabled without metrics peers (email.networkPolicy.metricsPeers). The policy would block the scrapes; list the Prometheus pods or namespace, or set email.networkPolicy.enabled=false." }}
{{- end }}
{{- end }}

{{- if $errs }}
{{- $lines := list }}
{{- range $i, $e := $errs }}
{{- $lines = append $lines (printf "  %d. %s" (add $i 1) $e) }}
{{- end }}
{{- fail (printf "opsie: %d configuration %s:\n%s" (len $errs) (ternary "problem" "problems" (eq (len $errs) 1)) (join "\n" $lines)) }}
{{- end }}
{{- end }}
