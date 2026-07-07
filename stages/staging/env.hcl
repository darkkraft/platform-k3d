# Staging environment facts. Its own k3d cluster on different host ports so it can
# coexist with dev on one machine.
locals {
  environment = "staging"

  cluster = {
    servers    = 1
    agents     = 1
    http_port  = 8080
    https_port = 8443
    api_port   = 6446
    k3s_image  = "rancher/k3s:v1.36.2-k3s1"
  }

  argocd = {
    namespace       = "argocd"
    chart_version   = "10.1.2"
    server_insecure = true
  }

  gitops = {
    repo_url        = "https://github.com/example-org/platform-gitops.git"
    target_revision = "main"
    bootstrap_path  = "gitops/bootstrap"
  }
}
