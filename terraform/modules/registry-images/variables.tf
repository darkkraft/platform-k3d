variable "registry_push" {
  type        = string
  description = "Host-side registry push target (host:port), e.g. localhost:5111."

  validation {
    condition     = can(regex("^[a-z0-9.-]+:[0-9]{2,5}$", var.registry_push))
    error_message = "[${var.registry_push}] registry_push is not allowed: must be host:port."
  }
}

variable "image_tag" {
  type        = string
  description = "Tag applied to every built image. A real tag — never :latest — so the Kyverno disallow-latest policy holds at plan time, not just at admission."

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$", var.image_tag))
    error_message = "[${var.image_tag}] image_tag is not allowed: must be a valid OCI tag."
  }

  validation {
    condition     = var.image_tag != "latest"
    error_message = "[${var.image_tag}] image_tag is not allowed: ':latest' is rejected here for the same reason the Kyverno disallow-latest policy rejects it at admission."
  }
}

variable "repo_root" {
  type        = string
  description = "Absolute path to the git repo root; image build contexts are resolved relative to it."

  validation {
    condition     = startswith(var.repo_root, "/")
    error_message = "[${var.repo_root}] repo_root is not allowed: must be an absolute path."
  }
}

variable "images" {
  type = map(object({
    # Build context, relative to repo_root ("." for the repo itself).
    context = string
    # Dockerfile path relative to the context (default: <context>/Dockerfile).
    dockerfile = optional(string, "Dockerfile")
    # Files (relative to repo_root) whose content hash forces a rebuild when it
    # changes — e.g. the CI image watches .tool-versions so tool pins re-bake it.
    watch_files = optional(list(string), [])
  }))
  description = "Images to build and push, keyed by image name."

  validation {
    condition     = length(var.images) > 0
    error_message = "images is not allowed to be empty: define at least one image."
  }

  validation {
    condition     = alltrue([for name, _ in var.images : can(regex("^[a-z][a-z0-9-]{1,40}$", name))])
    error_message = "images is not allowed: every key must be a lowercase alphanumeric/dash image name."
  }

  validation {
    condition     = alltrue([for _, img in var.images : length(trimspace(img.context)) > 0])
    error_message = "images is not allowed: every context must be a non-empty path relative to repo_root."
  }
}

variable "insecure_registry" {
  type        = bool
  default     = true
  description = "The target registry speaks plain HTTP / self-signed TLS (true for the local k3d registry). Set false when pushing to a real TLS registry."
}

variable "rebuild_trigger" {
  type        = string
  default     = ""
  description = "Opaque value that forces a rebuild+push when it changes (wire the cluster_id so images are re-pushed into a recreated registry)."
}
