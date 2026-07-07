# -----------------------------------------------------------------------------
# Layer 0 — cluster. Provisions this environment's k3d cluster and builds/pushes
# the app + CI images. No kubernetes/helm provider here — those would need a
# kube-context that does not exist yet (bootstrap runs after this layer via a
# Terragrunt dependency). The docker provider only talks to the local daemon,
# so it has no such chicken-and-egg.
# -----------------------------------------------------------------------------

module "k3d" {
  source = "../modules/k3d-cluster"

  cluster_name  = local.name
  servers       = var.cluster.servers
  agents        = var.cluster.agents
  http_port     = var.cluster.http_port
  https_port    = var.cluster.https_port
  api_port      = var.cluster.api_port
  k3s_image     = var.cluster.k3s_image
  wait_timeout  = var.cluster.wait_timeout
  tls_sans      = var.tls_sans
  registry_name = var.registry.name
  registry_port = var.registry.port
}
