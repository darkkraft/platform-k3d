# `tofu test` — the forgejo variable contract (plan-only, providers mocked).
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "null" {}

variables {
  kube_context = "k3d-platform-dev"
  # Callers always pass an absolute repo_root (Terragrunt get_repo_root()); the
  # module's bare {} default is only valid once that is supplied.
  seed = { enabled = true, repo_root = "/repo" }
}

run "valid_defaults" {
  command = plan
}

run "reject_non_semver_chart" {
  command = plan
  variables {
    chart_version = "17.1"
  }
  expect_failures = [var.chart_version]
}

run "reject_bad_admin_username" {
  command = plan
  variables {
    admin_username = "Bad_User"
  }
  expect_failures = [var.admin_username]
}

run "reject_bad_storage_size" {
  command = plan
  variables {
    storage_size = "2GB"
  }
  expect_failures = [var.storage_size]
}

run "reject_relative_seed_repo_root" {
  command = plan
  variables {
    seed = { enabled = true, repo_root = "relative/path" }
  }
  expect_failures = [var.seed]
}
