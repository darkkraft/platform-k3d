terraform {
  required_version = ">= 1.11.0"

  required_providers {
    # Declarative image build + push (no local-exec/bash): docker_image builds
    # against the local daemon, docker_registry_image pushes through it. The
    # daemon treats localhost registries as insecure by default, so the plain
    # HTTP k3d registry needs no extra TLS configuration.
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}
