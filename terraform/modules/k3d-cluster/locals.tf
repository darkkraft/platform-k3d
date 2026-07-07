locals {
  # k3d registers its kube-context as "k3d-<cluster_name>", merged into
  # ~/.kube/config. Deterministic from the name (known at plan time), so
  # downstream providers can target it without waiting on a resource output.
  kube_context = "k3d-${var.cluster_name}"

  # Fixed API port (stable kubeconfig) + extra cert SANs (clean remote TLS).
  api_port_arg = var.api_port > 0 ? "--api-port 0.0.0.0:${var.api_port}" : ""
  tls_san_args = join(" ", [for s in var.tls_sans : format("--k3s-arg \"--tls-san=%s@server:*\"", s)])

  # Shared k3d registry: in-cluster image ref host, and host push target.
  registry_ref  = "k3d-${var.registry_name}:${var.registry_port}"
  registry_push = "localhost:${var.registry_port}"
}
