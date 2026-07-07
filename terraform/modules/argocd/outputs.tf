output "namespace" {
  value       = kubernetes_namespace.this.metadata[0].name
  description = "Namespace where ArgoCD runs."
}

output "root_application_name" {
  value       = "root"
  description = "Name of the app-of-apps root Application."
}

output "project_names" {
  value       = keys(local.projects)
  description = "AppProjects created for platform/apps/monitoring segregation."
}
