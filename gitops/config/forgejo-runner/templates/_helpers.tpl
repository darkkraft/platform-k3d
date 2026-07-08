{{- define "forgejo-runner.labels" -}}
app.kubernetes.io/name: forgejo-runner
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: argocd
{{- end }}
