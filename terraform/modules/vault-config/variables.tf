variable "name" {
  type        = string
  description = "Resource name stem (e.g. platform-dev)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "[${var.name}] name is not allowed: lowercase alphanumeric/dashes, starting with a letter."
  }
}

variable "mount_path" {
  type        = string
  description = "KV-v2 mount path for platform secrets."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.mount_path))
    error_message = "[${var.mount_path}] mount_path is not allowed: lowercase alphanumeric/dashes, no slashes."
  }
}

variable "services" {
  type = map(object({
    database = string
    role     = string
  }))
  description = "Per-service credential definitions."

  validation {
    condition     = length(var.services) > 0
    error_message = "services is not allowed to be empty: define at least one service."
  }

  validation {
    condition     = alltrue([for _, s in var.services : can(regex("^[a-z][a-z0-9_]{2,30}$", s.role)) && can(regex("^[a-z][a-z0-9_]{2,30}$", s.database))])
    error_message = "services is not allowed: every role and database must be a lowercase snake_case identifier (3-31 chars)."
  }
}

variable "eso_namespace" {
  type        = string
  description = "Namespace where External Secrets Operator runs and the token secret is written."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.eso_namespace))
    error_message = "[${var.eso_namespace}] eso_namespace is not allowed: must be an RFC-1123 label."
  }
}

variable "eso_token_secret" {
  type        = string
  description = "Name of the k8s Secret holding the scoped Vault token."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.eso_token_secret))
    error_message = "[${var.eso_token_secret}] eso_token_secret is not allowed: must be an RFC-1123 name."
  }
}

variable "eso_token_ttl" {
  type        = string
  description = "TTL/period for the ESO Vault token."

  validation {
    condition     = can(regex("^[0-9]+(h|m|s)$", var.eso_token_ttl))
    error_message = "[${var.eso_token_ttl}] eso_token_ttl is not allowed: must be a Vault duration like 768h."
  }
}

variable "enable_grafana" {
  type        = bool
  default     = true
  description = "Seed a random Grafana admin credential into Vault (materialised by ESO for kube-prometheus-stack)."
}

variable "grafana_secret_path" {
  type        = string
  default     = "monitoring/grafana"
  description = "KV path (under mount_path) for the Grafana admin credential. ESO reads it via the monitoring/* policy."

  validation {
    condition     = can(regex("^monitoring/[a-z0-9/_-]+$", var.grafana_secret_path))
    error_message = "[${var.grafana_secret_path}] grafana_secret_path is not allowed: must live under monitoring/ (the ESO policy only grants that subtree)."
  }
}

variable "password_length" {
  type        = number
  default     = 32
  description = "Length of generated database passwords."

  validation {
    condition     = var.password_length >= 24 && var.password_length <= 64
    error_message = "[${var.password_length}] password_length is not allowed: must be between 24 and 64."
  }
}

variable "common_labels" {
  type        = map(string)
  default     = {}
  description = "Labels applied to module-managed Kubernetes resources."
}
