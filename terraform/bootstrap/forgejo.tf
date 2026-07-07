# In-cluster Forgejo as the sandbox GitOps source (stand-in for GitHub). Deployed
# only when local_git.enabled; production disables it and points at a real remote.
# The module owns the full Forgejo lifecycle: install, seeding this repo's
# working tree (so ArgoCD has content on its first sync), and idempotent
# Actions-runner registration.
module "forgejo" {
  count  = var.local_git.enabled ? 1 : 0
  source = "../modules/forgejo"

  kube_context   = local.kube_context
  chart_version  = var.local_git.chart_version
  org            = var.local_git.org
  repo           = var.local_git.repo
  ingress_host   = var.local_git.ingress_host
  admin_username = var.local_git.admin_username
  common_labels  = local.common_labels

  seed = {
    repo_root = var.repo_root
    # Re-seed whenever the cluster is recreated.
    trigger = var.cluster_id
  }
}
