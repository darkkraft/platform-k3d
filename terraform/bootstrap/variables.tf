variable "prefix" {
  type        = string
  default     = "platform"
  description = "Organisation/product prefix used to name resources (e.g. platform-dev-...)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.prefix))
    error_message = "[${var.prefix}] prefix is not allowed: 2-21 chars, lowercase alphanumeric or dashes, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment. Selects the per-env values file consumed by the ArgoCD root app and names the k3d cluster."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "[${var.environment}] environment is not allowed. Use one of: dev, staging, prod."
  }
}

variable "repo_root" {
  type        = string
  description = "Absolute path to the git repo root (Terragrunt passes get_repo_root()). Used to seed Forgejo from the working tree — Terragrunt runs from a cache dir, so path.module cannot locate the source."

  validation {
    condition     = startswith(var.repo_root, "/")
    error_message = "[${var.repo_root}] repo_root is not allowed: must be an absolute path (Terragrunt: repo_root = get_repo_root())."
  }
}

variable "profile" {
  type        = string
  default     = "full"
  description = "Platform profile. 'full' deploys every component; 'tiny' skips the heavy observability add-ons (Loki, Alloy, blackbox, trivy-operator) so the stack fits a resource-constrained host (~8 GB). Injected into the ArgoCD root app; Terragrunt sources it from the PROFILE env var (default full)."

  validation {
    condition     = contains(["full", "tiny"], var.profile)
    error_message = "[${var.profile}] profile is not allowed. Use one of: full, tiny."
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "Path to the kubeconfig file. k3d merges the cluster context into it on create."

  validation {
    condition     = length(trimspace(var.kubeconfig_path)) > 0
    error_message = "kubeconfig_path is not allowed to be empty."
  }
}

variable "kube_context" {
  type        = string
  description = "kubeconfig context of this env's k3d cluster (k3d-<name>). Injected by Terragrunt from the cluster layer's output; it exists before this layer's providers configure."

  validation {
    condition     = length(trimspace(var.kube_context)) > 0
    error_message = "kube_context is not allowed to be empty."
  }
}

variable "cluster_id" {
  type        = string
  default     = ""
  description = "Opaque cluster id from the cluster layer; changes on cluster recreation to re-trigger the local-exec seed/wait steps."
}

variable "app_namespace" {
  type        = string
  default     = "app"
  description = "Namespace that hosts the application workloads and their database."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.app_namespace))
    error_message = "[${var.app_namespace}] app_namespace is not allowed: must be an RFC-1123 label."
  }
}

variable "argocd" {
  type = object({
    namespace       = string
    chart_version   = string
    server_insecure = optional(bool, true)
    # UI host via Traefik (no port-forward). Empty = no ingress. Only effective
    # with server_insecure=true; a TLS-mode server (prod) keeps port-forward.
    ingress_host = optional(string, "argocd.127.0.0.1.sslip.io")
  })
  default = {
    namespace     = "argocd"
    chart_version = "10.1.2"
  }
  description = "ArgoCD install configuration. chart_version pins the argo/argo-cd Helm chart; server_insecure=true is acceptable only behind an in-cluster ingress/TLS terminator (documented trade-off for the sandbox)."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.argocd.namespace))
    error_message = "[${var.argocd.namespace}] argocd.namespace is not allowed: must be an RFC-1123 label."
  }

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.argocd.chart_version))
    error_message = "[${var.argocd.chart_version}] argocd.chart_version is not allowed: must be an exact semver (x.y.z) so the control plane is reproducible."
  }
}

variable "gitops" {
  type = object({
    repo_url        = string
    target_revision = string
    bootstrap_path  = optional(string, "gitops/bootstrap")
  })
  description = "Git source ArgoCD reconciles when local_git is disabled (e.g. GitHub). repo_url must be reachable by the ArgoCD repo-server; target_revision is a branch, tag, or commit."

  validation {
    condition     = can(regex("^(https?://|git@).+", var.gitops.repo_url))
    error_message = "[${var.gitops.repo_url}] gitops.repo_url is not allowed: must be an http(s):// or git@ URL."
  }

  validation {
    condition     = length(trimspace(var.gitops.target_revision)) > 0
    error_message = "gitops.target_revision is not allowed to be empty: pin a branch, tag, or commit."
  }

  validation {
    condition     = length(trimspace(var.gitops.bootstrap_path)) > 0 && !startswith(var.gitops.bootstrap_path, "/")
    error_message = "[${var.gitops.bootstrap_path}] gitops.bootstrap_path is not allowed: must be a non-empty repo-relative path."
  }
}

variable "local_git" {
  type = object({
    enabled        = optional(bool, true)
    chart_version  = optional(string, "17.1.1")
    org            = optional(string, "platform")
    repo           = optional(string, "platform-gitops")
    ingress_host   = optional(string, "forgejo.127.0.0.1.sslip.io")
    admin_username = optional(string, "platformadmin")
  })
  default     = {}
  description = "When enabled, deploy an in-cluster Forgejo as the GitOps source (self-contained sandbox). ArgoCD then reconciles from Forgejo instead of var.gitops.repo_url. Disable for a real GitHub/GitLab source (production)."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.local_git.chart_version))
    error_message = "[${var.local_git.chart_version}] local_git.chart_version is not allowed: must be an exact semver (x.y.z)."
  }

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.local_git.ingress_host))
    error_message = "[${var.local_git.ingress_host}] local_git.ingress_host is not allowed: must be a DNS hostname."
  }
}

variable "git_credentials" {
  type = object({
    username = optional(string, "")
    # Personal Access Token / GitHub App token. NEVER commit this; supply via
    # TF_VAR_git_credentials or a gitignored *.auto.tfvars outside version control.
    token = optional(string, "")
  })
  default     = {}
  sensitive   = true
  description = "Credentials for a private GitOps repo. Leave empty for a public repo."
}

variable "labels" {
  type = object({
    managed_by = optional(string, "opentofu")
    part_of    = optional(string, "platform")
    owner      = string
  })
  default = {
    owner = "platform-team"
  }
  description = "Common labels stamped onto TF-managed resources for ownership and provenance."

  validation {
    condition     = length(trimspace(var.labels.owner)) > 0
    error_message = "labels.owner is not allowed to be empty: every resource needs an accountable owner."
  }
}
