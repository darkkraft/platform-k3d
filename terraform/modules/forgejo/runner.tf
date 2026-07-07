# Idempotent Forgejo Actions runner registration (Forgejo's official offline
# method). A random 40-hex shared secret is (1) pre-registered on the server with
# `forgejo-cli actions register` (idempotent — safe to re-run), and (2) handed to
# the in-cluster runner as a k8s Secret so it can regenerate its .runner file on
# every (re)start WITHOUT creating duplicate runners.
resource "random_id" "runner_secret" {
  count       = var.runner.enabled ? 1 : 0
  byte_length = 20 # 40 hex chars, as Forgejo requires
}

resource "kubernetes_secret" "runner" {
  count = var.runner.enabled ? 1 : 0

  metadata {
    name      = var.runner.secret_name
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = var.common_labels
  }
  data = {
    secret = random_id.runner_secret[0].hex
  }
  type = "Opaque"
}

# Irreducible imperative step: forgejo-cli is only reachable via kubectl exec
# inside the server pod — Forgejo exposes no API for offline runner registration.
resource "null_resource" "runner_register" {
  count = var.runner.enabled ? 1 : 0

  triggers = {
    secret = random_id.runner_secret[0].hex
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      FJ_NS       = kubernetes_namespace.this.metadata[0].name
      SECRET      = random_id.runner_secret[0].hex
      RUNNER_NAME = var.runner.name
      LABELS      = var.runner.labels
    }
    command = <<-EOT
      set -euo pipefail
      CTX="${var.kube_context}"
      kubectl --context "$CTX" -n "$FJ_NS" rollout status deploy/forgejo --timeout=300s \
        || kubectl --context "$CTX" -n "$FJ_NS" wait --for=condition=ready pod \
             -l app.kubernetes.io/name=forgejo --timeout=300s

      # Register the runner's shared secret on the server. This MUST retry: the
      # readiness probe can pass before Forgejo finishes its DB migrations, so a
      # single `register` call can silently no-op and leave the runner
      # "unauthenticated: unregistered runner" (crashloop) with nothing re-trying.
      # The command is idempotent (keyed on name+secret), so retrying until it
      # succeeds is safe, and we fail loudly if it never does rather than leaving
      # a silently-broken CI runner.
      for i in $(seq 1 40); do
        POD="$(kubectl --context "$CTX" -n "$FJ_NS" get pod -l app.kubernetes.io/name=forgejo -o name 2>/dev/null | head -1)"
        if [ -n "$POD" ] && kubectl --context "$CTX" -n "$FJ_NS" exec -i "$POD" -- \
             forgejo forgejo-cli actions register --name "$RUNNER_NAME" --labels "$LABELS" --secret "$SECRET" 2>/dev/null; then
          echo "runner '$RUNNER_NAME' registered"
          exit 0
        fi
        echo "forgejo not ready to register the runner yet (attempt $i/40) — retrying in 5s"
        sleep 5
      done
      echo "ERROR: runner registration did not succeed after retries — CI runner would crashloop" >&2
      exit 1
    EOT
  }

  depends_on = [helm_release.this, kubernetes_secret.runner]
}
