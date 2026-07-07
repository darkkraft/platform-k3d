# Shared "bootstrap" layer unit. Runs after the cluster layer (Terragrunt
# dependency), so var.kube_context exists before this layer's providers configure.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/terraform//bootstrap"
}

dependency "cluster" {
  config_path                             = "../cluster"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "destroy"]
  mock_outputs = {
    kube_context = "k3d-platform-${local.env.locals.environment}"
    cluster_id   = "mock"
    cluster_name = "platform-${local.env.locals.environment}"
  }
}

inputs = {
  environment  = local.env.locals.environment
  repo_root    = get_repo_root()
  kube_context = dependency.cluster.outputs.kube_context
  cluster_id   = dependency.cluster.outputs.cluster_id
  argocd       = local.env.locals.argocd
  gitops       = local.env.locals.gitops
  # Opt-in resource profile: PROFILE=tiny skips the heavy observability add-ons
  # (Loki/Alloy/blackbox/trivy-operator) so the stack fits ~8 GB. Default: full.
  profile = get_env("PROFILE", "full")
}
