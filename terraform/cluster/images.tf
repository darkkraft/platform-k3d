# Build the app + CI images and PUSH them to the k3d registry (reliable pull by
# k3s, survives restarts — no flaky `k3d image import`). Fully declarative via
# the docker provider: one docker_image/docker_registry_image pair per image,
# rebuilt when its watch_files hash changes or the cluster is recreated.
# Tagged with a real tag (never :latest) so the Kyverno disallow-latest policy
# passes — the module enforces that at plan time.
module "images" {
  count  = var.build.enabled ? 1 : 0
  source = "../modules/registry-images"

  registry_push   = module.k3d.registry_push
  image_tag       = var.build.image_tag
  repo_root       = var.repo_root
  images          = var.build.images
  rebuild_trigger = module.k3d.cluster_id

  # The registry container must exist before the push.
  depends_on = [module.k3d]
}
