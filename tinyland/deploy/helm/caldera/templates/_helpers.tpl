{{/*
Expand the name of the chart.
*/}}
{{- define "caldera.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "caldera.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Chart version label.
*/}}
{{- define "caldera.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard labels merged onto every resource.
*/}}
{{- define "caldera.labels" -}}
helm.sh/chart: {{ include "caldera.chart" . }}
{{ include "caldera.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.extraLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels (deliberately stable across upgrades).
*/}}
{{- define "caldera.selectorLabels" -}}
app.kubernetes.io/name: {{ include "caldera.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Service account name.
*/}}
{{- define "caldera.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "caldera.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference. Pulls digest if set, otherwise tag.
*/}}
{{- define "caldera.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
Config secret name (rendered consistently across templates).
*/}}
{{- define "caldera.configSecretName" -}}
{{- default (printf "%s-config" (include "caldera.fullname" .)) .Values.config.secretName -}}
{{- end -}}
