{{/* ------------------------------------------------------------------ names */}}

{{- define "mantis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mantis.fullname" -}}
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

{{- define "mantis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mantis.labels" -}}
helm.sh/chart: {{ include "mantis.chart" . }}
{{ include "mantis.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mantis
{{- end }}

{{- define "mantis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mantis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Labels for the database, which must not match the application's selector. */}}
{{- define "mantis.db.labels" -}}
helm.sh/chart: {{ include "mantis.chart" . }}
{{ include "mantis.db.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mantis
{{- end }}

{{- define "mantis.db.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.database.type }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: database
{{- end }}

{{- define "mantis.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mantis.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* repository[:tag][@digest]; a digest wins over the tag. */}}
{{- define "mantis.imageRef" -}}
{{- if .digest }}
{{- printf "%s@%s" .repository .digest }}
{{- else }}
{{- printf "%s:%s" .repository (.tag | toString) }}
{{- end }}
{{- end }}

{{- define "mantis.image" -}}
{{- include "mantis.imageRef" (dict "repository" .Values.image.repository "tag" (.Values.image.tag | default .Chart.AppVersion) "digest" .Values.image.digest) }}
{{- end }}

{{/* ---------------------------------------------------------------- secrets */}}

{{/*
A secret value that survives upgrades. In order of preference: the value set
in values.yaml, the value already stored in the cluster, a new random one.

Relies on `lookup`, so it only preserves values under `helm install/upgrade`.
Anything that renders without cluster access (helm template, Argo CD) gets a
new random value each time -- use an existingSecret there.
*/}}
{{- define "mantis.secretValue" -}}
{{- $existing := lookup "v1" "Secret" .ctx.Release.Namespace .secret }}
{{- if .value }}
{{- .value }}
{{- else if and $existing $existing.data (hasKey $existing.data .key) }}
{{- index $existing.data .key | b64dec }}
{{- else }}
{{- randAlphaNum (default 32 .length | int) }}
{{- end }}
{{- end }}

{{- define "mantis.db.secretName" -}}
{{- .Values.database.auth.existingSecret | default (printf "%s-db" (include "mantis.fullname" .)) }}
{{- end }}

{{- define "mantis.app.secretName" -}}
{{- .Values.mantis.existingSecret | default (printf "%s-app" (include "mantis.fullname" .)) }}
{{- end }}

{{/* --------------------------------------------------------------- database */}}

{{/* Name of the database server resource (StatefulSet, MariaDB or Cluster). */}}
{{- define "mantis.db.serverName" -}}
{{- printf "%s-%s" (include "mantis.fullname" .) .Values.database.type | trunc 50 | trimSuffix "-" }}
{{- end }}

{{/* MantisBT's name for the ADOdb driver. */}}
{{- define "mantis.db.driver" -}}
{{- if eq .Values.database.type "postgresql" }}pgsql{{ else }}mysqli{{ end }}
{{- end }}

{{- define "mantis.db.port" -}}
{{- if and (eq .Values.database.mode "external") .Values.database.external.port }}
{{- .Values.database.external.port }}
{{- else if eq .Values.database.type "postgresql" }}5432
{{- else }}3306
{{- end }}
{{- end }}

{{/*
Service the application connects to. For operator clusters this is always the
primary: Galera accepts writes on every node, but spreading them invites
certification conflicts, and CloudNativePG replicas are read-only.
*/}}
{{- define "mantis.db.host" -}}
{{- $server := include "mantis.db.serverName" . }}
{{- if eq .Values.database.mode "external" }}
{{- .Values.database.external.host }}
{{- else if eq .Values.database.mode "standalone" }}
{{- $server }}
{{- else if eq .Values.database.type "mariadb" }}
{{- printf "%s-primary" $server }}
{{- else }}
{{- printf "%s-rw" $server }}
{{- end }}
{{- end }}

{{/* ----------------------------------------------------------------- mantis */}}

{{/*
mantis.contextPath normalised the way the image does it: "" for the root,
"/name" otherwise, never a trailing slash.
*/}}
{{- define "mantis.contextPath" -}}
{{- $p := .Values.mantis.contextPath | default "/" | trimPrefix "/" | trimSuffix "/" }}
{{- if $p }}/{{ $p }}{{ end }}
{{- end }}

{{/* Public hostname, if the Route or Ingress names one. */}}
{{- define "mantis.host" -}}
{{- if and .Values.route.enabled .Values.route.host }}
{{- .Values.route.host }}
{{- else if and .Values.ingress.enabled .Values.ingress.host }}
{{- .Values.ingress.host }}
{{- end }}
{{- end }}

{{/* Public URL, if one can be determined. */}}
{{- define "mantis.url" -}}
{{- $ctx := include "mantis.contextPath" . }}
{{- if .Values.mantis.url }}
{{- .Values.mantis.url }}
{{- else if and .Values.route.enabled .Values.route.host }}
{{- printf "%s://%s%s/" (ternary "https" "http" (not (empty .Values.route.tls))) .Values.route.host $ctx }}
{{- else if and .Values.ingress.enabled .Values.ingress.host }}
{{- printf "%s://%s%s/" (ternary "https" "http" (not (empty .Values.ingress.tls))) .Values.ingress.host $ctx }}
{{- end }}
{{- end }}

{{/* The TLS Secret the Route serves through externalCertificate, if any. */}}
{{- define "mantis.route.tlsSecret" -}}
{{- if .Values.route.tlsSecret }}
{{- .Values.route.tlsSecret }}
{{- else if .Values.certManager.enabled }}
{{- include "mantis.certManager.secretName" . }}
{{- end }}
{{- end }}

{{- define "mantis.certManager.secretName" -}}
{{- .Values.certManager.secretName | default (printf "%s-tls" (include "mantis.fullname" .)) }}
{{- end }}

{{- define "mantis.oidc.secretName" -}}
{{- .Values.mantis.oidc.existingSecret | default (include "mantis.app.secretName" .) }}
{{- end }}

{{- define "mantis.oidc.secretKey" -}}
{{- if .Values.mantis.oidc.existingSecret }}{{ .Values.mantis.oidc.existingSecretKey }}{{ else }}oidc-client-secret{{ end }}
{{- end }}

{{/*
Env entries for the (name value) pairs whose value is set, so an unset value
keeps the image's own default. Called with a list of pairs.
*/}}
{{- define "mantis.env" -}}
{{- $env := list }}
{{- range . }}
{{- $v := index . 1 }}
{{- if and (not (kindIs "invalid" $v)) (ne (toString $v) "") }}
{{- $env = append $env (dict "name" (index . 0) "value" (toString $v)) }}
{{- end }}
{{- end }}
{{- with $env }}{{ toYaml . }}{{ end }}
{{- end }}

{{/* MANTIS_PLUGINS: "<url>#sha256=<checksum>", space separated. */}}
{{- define "mantis.pluginList" -}}
{{- $entries := list }}
{{- range .Values.mantis.plugins.archives }}
{{- $entries = append $entries (printf "%s#sha256=%s" .url (lower .sha256)) }}
{{- end }}
{{- join " " $entries }}
{{- end }}

{{/* A php.ini or FPM setting name as the image's passthrough variables spell it: "." is "__". */}}
{{- define "mantis.envKey" -}}
{{- . | replace "." "__" }}
{{- end }}

{{/* A PHP single-quoted string literal. */}}
{{- define "mantis.php.string" -}}
'{{ . | toString | replace "\\" "\\\\" | replace "'" "\\'" }}'
{{- end }}

{{/*
The volumes and mounts the application container and the schema Job share: the
generated config, and the credentials config_inc.php reads at runtime.
*/}}
{{- define "mantis.configVolumes" -}}
- name: config
  secret:
    secretName: {{ include "mantis.fullname" . }}-config
- name: db-credentials
  secret:
    secretName: {{ include "mantis.db.secretName" . }}
    items:
      - key: {{ .Values.database.auth.secretKeys.username }}
        path: username
      - key: {{ .Values.database.auth.secretKeys.password }}
        path: password
- name: app-credentials
  secret:
    secretName: {{ include "mantis.app.secretName" . }}
{{- end }}

{{- define "mantis.configVolumeMounts" -}}
- name: config
  mountPath: /mantis/config
  readOnly: true
- name: db-credentials
  mountPath: /mantis/secrets/db
  readOnly: true
- name: app-credentials
  mountPath: /mantis/secrets/app
  readOnly: true
{{- end }}
