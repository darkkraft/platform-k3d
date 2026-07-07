output "kube_context" {
  value       = local.kube_context
  description = "kubeconfig context for this environment's k3d cluster (consumed by the services layer via Terragrunt dependency)."
}

output "app_namespace" {
  value       = kubernetes_namespace.app.metadata[0].name
  description = "Namespace hosting the application workloads and database."
}

output "vault_namespace" {
  value       = "vault"
  description = "Namespace where ArgoCD deploys Vault (the services layer reaches it via its ingress)."
}

output "argocd_namespace" {
  value       = module.argocd.namespace
  description = "Namespace where the ArgoCD control plane runs."
}

output "argocd_root_application" {
  value       = module.argocd.root_application_name
  description = "Name of the app-of-apps root Application that fans out to every workload."
}

output "effective_repo_url" {
  value       = local.effective_repo_url
  description = "The git URL ArgoCD reconciles from (Forgejo in sandbox, external remote in prod)."
}

output "next_steps" {
  description = "How to reach ArgoCD and verify the platform after apply."
  value       = <<-EOT
    ArgoCD is installed in namespace "${module.argocd.namespace}" on context "${local.kube_context}".

    1. Admin password:
       kubectl --context ${local.kube_context} -n ${module.argocd.namespace} get secret argocd-initial-admin-secret \
         -o jsonpath='{.data.password}' | base64 -d && echo
    2. Port-forward the UI:
       kubectl --context ${local.kube_context} -n ${module.argocd.namespace} port-forward svc/argocd-server 8080:443
    3. Watch the platform converge:
       kubectl --context ${local.kube_context} -n ${module.argocd.namespace} get applications -w

    The services layer (Vault config) runs automatically after this via
    `terragrunt run-all apply`, or on its own:
       terragrunt apply --working-dir stages/${var.environment}/services
  EOT
}
