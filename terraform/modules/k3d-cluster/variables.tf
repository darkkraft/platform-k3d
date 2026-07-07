variable "cluster_name" {
  type        = string
  description = "k3d cluster name (one per environment, e.g. platform-dev). kube-context becomes k3d-<name>."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.cluster_name))
    error_message = "[${var.cluster_name}] cluster_name is not allowed: lowercase alphanumeric/dashes, starting with a letter, 2-31 chars."
  }
}

variable "servers" {
  type        = number
  default     = 1
  description = "Number of k3s server (control-plane) nodes."

  validation {
    condition     = var.servers >= 1 && var.servers <= 3
    error_message = "[${var.servers}] servers is not allowed: must be between 1 and 3."
  }
}

variable "agents" {
  type        = number
  default     = 1
  description = "Number of k3s agent (worker) nodes. 1+ lets anti-affinity/HA actually schedule across nodes."

  validation {
    condition     = var.agents >= 0 && var.agents <= 5
    error_message = "[${var.agents}] agents is not allowed: must be between 0 and 5."
  }
}

variable "http_port" {
  type        = number
  default     = 80
  description = "Host port mapped to the cluster loadbalancer :80 (Traefik ingress). Must be unique per simultaneously-running env."

  validation {
    condition     = var.http_port >= 1 && var.http_port <= 65535
    error_message = "[${var.http_port}] http_port is not allowed: must be 1-65535."
  }
}

variable "https_port" {
  type        = number
  default     = 443
  description = "Host port mapped to the cluster loadbalancer :443 (Traefik ingress)."

  validation {
    condition     = var.https_port >= 1 && var.https_port <= 65535
    error_message = "[${var.https_port}] https_port is not allowed: must be 1-65535."
  }

  validation {
    condition     = var.https_port != var.http_port
    error_message = "[${var.https_port}] https_port is not allowed: must differ from http_port."
  }
}

variable "api_port" {
  type        = number
  default     = 0
  description = "Fixed host port for the Kubernetes API (0 = k3d picks a random port). Set a stable per-env port so the kubeconfig endpoint doesn't change on recreate and remote access is predictable."

  validation {
    condition     = var.api_port == 0 || (var.api_port >= 1024 && var.api_port <= 65535)
    error_message = "[${var.api_port}] api_port is not allowed: must be 0 (random) or 1024-65535."
  }

  validation {
    condition     = var.api_port == 0 || (var.api_port != var.http_port && var.api_port != var.https_port)
    error_message = "[${var.api_port}] api_port is not allowed: must differ from http_port and https_port."
  }
}

variable "tls_sans" {
  type        = list(string)
  default     = []
  description = "Extra IPs/hostnames added to the API server cert SANs (e.g. this host's LAN/Tailscale IP) so a remote kubectl validates TLS instead of needing insecure-skip-tls-verify."

  validation {
    condition     = alltrue([for s in var.tls_sans : can(regex("^[a-zA-Z0-9.:-]+$", s))])
    error_message = "tls_sans is not allowed: each entry must be a bare IP or hostname (no schemes, no spaces)."
  }
}

variable "k3s_image" {
  type        = string
  default     = "rancher/k3s:v1.36.2-k3s1"
  description = "Pinned k3s image k3d runs, so the Kubernetes version is reproducible."

  validation {
    condition     = can(regex("^rancher/k3s:v[0-9]+\\.[0-9]+\\.[0-9]+-k3s[0-9]+$", var.k3s_image))
    error_message = "[${var.k3s_image}] k3s_image is not allowed: must be an exactly-pinned rancher/k3s:vX.Y.Z-k3sN image (no :latest, no floating tags)."
  }
}

variable "wait_timeout" {
  type        = string
  default     = "300s"
  description = "How long k3d/kubectl wait for the cluster and nodes to be ready."

  validation {
    condition     = can(regex("^[0-9]+(s|m)$", var.wait_timeout))
    error_message = "[${var.wait_timeout}] wait_timeout is not allowed: must be a duration like 300s or 5m."
  }
}

variable "registry_name" {
  type        = string
  default     = "platform-registry"
  description = "Shared k3d-managed registry name (k3d prefixes it 'k3d-'). Created once, reused across clusters; images are pushed here and pulled by k3s reliably (no flaky image import)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.registry_name))
    error_message = "[${var.registry_name}] registry_name is not allowed: lowercase alphanumeric/dashes, starting with a letter."
  }
}

variable "registry_port" {
  type        = number
  default     = 5111
  description = "Host port for the k3d registry. In-cluster ref is k3d-<registry_name>:<registry_port>; host push target is localhost:<registry_port>."

  validation {
    condition     = var.registry_port >= 1024 && var.registry_port <= 65535
    error_message = "[${var.registry_port}] registry_port is not allowed: must be 1024-65535."
  }

  validation {
    condition     = var.registry_port != var.http_port && var.registry_port != var.https_port && var.registry_port != var.api_port
    error_message = "[${var.registry_port}] registry_port is not allowed: must differ from http_port, https_port, and api_port."
  }
}
