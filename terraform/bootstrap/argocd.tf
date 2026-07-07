# ArgoCD control plane + the single seed Application (app-of-apps root). The root
# app renders the gitops/bootstrap chart from its single values.yaml; environment,
# profile, and the effective git source (Forgejo in the sandbox) are injected via
# valuesObject, so every CHILD app reconciles from that source and layers the
# right per-env overlay — no per-env values files.
module "argocd" {
  source = "../modules/argocd"

  name                  = local.name
  environment           = var.environment
  profile               = var.profile
  app_namespace         = var.app_namespace
  namespace             = var.argocd.namespace
  chart_version         = var.argocd.chart_version
  server_insecure       = var.argocd.server_insecure
  ingress_host          = var.argocd.ingress_host
  common_labels         = local.common_labels
  gitops_repo_url       = local.effective_repo_url
  gitops_revision       = local.effective_revision
  bootstrap_path        = var.gitops.bootstrap_path
  git_username          = local.effective_git_username
  git_token             = local.effective_git_token
  git_repo_url_override = local.effective_repo_url
  # Plan-known: create the repo secret whenever we have a source of creds
  # (Forgejo always provides them; external path when a token is set).
  create_repo_secret = var.local_git.enabled || var.git_credentials.token != ""

  # Upstream Helm repos the platform apps pull from (added to AppProject
  # sourceRepos alongside the GitOps repo). Keep in sync with gitops/bootstrap/values.yaml.
  additional_source_repos = [
    "https://charts.jetstack.io",
    "https://charts.external-secrets.io",
    "https://cloudnative-pg.github.io/charts",
    "https://helm.releases.hashicorp.com",
    "https://kyverno.github.io/kyverno",
    "https://prometheus-community.github.io/helm-charts",
    "https://grafana.github.io/helm-charts",
    "https://aquasecurity.github.io/helm-charts",
    "https://argoproj.github.io/argo-helm",
  ]

  # The app namespace (with its PSA labels) must exist before ArgoCD starts
  # syncing workloads into it.
  depends_on = [kubernetes_namespace.app]
}

# Forgejo is seeded before ArgoCD installs (the module dependency runs that way),
# so the root app normally syncs first try. On a RE-seed of a live cluster,
# nudge ArgoCD to re-read the repo immediately instead of waiting a poll cycle.
resource "null_resource" "argocd_refresh" {
  count = var.local_git.enabled ? 1 : 0

  triggers = {
    seed = module.forgejo[0].seed_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --context '${local.kube_context}' -n '${var.argocd.namespace}' annotate applications.argoproj.io root argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true"
  }

  depends_on = [module.argocd]
}
