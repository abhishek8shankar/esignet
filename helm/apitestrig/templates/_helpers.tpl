{{/*
Return the proper image name
*/}}
{{- define "apitestrig.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "apitestrig.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "apitestrig.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (printf "%s" (include "common.names.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Resolve the -c value to pass to run-all.sh: the mounted custom config when
apitestrig.configOverride is set, otherwise the in-image path from
apitestrig.configFile.
*/}}
{{- define "apitestrig.configPath" -}}
{{- if .Values.apitestrig.configOverride -}}
/app/custom-config/config.json
{{- else -}}
{{ .Values.apitestrig.configFile }}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret backing the config.local.json overlay, whether
Helm-managed or user-supplied via existingSecret.
*/}}
{{- define "apitestrig.configLocalSecretName" -}}
{{- if .Values.apitestrig.configLocal.existingSecret -}}
{{ .Values.apitestrig.configLocal.existingSecret }}
{{- else -}}
{{ include "common.names.fullname" . }}-config-local
{{- end -}}
{{- end -}}

{{/*
Name of the Secret backing the conformance plan config files.
*/}}
{{- define "apitestrig.conformancePlanConfigSecretName" -}}
{{- if .Values.apitestrig.conformancePlanConfig.existingSecret -}}
{{ .Values.apitestrig.conformancePlanConfig.existingSecret }}
{{- else -}}
{{ include "common.names.fullname" . }}-conformance-plan
{{- end -}}
{{- end -}}

{{/*
Name of the Secret backing extraEnvVarsSecret.
*/}}
{{- define "apitestrig.envSecretName" -}}
{{ include "common.names.fullname" . }}-env
{{- end -}}

{{/*
Name of the Secret backing S3 report-push credentials.
*/}}
{{- define "apitestrig.s3SecretName" -}}
{{- if .Values.reports.s3.existingSecret -}}
{{ .Values.reports.s3.existingSecret }}
{{- else -}}
{{ include "common.names.fullname" . }}-s3
{{- end -}}
{{- end -}}

{{/*
Name of the PVC backing the reports volume.
*/}}
{{- define "apitestrig.reportsClaimName" -}}
{{- if .Values.reports.persistence.existingClaim -}}
{{ .Values.reports.persistence.existingClaim }}
{{- else -}}
{{ include "common.names.fullname" . }}-reports
{{- end -}}
{{- end -}}

{{/*
The shared pod spec used by both cronjob.yaml and job.yaml, so the two
trigger kinds can never drift out of sync with each other.
*/}}
{{- define "apitestrig.podTemplate" -}}
metadata:
  annotations:
    sidecar.istio.io/inject: {{ .Values.istio.sidecarInject | quote }}
    {{- if .Values.podAnnotations }}
    {{- include "common.tplvalues.render" (dict "value" .Values.podAnnotations "context" $) | nindent 4 }}
    {{- end }}
  labels: {{- include "common.labels.standard" . | nindent 4 }}
    {{- if .Values.commonLabels }}
    {{- include "common.tplvalues.render" (dict "value" .Values.commonLabels "context" $) | nindent 4 }}
    {{- end }}
    {{- if .Values.podLabels }}
    {{- include "common.tplvalues.render" (dict "value" .Values.podLabels "context" $) | nindent 4 }}
    {{- end }}
spec:
  restartPolicy: Never
  serviceAccountName: {{ include "apitestrig.serviceAccountName" . }}
  {{- include "apitestrig.imagePullSecrets" . | nindent 2 }}
  {{- if .Values.podSecurityContext.enabled }}
  securityContext: {{- omit .Values.podSecurityContext "enabled" | toYaml | nindent 4 }}
  {{- end }}
  {{- if .Values.hostAliases }}
  hostAliases: {{- include "common.tplvalues.render" (dict "value" .Values.hostAliases "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.affinity }}
  affinity: {{- include "common.tplvalues.render" (dict "value" .Values.affinity "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.nodeSelector }}
  nodeSelector: {{- include "common.tplvalues.render" (dict "value" .Values.nodeSelector "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.tolerations }}
  tolerations: {{- include "common.tplvalues.render" (dict "value" .Values.tolerations "context" $) | nindent 4 }}
  {{- end }}
  containers:
    - name: apitestrig
      image: {{ include "apitestrig.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- if .Values.containerSecurityContext.enabled }}
      securityContext: {{- omit .Values.containerSecurityContext "enabled" | toYaml | nindent 8 }}
      {{- end }}
      {{- if .Values.reports.s3.enabled }}
      {{/*
      S3 push needs to know when the harness is done (run-all.sh has no S3
      awareness of its own), so wrap it in a shell that drops a completion
      marker on the shared reports volume for the uploader container to
      watch for, then exits with the harness's own exit code.
      */}}
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -o pipefail
          ./run-all.sh -c {{ include "apitestrig.configPath" . | trim | quote }}{{ if .Values.apitestrig.surfaces }} -s {{ .Values.apitestrig.surfaces | quote }}{{ end }}{{ range .Values.args }} {{ . | quote }}{{ end }}
          rc=$?
          touch {{ printf "%s/.rig-complete" .Values.reports.mountPath | quote }}
          exit $rc
      {{- else }}
      {{- if .Values.command }}
      command: {{- include "common.tplvalues.render" (dict "value" .Values.command "context" $) | nindent 8 }}
      {{- end }}
      args:
        - "-c"
        - {{ include "apitestrig.configPath" . | trim | quote }}
        {{- if .Values.apitestrig.surfaces }}
        - "-s"
        - {{ .Values.apitestrig.surfaces | quote }}
        {{- end }}
        {{- if .Values.args }}
        {{- include "common.tplvalues.render" (dict "value" .Values.args "context" $) | nindent 8 }}
        {{- end }}
      {{- end }}
      env:
        - name: REPORT_DIR
          value: {{ .Values.reports.mountPath | quote }}
        {{- if .Values.apitestrig.configLocal.enabled }}
        - name: CONFIG_LOCAL
          value: "/app/secrets/config.local.json"
        {{- end }}
        {{- range $key, $value := .Values.apitestrig.extraEnvVars }}
        {{- if $value }}
        - name: {{ $key }}
          value: {{ $value | quote }}
        {{- end }}
        {{- end }}
        {{- range $key, $value := .Values.apitestrig.extraEnvVarsSecret }}
        {{- if $value }}
        - name: {{ $key }}
          valueFrom:
            secretKeyRef:
              name: {{ include "apitestrig.envSecretName" $ }}
              key: {{ $key }}
        {{- end }}
        {{- end }}
      envFrom:
        {{- range .Values.apitestrig.extraEnvVarsCM }}
        - configMapRef:
            name: {{ . }}
        {{- end }}
        {{- range .Values.apitestrig.extraEnvVarsSecretRefs }}
        - secretRef:
            name: {{ . }}
        {{- end }}
      volumeMounts:
        - name: reports
          mountPath: {{ .Values.reports.mountPath }}
        {{- if .Values.apitestrig.configLocal.enabled }}
        - name: config-local
          mountPath: /app/secrets
          readOnly: true
        {{- end }}
        {{- if .Values.apitestrig.configOverride }}
        - name: custom-config
          mountPath: /app/custom-config
          readOnly: true
        {{- end }}
        {{- if .Values.apitestrig.conformancePlanConfig.enabled }}
        - name: conformance-plan-config
          mountPath: /app/conformance-suite-private
          readOnly: true
        {{- end }}
      resources: {{- toYaml .Values.resources | nindent 8 }}
    {{- if .Values.reports.s3.enabled }}
    - name: report-uploader
      image: {{ include "common.images.image" (dict "imageRoot" .Values.reports.s3.image "global" .Values.global) }}
      imagePullPolicy: {{ .Values.reports.s3.image.pullPolicy }}
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -e
          export HOME=/tmp
          until [ -f {{ printf "%s/.rig-complete" .Values.reports.mountPath | quote }} ]; do
            sleep 5
          done
          INSECURE_FLAG=""
          [ "$S3_INSECURE" = "true" ] && INSECURE_FLAG="--insecure"
          mc alias set target "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" $INSECURE_FLAG
          DEST="target/$S3_BUCKET/$S3_PATH_PREFIX/$(date -u +%Y%m%dT%H%M%SZ)"
          mc cp $INSECURE_FLAG --recursive {{ .Values.reports.mountPath }}/ "$DEST/"
          echo "Uploaded reports to $DEST"
      env:
        - name: S3_ENDPOINT
          value: {{ .Values.reports.s3.endpoint | quote }}
        - name: S3_BUCKET
          value: {{ .Values.reports.s3.bucket | quote }}
        - name: S3_PATH_PREFIX
          value: {{ .Values.reports.s3.pathPrefix | quote }}
        - name: S3_INSECURE
          value: {{ .Values.reports.s3.insecure | quote }}
        - name: S3_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: {{ include "apitestrig.s3SecretName" . }}
              key: {{ .Values.reports.s3.existingSecretAccessKeyKey }}
        - name: S3_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: {{ include "apitestrig.s3SecretName" . }}
              key: {{ .Values.reports.s3.existingSecretSecretKeyKey }}
      volumeMounts:
        - name: reports
          mountPath: {{ .Values.reports.mountPath }}
          readOnly: true
    {{- end }}
  volumes:
    - name: reports
      {{- if .Values.reports.persistence.enabled }}
      persistentVolumeClaim:
        claimName: {{ include "apitestrig.reportsClaimName" . }}
      {{- else }}
      emptyDir: {}
      {{- end }}
    {{- if .Values.apitestrig.configLocal.enabled }}
    - name: config-local
      secret:
        secretName: {{ include "apitestrig.configLocalSecretName" . }}
        items:
          - key: {{ .Values.apitestrig.configLocal.existingSecretKey }}
            path: config.local.json
    {{- end }}
    {{- if .Values.apitestrig.configOverride }}
    - name: custom-config
      configMap:
        name: {{ include "common.names.fullname" . }}-config
    {{- end }}
    {{- if .Values.apitestrig.conformancePlanConfig.enabled }}
    - name: conformance-plan-config
      secret:
        secretName: {{ include "apitestrig.conformancePlanConfigSecretName" . }}
        defaultMode: 0400
    {{- end }}
{{- end -}}
