# `tofu test` — the registry-images variable contract (plan-only, docker mocked).
mock_provider "docker" {}

run "valid_defaults" {
  command = plan
  variables {
    registry_push = "localhost:5111"
    image_tag     = "dev"
    repo_root     = "/repo"
    images        = { api-service = { context = "apps/api-service" } }
  }
  assert {
    condition     = output.image_tag == "dev"
    error_message = "image_tag output should echo the input"
  }
}

run "reject_latest_tag" {
  command = plan
  variables {
    registry_push = "localhost:5111"
    image_tag     = "latest"
    repo_root     = "/repo"
    images        = { api-service = { context = "apps/api-service" } }
  }
  expect_failures = [var.image_tag]
}

run "reject_non_hostport_registry" {
  command = plan
  variables {
    registry_push = "not-a-host-port"
    image_tag     = "dev"
    repo_root     = "/repo"
    images        = { api-service = { context = "apps/api-service" } }
  }
  expect_failures = [var.registry_push]
}

run "reject_relative_repo_root" {
  command = plan
  variables {
    registry_push = "localhost:5111"
    image_tag     = "dev"
    repo_root     = "relative/path"
    images        = { api-service = { context = "apps/api-service" } }
  }
  expect_failures = [var.repo_root]
}

run "reject_empty_images" {
  command = plan
  variables {
    registry_push = "localhost:5111"
    image_tag     = "dev"
    repo_root     = "/repo"
    images        = {}
  }
  expect_failures = [var.images]
}
