locals {
  # Every resource is named/derived from this single stem so environments never
  # collide and names are predictable: platform-dev, platform-staging, platform-prod.
  name = "${var.prefix}-${var.environment}"
}
