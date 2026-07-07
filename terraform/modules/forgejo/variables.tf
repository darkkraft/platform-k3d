variable "namespace" {
  type        = string
  default     = "forgejo"
  description = "Namespace for the in-cluster Forgejo (sandbox GitOps source)."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "[${var.namespace}] namespace is not allowed: must be an RFC-1123 label."
  }
}

variable "kube_context" {
  type        = string
  description = "kubeconfig context of the target cluster; the seed and runner-registration steps drive kubectl against it."

  validation {
    condition     = length(trimspace(var.kube_context)) > 0
    error_message = "kube_context is not allowed to be empty."
  }
}

variable "chart_version" {
  type        = string
  default     = "17.1.1"
  description = "forgejo-helm OCI chart version (oci://code.forgejo.org/forgejo-helm/forgejo)."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.chart_version))
    error_message = "[${var.chart_version}] chart_version is not allowed: must be an exact semver (x.y.z) so the install is reproducible."
  }
}

variable "admin_username" {
  type        = string
  default     = "platformadmin"
  description = "Forgejo admin username created on first boot."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.admin_username))
    error_message = "[${var.admin_username}] admin_username is not allowed: lowercase alphanumeric/dashes, 3-31 chars, starting with a letter."
  }
}

variable "org" {
  type        = string
  default     = "platform"
  description = "Forgejo org that owns the GitOps repo."

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,38}$", var.org))
    error_message = "[${var.org}] org is not allowed: must be a valid Forgejo org name."
  }
}

variable "repo" {
  type        = string
  default     = "platform-gitops"
  description = "Forgejo repo name that ArgoCD reconciles."

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$", var.repo))
    error_message = "[${var.repo}] repo is not allowed: must be a valid git repository name."
  }
}

variable "ingress_host" {
  type        = string
  default     = "forgejo.127.0.0.1.sslip.io"
  description = "Ingress host for browser/CLI access to Forgejo via k3s Traefik."

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.ingress_host))
    error_message = "[${var.ingress_host}] ingress_host is not allowed: must be a DNS hostname."
  }
}

variable "storage_size" {
  type        = string
  default     = "2Gi"
  description = "PVC size for Forgejo data."

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.storage_size))
    error_message = "[${var.storage_size}] storage_size is not allowed: must be a k8s quantity like 512Mi or 2Gi."
  }
}

variable "seed" {
  type = object({
    # Push the caller's working tree into Forgejo so ArgoCD has content to
    # reconcile on first sync.
    enabled = optional(bool, true)
    # Absolute path to the git repo to push (Terragrunt: get_repo_root()).
    repo_root = optional(string, "")
    # Opaque re-seed trigger; wire the cluster_id so a recreated cluster is re-seeded.
    trigger = optional(string, "")
  })
  default     = {}
  description = "Working-tree seeding of the GitOps repo (org + repo creation, git push of HEAD and tags)."

  validation {
    condition     = !var.seed.enabled || startswith(var.seed.repo_root, "/")
    error_message = "seed is not allowed: when seed.enabled, seed.repo_root must be an absolute path."
  }
}

variable "runner" {
  type = object({
    # Register a Forgejo Actions runner secret so the in-cluster runner
    # (deployed by ArgoCD from gitops/config/forgejo-runner) can execute CI.
    enabled = optional(bool, true)
    name    = optional(string, "k3d-runner")
    labels  = optional(string, "docker")
    # k8s Secret name the runner chart mounts — must match
    # gitops/config/forgejo-runner/values.yaml.
    secret_name = optional(string, "forgejo-runner-secret")
  })
  default     = {}
  description = "Forgejo Actions runner registration (offline, idempotent, shared-secret method)."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.runner.secret_name))
    error_message = "[${var.runner.secret_name}] runner.secret_name is not allowed: must be an RFC-1123 name."
  }
}

variable "common_labels" {
  type        = map(string)
  default     = {}
  description = "Labels applied to module-managed resources."
}
