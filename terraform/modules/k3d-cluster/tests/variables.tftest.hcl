# `tofu test` — asserts the k3d-cluster module's variable CONTRACT (the validation
# rules the whole tree relies on). Uses `command = plan` so nothing is created and
# no Docker/cluster is needed; only the null provider is initialised.
#
# Run:  cd terraform/modules/k3d-cluster && tofu init && tofu test

# A fully-valid input set — the plan must succeed.
run "valid_defaults" {
  command = plan

  variables {
    cluster_name = "platform-dev"
    http_port    = 80
    https_port   = 443
    api_port     = 6445
    k3s_image    = "rancher/k3s:v1.36.2-k3s1"
  }

  assert {
    condition     = output.kube_context == "k3d-platform-dev"
    error_message = "kube_context should be derived as k3d-<cluster_name>"
  }
}

# http_port == https_port must be rejected (cross-field validation).
run "reject_http_https_collision" {
  command = plan

  variables {
    cluster_name = "platform-dev"
    http_port    = 8080
    https_port   = 8080
  }

  expect_failures = [var.https_port]
}

# api_port colliding with an ingress port must be rejected.
run "reject_api_port_collision" {
  command = plan

  variables {
    cluster_name = "platform-dev"
    http_port    = 80
    https_port   = 443
    api_port     = 80
  }

  expect_failures = [var.api_port]
}

# A floating / :latest k3s image must be rejected (reproducibility).
run "reject_unpinned_k3s_image" {
  command = plan

  variables {
    cluster_name = "platform-dev"
    k3s_image    = "rancher/k3s:latest"
  }

  expect_failures = [var.k3s_image]
}

# An invalid cluster name (must start with a letter) must be rejected.
run "reject_bad_cluster_name" {
  command = plan

  variables {
    cluster_name = "1-bad-name"
  }

  expect_failures = [var.cluster_name]
}

# Registry port must not collide with the ingress/API ports.
run "reject_registry_port_collision" {
  command = plan

  variables {
    cluster_name  = "platform-dev"
    http_port     = 80
    https_port    = 443
    registry_port = 443
  }

  expect_failures = [var.registry_port]
}
