# Block the apply until ArgoCD has brought Vault up (sync-wave 0), so the services
# layer (which configures Vault through its ingress) can run immediately after.
# Irreducible imperative step: "wait for another controller's rollout" has no
# provider-shaped equivalent in this layer.
resource "null_resource" "wait_for_vault" {
  triggers = {
    cluster = var.cluster_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "waiting for ArgoCD to deploy Vault (sync-wave 0)"
      for i in $(seq 1 60); do
        if kubectl --context "${local.kube_context}" -n vault get pod -l app.kubernetes.io/name=vault >/dev/null 2>&1; then
          kubectl --context "${local.kube_context}" -n vault wait --for=condition=ready pod \
            -l app.kubernetes.io/name=vault --timeout=300s && exit 0
        fi
        sleep 5
      done
      echo "WARN: Vault not ready yet; re-run the services layer once it is." >&2
    EOT
  }

  depends_on = [module.forgejo, module.argocd]
}
