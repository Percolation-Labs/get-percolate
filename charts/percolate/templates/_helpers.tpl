{{- define "percolate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "percolate.fullname" -}}
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

{{- define "percolate.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "percolate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "percolate.secretName" -}}
{{- .Values.secrets.existingSecret | default (printf "%s-secrets" (include "percolate.fullname" .)) -}}
{{- end -}}

{{- define "percolate.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}

{{/*
The database host. One definition, because a chart that computes this in five
templates is a chart where `postgres.enabled: false` works in four of them.
*/}}
{{- define "percolate.dbHost" -}}
{{- if .Values.postgres.enabled -}}
{{- printf "%s-postgres" (include "percolate.fullname" .) -}}
{{- else -}}
{{- required "externalDatabase.host is required when postgres.enabled is false" .Values.externalDatabase.host -}}
{{- end -}}
{{- end -}}

{{- define "percolate.dbPort" -}}
{{- if .Values.postgres.enabled }}5432{{ else }}{{ .Values.externalDatabase.port }}{{ end -}}
{{- end -}}

{{- define "percolate.dbName" -}}
{{- if .Values.postgres.enabled }}{{ .Values.postgres.database }}{{ else }}{{ .Values.externalDatabase.database }}{{ end -}}
{{- end -}}

{{/*
The object-storage endpoint: the bundled MinIO, or whatever you pointed at.
*/}}
{{- define "percolate.s3Endpoint" -}}
{{- if .Values.objectStorage.external.endpoint -}}
{{- .Values.objectStorage.external.endpoint -}}
{{- else -}}
{{- printf "http://%s-minio:9000" (include "percolate.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Environment shared by every percolate-core service EXCEPT the DSN, which
differs by role -- the worker connects as `worker` and the HTTP services as
`authenticator`, and collapsing that into one variable is how a service ends up
running every query as itself and ignoring the caller identity it just
installed.
*/}}
{{- define "percolate.commonEnv" -}}
- name: P8_S3_ENDPOINT
  value: {{ include "percolate.s3Endpoint" . | quote }}
- name: P8_BUCKET
  value: {{ .Values.objectStorage.bucket | quote }}
- name: P8_S3_REGION
  value: {{ .Values.objectStorage.external.region | quote }}
- name: P8_S3_KEY
  valueFrom: {secretKeyRef: {name: {{ include "percolate.secretName" . }}, key: s3-key}}
- name: P8_S3_SECRET
  valueFrom: {secretKeyRef: {name: {{ include "percolate.secretName" . }}, key: s3-secret}}
- name: P8_JWT_SECRET
  valueFrom: {secretKeyRef: {name: {{ include "percolate.secretName" . }}, key: jwt-secret}}
{{- end -}}

{{- define "percolate.serviceDsn" -}}
postgres://authenticator:$(P8_AUTHENTICATOR_PASSWORD)@{{ include "percolate.dbHost" . }}:{{ include "percolate.dbPort" . }}/{{ include "percolate.dbName" . }}
{{- end -}}

{{- define "percolate.workerDsn" -}}
postgres://worker:$(P8_WORKER_PASSWORD)@{{ include "percolate.dbHost" . }}:{{ include "percolate.dbPort" . }}/{{ include "percolate.dbName" . }}
{{- end -}}
