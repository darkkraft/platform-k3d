# Build every image against the local Docker daemon. Declarative replacement
# for the previous docker-build local-exec: one resource per image, rebuilds
# driven by plan-visible triggers instead of shell re-runs.
resource "docker_image" "this" {
  for_each = var.images

  name = local.refs[each.key]

  build {
    context    = "${var.repo_root}/${each.value.context}"
    dockerfile = each.value.dockerfile
  }

  # Keep the image on the daemon when the resource is destroyed — teardown of an
  # environment should not evict layers other environments' builds still reuse.
  keep_locally = true

  triggers = local.triggers[each.key]
}

# Push each built image to the k3d registry, where k3s pulls it reliably
# (survives cluster restarts — unlike the flaky `k3d image import`).
resource "docker_registry_image" "this" {
  for_each = var.images

  name          = docker_image.this[each.key].name
  keep_remotely = true

  # The k3d registry speaks plain HTTP: the provider's registry client tries
  # HTTPS first and needs this to fall back (the daemon-side push already
  # treats localhost as insecure by default).
  insecure_skip_verify = var.insecure_registry

  triggers = local.triggers[each.key]
}
