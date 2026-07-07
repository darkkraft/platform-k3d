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
    # Declarative image build + push to the k3d registry. Talks only to the
    # local Docker daemon, so it needs no kube-context (bootstrap's providers
    # do — which is why they live in the next layer).
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}
