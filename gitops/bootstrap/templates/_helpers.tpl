{{/*
Validate that required global config is present. Fails the render early with a
clear message instead of producing broken Applications.
*/}}
{{- define "bootstrap.validate" -}}
{{- if not .Values.git.repoURL }}{{ fail "git.repoURL must be set (values.yaml or the root app's valuesObject)" }}{{ end }}
{{- if not .Values.git.targetRevision }}{{ fail "git.targetRevision must be set (values.yaml or the root app's valuesObject)" }}{{ end }}
{{- if not .Values.cluster.server }}{{ fail "cluster.server must be set (values.yaml or the root app's valuesObject)" }}{{ end }}
{{- end }}
