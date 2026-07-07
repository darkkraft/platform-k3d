output "mount_path" {
  value       = vault_mount.this.path
  description = "KV-v2 mount path."
}

output "secret_paths" {
  value = {
    for k, v in vault_kv_secret_v2.db : k => "${vault_mount.this.path}/db/${k}"
  }
  description = "Vault KV paths for each service's credentials (data path is <mount>/data/db/<service>)."
}

output "eso_token_secret_ref" {
  value       = "${kubernetes_secret.eso_token.metadata[0].namespace}/${kubernetes_secret.eso_token.metadata[0].name}"
  description = "Namespace/name of the k8s Secret holding the scoped Vault token."
}
