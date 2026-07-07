terraform {
  # OpenTofu 1.11+ is required for the ephemeral resources used by the services
  # layer; we pin the same floor here so both layers share one toolchain.
  required_version = ">= 1.11.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # gavinbunney/kubectl applies raw CRs (ArgoCD Application / AppProject)
    # without the plan-time schema validation that hashicorp/kubernetes's
    # kubernetes_manifest performs. That validation would fail on a first apply
    # because the Argo CRDs do not exist until the Helm release installs them.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
    # ArgoCD refresh nudge + Vault readiness gate via local-exec.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
