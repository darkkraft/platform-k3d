terraform {
  required_version = ">= 1.11.0"

  required_providers {
    # k3d has no first-class provider; the cluster is driven through local-exec
    # (the metal/k3s reference pattern, adapted to k3d for multi-cluster-per-host
    # on Linux+Docker). null_resource triggers give idempotent create/destroy.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
