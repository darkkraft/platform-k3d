terraform {
  required_version = ">= 1.11.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    # Seed + runner registration are irreducibly imperative (git push, forgejo-cli
    # via kubectl exec) — driven through local-exec on null_resource.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
