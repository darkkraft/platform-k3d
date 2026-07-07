# Shared "services" layer unit. Runs after bootstrap (Terragrunt dependency),
# which only returns once Vault is up (wait_for_vault). Wires this layer to the
# bootstrap layer's outputs (replaces terraform_remote_state).
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/terraform//services"
}

dependency "bootstrap" {
  config_path                             = "../bootstrap"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "destroy"]
  mock_outputs = {
    kube_context    = "k3d-platform-${local.env.locals.environment}"
    vault_namespace = "vault"
    app_namespace   = "app"
  }
}

inputs = {
  environment     = local.env.locals.environment
  kube_context    = dependency.bootstrap.outputs.kube_context
  vault_namespace = dependency.bootstrap.outputs.vault_namespace
  app_namespace   = dependency.bootstrap.outputs.app_namespace
  # Host port fronting Traefik — the layer reaches Vault's ingress on it.
  ingress_http_port = tonumber(get_env("K3D_HTTP_PORT", tostring(local.env.locals.cluster.http_port)))
  # vault_token comes from TF_VAR_vault_token (dev root token) — never committed.
}
