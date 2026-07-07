locals {
  # Every resource is named/derived from this single stem so environments never
  # collide and names are predictable: platform-dev, platform-staging, platform-prod.
  name = "${var.prefix}-${var.environment}"

  # kube-context comes from the Layer-0 cluster root (Terragrunt dependency); it
  # already exists when this layer's kubernetes/helm/kubectl providers configure.
  kube_context = var.kube_context

  common_labels = {
    "app.kubernetes.io/managed-by"     = var.labels.managed_by
    "app.kubernetes.io/part-of"        = var.labels.part_of
    "platform.example.com/owner"       = var.labels.owner
    "platform.example.com/environment" = var.environment
  }

  # Pod Security Admission baseline for the application namespace. The workloads
  # (distroless, non-root, no privilege escalation) satisfy "restricted"; we run
  # audit+warn at the same level so violations are visible even before enforce.
  pss_labels = {
    "pod-security.kubernetes.io/enforce"         = "restricted"
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/audit"           = "restricted"
    "pod-security.kubernetes.io/warn"            = "restricted"
  }

  # The GitOps source ArgoCD actually reconciles from: in-cluster Forgejo in the
  # sandbox, or the configured external remote in production. Only repoURL +
  # credentials change; the rest of the platform is identical.
  effective_repo_url     = var.local_git.enabled ? module.forgejo[0].internal_repo_url : var.gitops.repo_url
  effective_git_username = var.local_git.enabled ? module.forgejo[0].admin_username : var.git_credentials.username
  effective_git_token    = var.local_git.enabled ? module.forgejo[0].admin_password : var.git_credentials.token
  # ArgoCD tracks the environment's configured revision (env.hcl). All envs track
  # `main`; prod's safety is the Argo Rollouts manual promotion gate, not branch
  # isolation. The seed pushes HEAD:main into Forgejo as the in-cluster source.
  effective_revision = var.gitops.target_revision
}
