locals {
  http_service = "forgejo-http"

  # In-cluster URL ArgoCD's repo-server uses to reconcile. Stand-in for GitHub;
  # in production this becomes an https://github.com/... URL (see bootstrap docs).
  internal_repo_url = "http://${local.http_service}.${var.namespace}.svc:3000/${var.org}/${var.repo}.git"
}
