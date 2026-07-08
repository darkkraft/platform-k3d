{{- define "secret-store.labels" -}}
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: argocd
app.kubernetes.io/component: secret-store
{{- end }}
