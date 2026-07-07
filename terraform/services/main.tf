# -----------------------------------------------------------------------------
# Layer 2 — services. Runs after bootstrap (Terragrunt dependency), once ArgoCD
# has brought Vault up. Configures the secrets platform through its in-cluster
# Traefik ingress — Vault is never exposed via a NodePort.
# -----------------------------------------------------------------------------

# Vault KV mount + per-service credentials, and the scoped token ESO uses to
# read them. Database roles/grants themselves are owned by CloudNativePG
# (declarative Cluster.spec.managed.roles), not by OpenTofu.
module "vault_config" {
  source = "../modules/vault-config"

  name             = local.name
  mount_path       = var.vault.mount_path
  services         = var.services
  eso_namespace    = var.eso.namespace
  eso_token_secret = var.eso.token_secret
  eso_token_ttl    = var.eso.token_ttl
  common_labels    = local.common_labels
}
