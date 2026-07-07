locals {
  # Vault policy granting read-only access to exactly this mount's db/* and
  # monitoring/* secrets. Rendered as HCL for the vault_policy document.
  eso_policy = <<-EOT
    path "${var.mount_path}/data/db/*" {
      capabilities = ["read"]
    }
    path "${var.mount_path}/metadata/db/*" {
      capabilities = ["read", "list"]
    }
    path "${var.mount_path}/data/monitoring/*" {
      capabilities = ["read"]
    }
    path "${var.mount_path}/metadata/monitoring/*" {
      capabilities = ["read", "list"]
    }
  EOT
}
