# `tofu test` — the argocd variable contract (plan-only, providers mocked).
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

variables {
  name            = "platform-dev"
  environment     = "dev"
  chart_version   = "10.1.2"
  gitops_repo_url = "https://github.com/x/y.git"
  gitops_revision = "main"
}

run "valid_defaults" {
  command = plan
}

run "reject_non_semver_chart" {
  command = plan
  variables {
    chart_version = "v10"
  }
  expect_failures = [var.chart_version]
}

run "reject_bad_environment" {
  command = plan
  variables {
    environment = "qa"
  }
  expect_failures = [var.environment]
}

run "reject_bad_profile" {
  command = plan
  variables {
    profile = "huge"
  }
  expect_failures = [var.profile]
}

run "reject_insecure_source_repo" {
  command = plan
  variables {
    additional_source_repos = ["http://insecure.example"]
  }
  expect_failures = [var.additional_source_repos]
}
