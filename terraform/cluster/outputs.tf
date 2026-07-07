output "kube_context" {
  value       = module.k3d.kube_context
  description = "kubeconfig context for this environment's k3d cluster (consumed by the bootstrap layer)."
}

output "cluster_name" {
  value       = module.k3d.cluster_name
  description = "k3d cluster name."
}

output "cluster_id" {
  value       = module.k3d.cluster_id
  description = "Opaque id that changes when the cluster is (re)provisioned; bootstrap uses it to order/trigger."
}

output "registry_ref" {
  value       = module.k3d.registry_ref
  description = "In-cluster registry host (image ref prefix for deployments): k3d-<name>:<port>."
}

output "pushed_images" {
  value       = var.build.enabled ? module.images[0].pushed_refs : {}
  description = "Image refs built and pushed to the registry by this layer."
}
