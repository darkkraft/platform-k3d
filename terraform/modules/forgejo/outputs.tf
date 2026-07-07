output "internal_repo_url" {
  value       = local.internal_repo_url
  description = "In-cluster git URL ArgoCD reconciles from."
}

output "http_service" {
  value       = "${local.http_service}.${var.namespace}"
  description = "namespace-qualified http service (for port-forward during seeding)."
}

output "namespace" {
  value       = kubernetes_namespace.this.metadata[0].name
  description = "Forgejo namespace."
}

output "ingress_host" {
  value       = var.ingress_host
  description = "Browser/CLI host for Forgejo."
}

output "admin_username" {
  value       = var.admin_username
  description = "Forgejo admin username."
}

output "admin_password" {
  value       = random_password.admin.result
  sensitive   = true
  description = "Forgejo admin password (used to seed the repo and log into the UI)."
}

output "org" {
  value       = var.org
  description = "GitOps org."
}

output "repo" {
  value       = var.repo
  description = "GitOps repo name."
}

output "seed_id" {
  value       = var.seed.enabled ? null_resource.seed[0].id : ""
  description = "Changes whenever the repo is (re)seeded — callers use it to trigger an ArgoCD refresh."
}
