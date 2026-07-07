provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

# The services layer configures Vault through its in-cluster Traefik ingress
# (vault.<sslip>.io on the env's host HTTP port). Vault is never exposed via a
# NodePort; this is the same ingress that serves the UI, and the vault
# NetworkPolicy already admits Traefik. sslip.io resolves the host to 127.0.0.1,
# so this runs on the k3d host (where the ingress port is published).
provider "vault" {
  address = "http://${var.vault.ingress_host}:${var.ingress_http_port}"
  token   = var.vault_token
}
