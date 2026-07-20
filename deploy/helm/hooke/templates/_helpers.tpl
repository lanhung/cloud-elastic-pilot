{{- define "hooke.name" -}}hooke{{- end -}}
{{- define "hooke.fullname" -}}{{ .Release.Name }}{{- end -}}
{{- define "hooke.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "hooke.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
{{- define "hooke.image" -}}{{ printf "%s:%s" .Values.image.repository .Values.image.tag }}{{- end -}}
{{- define "hooke.authTokenEnv" -}}
{{- if .Values.global.authTokenSecret.name }}
- name: HOOKE_AUTH_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.authTokenSecret.name }}
      key: {{ .Values.global.authTokenSecret.key }}
{{- end }}
{{- end -}}
