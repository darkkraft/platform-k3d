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
  description = "Deployment environment. Names the k3d cluster (<prefix>-<environment>)."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "[${var.environment}] environment is not allowed. Use one of: dev, staging, prod."
  }
}

variable "repo_root" {
  type        = string
  description = "Absolute repo root (Terragrunt get_repo_root()) — build context for the images."

  validation {
    condition     = startswith(var.repo_root, "/")
    error_message = "[${var.repo_root}] repo_root is not allowed: must be an absolute path (Terragrunt: repo_root = get_repo_root())."
  }
}

variable "cluster" {
  type = object({
    # Node topology. 1+ agents lets anti-affinity/HA actually schedule across nodes.
    servers = optional(number, 1)
    agents  = optional(number, 1)
    # Host ports mapped to the cluster loadbalancer (Traefik ingress). Must be
    # unique per simultaneously-running environment.
    http_port  = optional(number, 80)
    https_port = optional(number, 443)
    # Fixed host port for the Kubernetes API (0 = k3d picks a random port).
    # A stable per-env port keeps the kubeconfig endpoint constant across recreates.
    api_port = optional(number, 0)
    # Pinned k3s image so the Kubernetes version is reproducible.
    k3s_image = optional(string, "rancher/k3s:v1.36.2-k3s1")
    # How long k3d/kubectl wait for the cluster and nodes to be ready.
    wait_timeout = optional(string, "300s")
  })
  default     = {}
  description = "k3d cluster topology and host-port mapping for this environment."

  validation {
    condition     = var.cluster.servers >= 1 && var.cluster.servers <= 3 && var.cluster.agents >= 0 && var.cluster.agents <= 5
    error_message = "[${var.cluster.servers}s/${var.cluster.agents}a] cluster topology is not allowed: servers 1-3, agents 0-5."
  }

  validation {
    condition = alltrue([
      var.cluster.http_port >= 1 && var.cluster.http_port <= 65535,
      var.cluster.https_port >= 1 && var.cluster.https_port <= 65535,
      var.cluster.api_port == 0 || (var.cluster.api_port >= 1024 && var.cluster.api_port <= 65535),
    ])
    error_message = "cluster ports are not allowed: http/https must be 1-65535, api_port 0 (random) or 1024-65535."
  }

  validation {
    condition     = length(distinct(compact([tostring(var.cluster.http_port), tostring(var.cluster.https_port), var.cluster.api_port == 0 ? "" : tostring(var.cluster.api_port)]))) == (var.cluster.api_port == 0 ? 2 : 3)
    error_message = "cluster ports are not allowed: http_port, https_port, and api_port must not collide."
  }

  validation {
    condition     = can(regex("^rancher/k3s:v[0-9]+\\.[0-9]+\\.[0-9]+-k3s[0-9]+$", var.cluster.k3s_image))
    error_message = "[${var.cluster.k3s_image}] cluster.k3s_image is not allowed: must be an exactly-pinned rancher/k3s:vX.Y.Z-k3sN image."
  }

  validation {
    condition     = can(regex("^[0-9]+(s|m)$", var.cluster.wait_timeout))
    error_message = "[${var.cluster.wait_timeout}] cluster.wait_timeout is not allowed: must be a duration like 300s or 5m."
  }
}

variable "tls_sans" {
  type        = list(string)
  default     = []
  description = "Extra API-server cert SANs (this host's LAN/Tailscale IP) for clean remote kubectl TLS."

  validation {
    condition     = alltrue([for s in var.tls_sans : can(regex("^[a-zA-Z0-9.:-]+$", s))])
    error_message = "tls_sans is not allowed: each entry must be a bare IP or hostname (no schemes, no spaces)."
  }
}

variable "registry" {
  type = object({
    # Shared k3d registry (created once, reused by every environment's cluster).
    name = optional(string, "platform-registry")
    port = optional(number, 5111)
  })
  default     = {}
  description = "Shared k3d image registry. In-cluster ref is k3d-<name>:<port>; host push target is localhost:<port>."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.registry.name))
    error_message = "[${var.registry.name}] registry.name is not allowed: lowercase alphanumeric/dashes, starting with a letter."
  }

  validation {
    condition     = var.registry.port >= 1024 && var.registry.port <= 65535
    error_message = "[${var.registry.port}] registry.port is not allowed: must be 1024-65535."
  }
}

variable "build" {
  type = object({
    # Build + push locally (set false to rely on CI-published images instead).
    enabled = optional(bool, true)
    # A real tag, never :latest — the registry-images module rejects :latest at
    # plan time, mirroring the Kyverno disallow-latest admission policy.
    image_tag = optional(string, "dev")
    # Images to build, keyed by name. context/dockerfile/watch_files are
    # relative to repo_root (dockerfile relative to its context).
    images = optional(map(object({
      context     = string
      dockerfile  = optional(string, "Dockerfile")
      watch_files = optional(list(string), [])
      })), {
      api-service       = { context = "apps/api-service" }
      inventory-service = { context = "apps/inventory-service" }
      # The CI toolchain image the Forgejo runner executes jobs in. Watches the
      # tool pins so a version bump re-bakes it — and only it.
      ci-runner = {
        context     = "."
        dockerfile  = ".forgejo/Dockerfile.ci"
        watch_files = [".forgejo/Dockerfile.ci", ".tool-versions"]
      }
    })
  })
  default     = {}
  description = "Local image build + push configuration for this environment's registry."
}
