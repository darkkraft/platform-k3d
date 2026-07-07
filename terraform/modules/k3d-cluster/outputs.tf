output "kube_context" {
  value       = local.kube_context
  description = "kubeconfig context for this environment's k3d cluster (k3d-<name>)."
}

output "cluster_name" {
  value       = var.cluster_name
  description = "k3d cluster name (used for `k3d image import` when loading local builds)."
}

output "registry_ref" {
  value       = local.registry_ref
  description = "In-cluster registry host (image prefix for deployments): k3d-<name>:<port>."
}

output "registry_push" {
  value       = local.registry_push
  description = "Host-side registry push target: localhost:<port>."
}

output "cluster_id" {
  # Referencing the null_resource id lets callers depend_on the module so their
  # kubernetes/helm resources only run after the cluster is Ready.
  value       = null_resource.cluster.id
  description = "Opaque id that changes when the cluster is (re)provisioned."
}
