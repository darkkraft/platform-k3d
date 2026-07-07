# Dev environment facts, shared by the bootstrap and services units in this env.
locals {
  environment = "dev"

  # Single-node-ish sandbox: 1 server + 1 agent so anti-affinity can schedule.
  # Ports 80/443 on the host -> Traefik. (staging/prod use different host ports
  # so all three could run on one machine simultaneously.)
  cluster = {
    servers    = 1
    agents     = 1
    http_port  = 80   # override per-host with env K3D_HTTP_PORT if :80 is taken
    https_port = 443  # override with K3D_HTTPS_PORT
    api_port   = 6445 # fixed API port -> stable kubeconfig endpoint
    k3s_image  = "rancher/k3s:v1.36.2-k3s1"
  }

  argocd = {
    namespace       = "argocd"
    chart_version   = "10.1.2"
    server_insecure = true
  }

  # Documented external/prod GitOps source. In the sandbox local_git (Forgejo) is
  # on by default, so ArgoCD reconciles from Forgejo and this is just the fallback.
  gitops = {
    repo_url        = "https://github.com/example-org/platform-gitops.git"
    target_revision = "main"
    bootstrap_path  = "gitops/bootstrap"
  }
}
