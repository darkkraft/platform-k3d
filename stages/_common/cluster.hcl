# Shared "cluster" layer unit (included by every stages/<env>/cluster). Pure data:
# env.hcl declares the per-env cluster object; only per-host escape hatches
# (busy ports, slow machines, shared-host node count) come from K3D_* env vars.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

terraform {
  source = "${get_repo_root()}/terraform//cluster"
}

inputs = {
  environment = local.env.locals.environment
  repo_root   = get_repo_root()

  cluster = merge(local.env.locals.cluster, {
    http_port    = tonumber(get_env("K3D_HTTP_PORT", tostring(local.env.locals.cluster.http_port)))
    https_port   = tonumber(get_env("K3D_HTTPS_PORT", tostring(local.env.locals.cluster.https_port)))
    wait_timeout = get_env("K3D_WAIT_TIMEOUT", "300s")
    # env.hcl sets the design node count (prod = 2 agents); on a shared host
    # already running other clusters, override down with K3D_AGENTS to fit.
    agents = tonumber(get_env("K3D_AGENTS", tostring(local.env.locals.cluster.agents)))
  })

  tls_sans = compact(split(",", get_env("K3D_TLS_SAN", "")))
}
