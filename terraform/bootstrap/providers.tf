# All three providers target the k3d cluster's context, derived from the env name
# (known at plan time). The kubernetes/helm/kubectl resources depend_on the k3d
# module so the cluster + context exist before anything is applied to them.
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = local.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = local.kube_context
  }
}

provider "kubectl" {
  config_path       = var.kubeconfig_path
  config_context    = local.kube_context
  load_config_file  = true
  apply_retry_count = 3
}
