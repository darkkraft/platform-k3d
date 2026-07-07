# `tofu test` — the vault-config variable contract (plan-only, providers mocked).
mock_provider "vault" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

variables {
  name             = "platform-dev"
  mount_path       = "platform"
  services         = { api = { database = "orders", role = "api_service" } }
  eso_namespace    = "external-secrets"
  eso_token_secret = "vault-token"
  eso_token_ttl    = "768h"
}

run "valid_defaults" {
  command = plan
}

run "reject_short_password" {
  command = plan
  variables {
    password_length = 8
  }
  expect_failures = [var.password_length]
}

run "reject_non_snake_role" {
  command = plan
  variables {
    services = { api = { database = "orders", role = "API-Service" } }
  }
  expect_failures = [var.services]
}

run "reject_slash_in_mount" {
  command = plan
  variables {
    mount_path = "platform-secret-path-with-no-slash-allowed/x"
  }
  expect_failures = [var.mount_path]
}

run "reject_grafana_path_outside_monitoring" {
  command = plan
  variables {
    grafana_secret_path = "db/grafana"
  }
  expect_failures = [var.grafana_secret_path]
}
