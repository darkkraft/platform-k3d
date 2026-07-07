# Local Docker daemon (default unix socket) — used only to build the app/CI
# images and push them to the k3d registry. Independent of the cluster itself.
provider "docker" {
  # The k3d registry is anonymous and speaks plain HTTP. docker_registry_image
  # needs (1) an auth entry for the registry to exist — placeholder credentials
  # the auth-less registry ignores — and (2) the explicit http:// scheme, which
  # is the provider's documented switch off HTTPS for insecure local registries.
  registry_auth {
    address  = "http://localhost:${var.registry.port}"
    username = "anonymous"
    password = "anonymous"
  }
}
