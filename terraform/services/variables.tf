variable "prefix" {
  type        = string
  default     = "platform"
  description = "Organisation/product prefix, matching the bootstrap layer."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.prefix))
    error_message = "[${var.prefix}] prefix is not allowed: 2-21 chars, lowercase alphanumeric or dashes, starting with a letter."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment (must match the bootstrap workspace)."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "[${var.environment}] environment is not allowed. Use one of: dev, staging, prod."
  }
}

variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "Path to the kubeconfig file."

  validation {
    condition     = length(trimspace(var.kubeconfig_path)) > 0
    error_message = "kubeconfig_path is not allowed to be empty."
  }
}

variable "kube_context" {
  type        = string
  description = "kubeconfig context to target. Terragrunt injects this from the bootstrap layer's output (k3d-<prefix>-<env>). REQUIRED (no default): a hardcoded default risked a standalone `prod` run silently targeting the dev cluster."

  validation {
    condition     = length(trimspace(var.kube_context)) > 0
    error_message = "kube_context is not allowed to be empty."
  }
}

variable "vault_namespace" {
  type        = string
  default     = "vault"
  description = "Namespace where Vault runs (the services layer reaches it via its Traefik ingress). Vault is isolated from the restricted-PSA application namespace."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.vault_namespace))
    error_message = "[${var.vault_namespace}] vault_namespace is not allowed: must be an RFC-1123 label."
  }
}

variable "app_namespace" {
  type        = string
  default     = "app"
  description = "Namespace holding the application workloads + their ESO-materialised DB Secrets (Terragrunt injects it from the bootstrap layer). The DB-role reconcile step waits for those Secrets here."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.app_namespace))
    error_message = "[${var.app_namespace}] app_namespace is not allowed: must be an RFC-1123 label."
  }
}

variable "cnpg_namespace" {
  type        = string
  default     = "cnpg-system"
  description = "Namespace where the CloudNativePG operator runs (bounced once after secrets land so it reconciles the managed-role passwords)."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cnpg_namespace))
    error_message = "[${var.cnpg_namespace}] cnpg_namespace is not allowed: must be an RFC-1123 label."
  }
}

variable "ingress_http_port" {
  type        = number
  default     = 80
  description = "Host port published to the cluster's Traefik ingress (:80). Used to reach Vault's ingress when configuring it; matches the env's cluster.http_port."

  validation {
    condition     = var.ingress_http_port >= 1 && var.ingress_http_port <= 65535
    error_message = "[${var.ingress_http_port}] ingress_http_port is not allowed: must be 1-65535."
  }
}

variable "vault" {
  type = object({
    # Traefik ingress host that fronts Vault (sslip.io resolves to 127.0.0.1 on
    # the host). The services layer configures Vault through this ingress rather
    # than exposing it via a NodePort.
    ingress_host = optional(string, "vault.127.0.0.1.sslip.io")
    # KV-v2 mount path for platform secrets. A dedicated mount (not the default
    # "secret/") keeps our data isolated and policy scoping explicit.
    mount_path = optional(string, "platform")
  })
  default     = {}
  description = "Vault mount configuration + the ingress host used to reach it (non-secret)."

  validation {
    condition     = length(trimspace(var.vault.ingress_host)) > 0
    error_message = "vault.ingress_host is not allowed to be empty."
  }

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.vault.mount_path))
    error_message = "[${var.vault.mount_path}] vault.mount_path is not allowed: lowercase alphanumeric/dashes, no slashes."
  }
}

variable "vault_token" {
  type = string
  # Root/admin token of the target Vault. In the sandbox this is the dev-mode
  # root token; a production Vault uses AppRole/Kubernetes auth, never a static
  # token. Supply via TF_VAR_vault_token (never commit it):
  #   export TF_VAR_vault_token=root
  sensitive   = true
  description = "Token used by OpenTofu to configure Vault."

  validation {
    condition     = length(var.vault_token) > 0
    error_message = "vault_token is not allowed to be empty: provide it via TF_VAR_vault_token; it is never stored in committed tfvars."
  }
}

variable "eso" {
  type = object({
    namespace    = optional(string, "external-secrets")
    token_secret = optional(string, "vault-token")
    token_ttl    = optional(string, "768h")
  })
  default     = {}
  description = "External Secrets Operator integration: namespace and the k8s Secret holding the scoped Vault token ESO authenticates with."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.eso.namespace)) && can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.eso.token_secret))
    error_message = "[${var.eso.namespace}/${var.eso.token_secret}] eso is not allowed: namespace and token_secret must be RFC-1123 names."
  }

  validation {
    condition     = can(regex("^[0-9]+(h|m|s)$", var.eso.token_ttl))
    error_message = "[${var.eso.token_ttl}] eso.token_ttl is not allowed: must be a Vault duration like 768h."
  }
}

variable "services" {
  type = map(object({
    database = string
    role     = string
  }))
  default = {
    api-service = {
      database = "orders"
      role     = "api_service"
    }
    inventory-service = {
      database = "inventory"
      role     = "inventory_service"
    }
  }
  description = "Per-service database credential definitions. Each service gets its own least-privileged role/password stored in Vault; CNPG grants it access to only its own database."

  validation {
    condition     = length(var.services) > 0
    error_message = "services is not allowed to be empty: define at least one service."
  }

  validation {
    condition     = alltrue([for _, s in var.services : can(regex("^[a-z][a-z0-9_]{2,30}$", s.role)) && can(regex("^[a-z][a-z0-9_]{2,30}$", s.database))])
    error_message = "services is not allowed: every role and database must be a lowercase snake_case identifier (3-31 chars)."
  }
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
