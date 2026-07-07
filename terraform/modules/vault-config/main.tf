# KV-v2 mount dedicated to platform secrets (isolated from Vault's default
# secret/ mount so policy scoping is explicit).
resource "vault_mount" "this" {
  path        = var.mount_path
  type        = "kv-v2"
  description = "Platform DB credentials for ${var.name}"
}

# One random password per service. Excludes shell/URL-hostile characters so the
# value is safe in connection strings and basic-auth secrets alike.
resource "random_password" "db" {
  for_each = var.services

  length           = var.password_length
  special          = true
  override_special = "-_.~"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
}

# Credentials in Vault. ESO reads these and materialises basic-auth k8s Secrets;
# CNPG consumes those to set each managed role's password.
resource "vault_kv_secret_v2" "db" {
  for_each = var.services

  mount = vault_mount.this.path
  name  = "db/${each.key}"

  data_json = jsonencode({
    username = each.value.role
    password = random_password.db[each.key].result
    database = each.value.database
  })
}

# Grafana admin credential (random, no plaintext anywhere). ESO materialises it
# into the monitoring namespace as the Secret kube-prometheus-stack consumes via
# grafana.admin.existingSecret. Toggle off if Grafana is disabled.
resource "random_password" "grafana" {
  count = var.enable_grafana ? 1 : 0

  length           = var.password_length
  special          = true
  override_special = "-_.~"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
}

resource "vault_kv_secret_v2" "grafana" {
  count = var.enable_grafana ? 1 : 0

  mount = vault_mount.this.path
  name  = var.grafana_secret_path

  data_json = jsonencode({
    username = "admin"
    password = random_password.grafana[0].result
  })
}

resource "vault_policy" "eso" {
  name   = "${var.name}-eso-read"
  policy = local.eso_policy
}

# A scoped, renewable token for ESO. Least privilege: it can only read db/* under
# our mount — not the whole Vault. Rotation = tofu apply (new token) or ESO's own
# token renewal within the TTL.
resource "vault_token" "eso" {
  policies  = [vault_policy.eso.name]
  period    = var.eso_token_ttl
  renewable = true
  # Do not tie the token's life to the (short-lived) provider session.
  no_parent = true

  metadata = {
    purpose = "external-secrets-operator"
    env     = var.name
  }
}

resource "kubernetes_secret" "eso_token" {
  metadata {
    name      = var.eso_token_secret
    namespace = var.eso_namespace
    labels    = var.common_labels
  }

  data = {
    token = vault_token.eso.client_token
  }

  type = "Opaque"
}
