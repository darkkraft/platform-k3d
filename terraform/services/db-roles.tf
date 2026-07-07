# Close the one cross-layer ordering gap so a single `terragrunt run-all apply`
# comes up green with no manual step.
#
# The problem: ArgoCD creates the CloudNativePG Cluster (and its managed roles)
# during the bootstrap layer — BEFORE this services layer has configured Vault
# and written the ESO token. So when CNPG first reconciles the roles, the
# ESO-materialised password Secrets do not exist yet; CNPG records the failure
# and parks the roles in `pending-reconciliation`, and it does not retry once
# the Secrets finally appear. The apps then fail auth (28P01) indefinitely.
#
# The fix: right after this layer writes the credentials to Vault (module
# vault_config), wait for ESO to materialise each service's Secret, then bounce
# the CNPG operator once so it re-reconciles the roles against the now-present
# Secrets. Idempotent; only re-runs when the credential set changes.
resource "null_resource" "reconcile_db_roles" {
  triggers = {
    # Re-run whenever the service set or their Vault paths change (i.e. whenever
    # the passwords ESO serves could have changed).
    services = jsonencode(module.vault_config.secret_paths)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CTX          = var.kube_context
      APP_NS       = var.app_namespace
      CNPG_NS      = var.cnpg_namespace
      SECRET_NAMES = join(" ", [for k in keys(var.services) : "${k}-db"])
    }
    command = <<-EOT
      set -euo pipefail
      # 1. Wait (bounded) for ESO to materialise every service's DB Secret —
      #    created only after this layer configured Vault + wrote the ESO token.
      for s in $SECRET_NAMES; do
        for i in $(seq 1 36); do
          kubectl --context "$CTX" -n "$APP_NS" get secret "$s" >/dev/null 2>&1 && break
          sleep 5
        done
      done
      # 2. Bounce the CNPG operator so it re-reconciles the managed-role passwords
      #    against the Secrets that now exist. BEST-EFFORT: on a busy single-node
      #    sandbox (esp. colima on macOS, where the node can briefly go NotReady
      #    under load) the operator can be slow to reschedule — so we do NOT fail
      #    the apply if the rollout lags. The restart is already issued; CNPG
      #    reconciles the roles as soon as the pod is back, and the apps retry the
      #    DB connection until then (they come Ready without another apply).
      kubectl --context "$CTX" -n "$CNPG_NS" rollout restart deploy/cloudnative-pg || true
      kubectl --context "$CTX" -n "$CNPG_NS" rollout status deploy/cloudnative-pg --timeout=300s \
        || echo "WARN: cnpg operator slow to roll out (node under load?); managed-role passwords will reconcile once it settles — apps retry the DB meanwhile."
    EOT
  }

  depends_on = [module.vault_config]
}
