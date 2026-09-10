{{/*
Return the proper image name
*/}}
{{- define "uitestrig.image" -}}
{{ include "common.images.image" (dict "imageRoot" .Values.image "global" .Values.global) }}
{{- end -}}

{{/*
Return the proper Docker Image Registry Secret Names
*/}}
{{- define "uitestrig.imagePullSecrets" -}}
{{- include "common.images.pullSecrets" (dict "images" (list .Values.image) "global" .Values.global) -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "uitestrig.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (printf "%s" (include "common.names.fullname" .)) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Name of the ConfigMap rendered from uitestrig.configMap.
*/}}
{{- define "uitestrig.configMapName" -}}
{{ include "common.names.fullname" . }}-config
{{- end -}}

{{/*
Name of the Secret rendered from uitestrig.secret.
*/}}
{{- define "uitestrig.secretName" -}}
{{ include "common.names.fullname" . }}-secret
{{- end -}}

{{/*
Name of the Secret backing BrowserStack credentials.
*/}}
{{- define "uitestrig.browserstackSecretName" -}}
{{ include "common.names.fullname" . }}-browserstack
{{- end -}}

{{/*
Name of the PVC backing the reports volume.
*/}}
{{- define "uitestrig.reportsClaimName" -}}
{{- if .Values.reports.persistence.existingClaim -}}
{{ .Values.reports.persistence.existingClaim }}
{{- else -}}
{{ include "common.names.fullname" . }}-reports
{{- end -}}
{{- end -}}

{{/*
The shared pod spec used by both cronjob.yaml and job.yaml.
*/}}
{{- define "uitestrig.podTemplate" -}}
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
  serviceAccountName: {{ include "uitestrig.serviceAccountName" . }}
  {{- include "uitestrig.imagePullSecrets" . | nindent 2 }}
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
  initContainers:
    {{/*
    The image bakes in /home/mosip/test-output/SparkReport/ (see Dockerfile)
    for the reporting library's benefit -- mounting a volume at
    reports.mountPath hides that baked-in subdirectory on a fresh
    PVC/emptyDir, so recreate it here before the main container starts.
    Always runs, regardless of enableInsecure.
    */}}
    - name: prepare-report-dirs
      image: {{ include "uitestrig.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: ["/bin/sh", "-c"]
      args:
        - mkdir -p {{ .Values.reports.mountPath }}/SparkReport
      volumeMounts:
        - name: reports
          mountPath: {{ .Values.reports.mountPath }}
          subPath: test-output
    {{- if .Values.uitestrig.enableInsecure }}
    {{/*
    Imports the eSignet host's certificate into a JVM cacerts truststore,
    same pattern as the old Java apitestrig chart (mosip-functional-tests,
    helm/apitestrig) -- but this image's base is eclipse-temurin, whose
    JAVA_HOME is /opt/java/openjdk (confirmed against Adoptium/Temurin's own
    docs), NOT /usr/local/openjdk-11 like that older chart's image. The base
    image's own built-in USE_SYSTEM_CA_CERTS auto-handling doesn't apply here
    since uitest-esignet's Dockerfile sets its own ENTRYPOINT, bypassing the
    base image's cert-processing entrypoint entirely -- hence doing this by
    hand instead. UNVERIFIED against a live cluster; test before relying on it.
    */}}
    - name: import-cacerts
      image: {{ include "uitestrig.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -e
          HOST=$(printf '%s' "$ESIGNET_HOST_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*##; s#:.*##')
          CACERTS_SRC=/opt/java/openjdk/lib/security/cacerts
          if [ -z "$HOST" ]; then
            echo "no eSignet host configured, copying default cacerts unchanged"
            cp "$CACERTS_SRC" /cacerts/cacerts
            exit 0
          fi
          apk add --no-cache openssl >/dev/null 2>&1 || true
          openssl s_client -servername "$HOST" -connect "$HOST:443" </dev/null 2>/dev/null \
            | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > "/tmp/$HOST.cer"
          cp "$CACERTS_SRC" /tmp/cacerts
          keytool -delete -alias "$HOST" -keystore /tmp/cacerts -storepass changeit >/dev/null 2>&1 || true
          keytool -trustcacerts -keystore /tmp/cacerts -storepass changeit -noprompt \
            -importcert -alias "$HOST" -file "/tmp/$HOST.cer"
          cp /tmp/cacerts /cacerts/cacerts
      env:
        - name: ESIGNET_HOST_URL
          value: {{ .Values.uitestrig.configMap.eSignetbaseurl | quote }}
      volumeMounts:
        - name: cacerts
          mountPath: /cacerts
    {{- end }}
  containers:
    - name: uitestrig
      image: {{ include "uitestrig.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      {{- if .Values.containerSecurityContext.enabled }}
      securityContext: {{- omit .Values.containerSecurityContext "enabled" | toYaml | nindent 8 }}
      {{- end }}
      {{- if .Values.uitestrig.command }}
      command: {{- include "common.tplvalues.render" (dict "value" .Values.uitestrig.command "context" $) | nindent 8 }}
      {{- end }}
      {{- if .Values.uitestrig.args }}
      args:
        {{- include "common.tplvalues.render" (dict "value" .Values.uitestrig.args "context" $) | nindent 8 }}
      {{- end }}
      env:
        {{- range $key, $value := .Values.uitestrig.extraEnvVars }}
        {{- if $value }}
        - name: {{ $key }}
          value: {{ $value | quote }}
        {{- end }}
        {{- end }}
      envFrom:
        - configMapRef:
            name: {{ include "uitestrig.configMapName" . }}
        - secretRef:
            name: {{ include "uitestrig.secretName" . }}
        {{- if .Values.uitestrig.browserstack.enabled }}
        - secretRef:
            name: {{ include "uitestrig.browserstackSecretName" . }}
        {{- end }}
        {{- range .Values.uitestrig.extraEnvVarsCM }}
        - configMapRef:
            name: {{ . }}
        {{- end }}
        {{- range .Values.uitestrig.extraEnvVarsSecretRefs }}
        - secretRef:
            name: {{ . }}
        {{- end }}
      volumeMounts:
        - name: reports
          mountPath: {{ .Values.reports.mountPath }}
          subPath: test-output
        - name: reports
          mountPath: {{ .Values.reports.screenshotsMountPath }}
          subPath: screenshots
        {{- if .Values.uitestrig.enableInsecure }}
        - name: cacerts
          mountPath: /opt/java/openjdk/lib/security/cacerts
          subPath: cacerts
        {{- end }}
      resources: {{- toYaml .Values.resources | nindent 8 }}
  volumes:
    - name: reports
      {{- if .Values.reports.persistence.enabled }}
      persistentVolumeClaim:
        claimName: {{ include "uitestrig.reportsClaimName" . }}
      {{- else }}
      emptyDir: {}
      {{- end }}
    {{- if .Values.uitestrig.enableInsecure }}
    - name: cacerts
      emptyDir: {}
    {{- end }}
{{- end -}}
