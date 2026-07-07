locals {
  # Fully-qualified push refs, e.g. localhost:5111/api-service:abc123.
  refs = { for name, _ in var.images : name => "${var.registry_push}/${name}:${var.image_tag}" }

  # Per-image rebuild triggers: the opaque cluster trigger plus a content hash
  # for each watched file, so a pin bump re-bakes exactly the affected image.
  triggers = {
    for name, img in var.images : name => merge(
      { rebuild = var.rebuild_trigger },
      { for f in img.watch_files : f => filesha256("${var.repo_root}/${f}") }
    )
  }
}
