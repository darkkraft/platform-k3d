{{- define "portal.labels" -}}
app.kubernetes.io/name: portal
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "portal.selectorLabels" -}}
app.kubernetes.io/name: portal
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
