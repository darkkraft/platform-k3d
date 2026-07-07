locals {
  # Same naming stem as the other layers: platform-dev, platform-staging, platform-prod.
  name = "${var.prefix}-${var.environment}"

  common_labels = {
    "app.kubernetes.io/managed-by"     = var.labels.managed_by
    "app.kubernetes.io/part-of"        = var.labels.part_of
    "platform.example.com/owner"       = var.labels.owner
    "platform.example.com/environment" = var.environment
  }
}
