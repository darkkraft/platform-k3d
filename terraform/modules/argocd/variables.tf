variable "name" {
  type        = string
  description = "Resource name stem (e.g. platform-dev), used for labels and manifest names."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "[${var.name}] name is not allowed: lowercase alphanumeric/dashes, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Environment name; injected into the bootstrap chart so each app layers its gitops/config/<name>/<env>.yaml overlay."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "[${var.environment}] environment is not allowed. Use one of: dev, staging, prod."
  }
}

variable "profile" {
  type        = string
  default     = "full"
  description = "Deployment profile injected into the bootstrap chart via the root Application. 'full' renders every app; 'tiny' skips apps flagged heavy (Loki/Alloy/blackbox/trivy-operator) to fit a resource-constrained host."

  validation {
    condition     = contains(["full", "tiny"], var.profile)
    error_message = "[${var.profile}] profile is not allowed. Use one of: full, tiny."
  }
}

variable "app_namespace" {
  type        = string
  default     = "app"
  description = "Namespace the business microservices deploy into. The 'apps' AppProject is scoped to only this namespace (least privilege)."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.app_namespace))
    error_message = "[${var.app_namespace}] app_namespace is not allowed: must be an RFC-1123 label."
  }
}

variable "namespace" {
  type        = string
  default     = "argocd"
  description = "Namespace for the ArgoCD control plane."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "[${var.namespace}] namespace is not allowed: must be an RFC-1123 label."
  }
}

variable "chart_version" {
  type        = string
  description = "Exact argo/argo-cd Helm chart version."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.chart_version))
    error_message = "[${var.chart_version}] chart_version is not allowed: must be an exact semver (x.y.z) so the control plane is reproducible."
  }
}

variable "server_insecure" {
  type        = bool
  default     = true
  description = "Run argocd-server without its own TLS (terminate TLS at the ingress instead)."
}

variable "ingress_host" {
  type        = string
  default     = ""
  description = "Ingress host for the ArgoCD UI via k3s Traefik (e.g. argocd.127.0.0.1.sslip.io). Only effective with server_insecure=true (plain-HTTP backend); empty disables the ingress (port-forward access)."

  validation {
    condition     = var.ingress_host == "" || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.ingress_host))
    error_message = "[${var.ingress_host}] ingress_host is not allowed: must be empty or a DNS hostname."
  }
}

variable "common_labels" {
  type        = map(string)
  default     = {}
  description = "Labels applied to module-managed resources."
}

variable "gitops_repo_url" {
  type        = string
  description = "Git repository ArgoCD reconciles from."

  validation {
    condition     = can(regex("^(https?://|git@).+", var.gitops_repo_url))
    error_message = "[${var.gitops_repo_url}] gitops_repo_url is not allowed: must be an http(s):// or git@ URL."
  }
}

variable "gitops_revision" {
  type        = string
  description = "Git branch/tag/commit ArgoCD tracks."

  validation {
    condition     = length(trimspace(var.gitops_revision)) > 0
    error_message = "gitops_revision is not allowed to be empty: pin a branch, tag, or commit."
  }
}

variable "bootstrap_path" {
  type        = string
  default     = "gitops/bootstrap"
  description = "Path within the repo to the app-of-apps bootstrap Helm chart."

  validation {
    condition     = length(trimspace(var.bootstrap_path)) > 0 && !startswith(var.bootstrap_path, "/")
    error_message = "[${var.bootstrap_path}] bootstrap_path is not allowed: must be a non-empty repo-relative path."
  }
}

variable "git_username" {
  type        = string
  default     = ""
  description = "Username for a private repo (empty for public)."
}

variable "git_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "PAT/GitHub App token for a private repo (empty for public)."
}

variable "additional_source_repos" {
  type        = list(string)
  default     = []
  description = "Upstream Helm chart repo URLs the platform apps pull from, added to each AppProject's sourceRepos allow-list alongside the GitOps repo."

  validation {
    condition     = alltrue([for r in var.additional_source_repos : can(regex("^https://", r))])
    error_message = "additional_source_repos is not allowed: every entry must be an https:// URL (no plaintext chart sources)."
  }
}

variable "create_repo_secret" {
  type        = bool
  default     = false
  description = "Whether to create the ArgoCD repo-credentials Secret. Must be a plan-known value (do NOT derive it from a generated token)."
}

variable "git_repo_url_override" {
  type        = string
  default     = ""
  description = "If set, injected as git.repoURL into the bootstrap chart via the root Application so every CHILD app reconciles from this source (Forgejo in the sandbox), overriding the value baked in gitops/bootstrap/values.yaml."

  validation {
    condition     = var.git_repo_url_override == "" || can(regex("^(https?://|git@).+", var.git_repo_url_override))
    error_message = "[${var.git_repo_url_override}] git_repo_url_override is not allowed: must be empty or an http(s):// / git@ URL."
  }
}
