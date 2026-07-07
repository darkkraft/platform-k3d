output "vault_mount_path" {
  value       = module.vault_config.mount_path
  description = "KV-v2 mount path holding per-service database credentials."
}

output "service_secret_paths" {
  value       = module.vault_config.secret_paths
  description = "Vault paths where each service's credentials are stored (for ExternalSecret remoteRefs)."
}

output "eso_token_secret" {
  value       = module.vault_config.eso_token_secret_ref
  description = "Namespace/name of the k8s Secret holding the scoped Vault token ESO uses."
}
