output "pushed_refs" {
  value       = { for name, _ in var.images : name => local.refs[name] }
  description = "Host-side image refs that were built and pushed, keyed by image name."
}

output "image_tag" {
  value       = var.image_tag
  description = "Tag every image was pushed with (deployments reference k3d-<registry>:<port>/<name>:<this>)."
}
