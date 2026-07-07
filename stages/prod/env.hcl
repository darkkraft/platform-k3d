# Prod environment facts. More nodes for real anti-affinity/HA, TLS on the ArgoCD
# server. Tracks `main` like the other envs; prod's safety is the Argo Rollouts
# MANUAL promotion gate (autoPromotionEnabled=false) — a merged change syncs the
# manifests but the new version health-checks in PREVIEW and only takes live
# traffic when a human promotes it.
locals {
  environment = "prod"

  cluster = {
    servers    = 1
    agents     = 2
    http_port  = 9080
    https_port = 9443
    api_port   = 6447
    k3s_image  = "rancher/k3s:v1.36.2-k3s1"
  }

  argocd = {
    namespace       = "argocd"
    chart_version   = "10.1.2"
    server_insecure = false
  }

  gitops = {
    repo_url        = "https://github.com/example-org/platform-gitops.git"
    target_revision = "main"
    bootstrap_path  = "gitops/bootstrap"
  }
}
