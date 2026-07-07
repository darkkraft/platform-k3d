terraform {
  required_version = ">= 1.11.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.5"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    # Post-secret CNPG role reconcile nudge via local-exec (see db-roles.tf).
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
