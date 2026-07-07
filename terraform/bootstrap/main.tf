# -----------------------------------------------------------------------------
# Layer 1 — bootstrap. One `terragrunt apply` per environment brings up:
#   ArgoCD + Forgejo (seeded with this repo) -> root app -> wait for Vault
#   (so the services layer can configure it next).
# Everything after ArgoCD is reconciled from git by ArgoCD, not by OpenTofu.
#
# The k3d cluster itself is Layer 0 (terraform/cluster, a Terragrunt dependency),
# so var.kube_context already exists when this layer's providers configure.
# Composition lives in the concern-named siblings: forgejo.tf, argocd.tf, vault.tf.
# -----------------------------------------------------------------------------

# Application namespace. Created here (not by ArgoCD CreateNamespace) so we own
# its Pod Security Admission labels from the start of the workload lifecycle.
resource "kubernetes_namespace" "app" {
  metadata {
    name   = var.app_namespace
    labels = merge(local.common_labels, local.pss_labels)
  }
}
