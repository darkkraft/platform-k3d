# Seed Forgejo with the caller's working tree so ArgoCD has something to
# reconcile: create org + repo over the API, then git-push HEAD to main.
# Runs inside this module (Forgejo lifecycle), before ArgoCD even installs,
# so the root Application syncs on its first attempt.
#
# Irreducible imperative step: no Terraform provider can push a git tree.
# Everything provider-shaped (org/repo existence) is still handled idempotently.
resource "null_resource" "seed" {
  count = var.seed.enabled ? 1 : 0

  triggers = {
    cluster = var.seed.trigger
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      FJ_NS     = kubernetes_namespace.this.metadata[0].name
      FJ_SVC    = local.http_service
      FJ_ORG    = var.org
      FJ_REPO   = var.repo
      FJ_USER   = var.admin_username
      FJ_PASS   = random_password.admin.result
      REPO_ROOT = var.seed.repo_root
    }
    command = <<-EOT
      set -euo pipefail
      CTX="${var.kube_context}"
      kubectl --context "$CTX" -n "$FJ_NS" rollout status deploy/forgejo --timeout=300s \
        || kubectl --context "$CTX" -n "$FJ_NS" wait --for=condition=ready pod -l app.kubernetes.io/name=forgejo --timeout=300s

      # Bind a RANDOM free local port (":3000" lets kubectl choose) so the seed
      # never collides with a host service already on 3000. Parse the chosen port.
      PFLOG="$(mktemp)"
      kubectl --context "$CTX" -n "$FJ_NS" port-forward "svc/$FJ_SVC" :3000 >"$PFLOG" 2>&1 &
      PF_PID=$!
      trap 'kill $PF_PID 2>/dev/null || true; rm -f "$PFLOG"' EXIT
      LP=""
      for i in $(seq 1 60); do
        LP="$(sed -n 's/.*127\.0\.0\.1:\([0-9]\{1,\}\).*/\1/p' "$PFLOG" | head -1)"
        if [ -n "$LP" ] && curl -fsS "http://localhost:$LP/api/healthz" >/dev/null 2>&1; then break; fi
        sleep 1
      done
      [ -n "$LP" ] || { echo "ERROR: forgejo port-forward never became ready" >&2; cat "$PFLOG" >&2; exit 1; }

      # Create org + repo (ignore 'already exists' on re-run).
      curl -fsS -u "$FJ_USER:$FJ_PASS" -H 'Content-Type: application/json' \
        -X POST "http://localhost:$LP/api/v1/orgs" -d "{\"username\":\"$FJ_ORG\"}" >/dev/null 2>&1 || true
      curl -fsS -u "$FJ_USER:$FJ_PASS" -H 'Content-Type: application/json' \
        -X POST "http://localhost:$LP/api/v1/orgs/$FJ_ORG/repos" \
        -d "{\"name\":\"$FJ_REPO\",\"private\":false,\"default_branch\":\"main\"}" >/dev/null 2>&1 || true

      # Push the working tree (errors surface — no output suppression). All envs
      # track `main`, so main is the only ref ArgoCD needs.
      git -C "$REPO_ROOT" -c http.extraHeader= push -f \
        "http://$FJ_USER:$FJ_PASS@localhost:$LP/$FJ_ORG/$FJ_REPO.git" HEAD:refs/heads/main
    EOT
  }

  depends_on = [helm_release.this]
}
